#!/bin/bash
set -e

cd "$(dirname "$0")/.."

BUNDLE_NAME="GitLabAlert"
# Where the bundle is assembled. Locally this is the installed app, so a release
# build doubles as an install. CI overrides it with a staging directory: a
# runner has no /Applications worth writing to, and nothing to keep in sync.
APP_DIR="${APP_DIR:-/Applications}"
APP="${APP_DIR}/${BUNDLE_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
SIGNING_CN="${SIGNING_CN:-GitLab Alert Signing}"
DIST="${DIST:-dist}"

# A release must have a stable designated requirement: Keychain item ACLs and the
# notification grant are pinned to it, and ad-hoc's changes on every build.
# `security find-identity -v` lists revoked certs as valid from a stale OCSP
# cache, so candidates are probed by actually signing and verifying.
# An explicit identity, when the caller already knows which one to use. CI
# imports the certificate into a throwaway keychain where it is unavoidably
# untrusted, so `find-identity -v` would report nothing: the SHA-1 of the
# imported identity is passed in instead, and codesign is happy to sign with it.
CERT="${SIGNING_IDENTITY:-}"
if [ -n "${CERT}" ]; then
    echo "▶ Using the identity supplied in SIGNING_IDENTITY."
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGNING_CN}"; then
    CERT="${SIGNING_CN}"
else
    for CANDIDATE in $(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/Apple Development/ { print $2 }'); do
        PROBE=$(mktemp)
        cp /bin/echo "${PROBE}"
        if codesign --force --sign "${CANDIDATE}" "${PROBE}" 2>/dev/null \
           && codesign --verify --strict "${PROBE}" 2>/dev/null; then
            CERT="${CANDIDATE}"
            rm -f "${PROBE}"
            break
        fi
        rm -f "${PROBE}"
    done
fi

if [ -z "${CERT}" ]; then
    echo "❌ No usable signing identity."
    echo "   Ad-hoc is not acceptable for a release: it resets the Keychain ACL"
    echo "   and the notification grant on every build."
    echo "   Run once:  bash bin/make-signing-cert.sh"
    exit 1
fi

if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "▶ Skipping logic tests (SKIP_TESTS=1)."
else
    echo "▶ Running logic tests…"
    bash bin/test.sh
fi

# Only meaningful when we are about to overwrite the installed app. On a
# staging build there is nothing running to displace.
if [ "${APP_DIR}" = "/Applications" ]; then
    echo "▶ Stopping running instance…"
    pkill -x "${BUNDLE_NAME}" 2>/dev/null || true
    sleep 0.3
fi

# Universal, unlike the debug build: a release is what other people run, and an
# arm64-only binary would leave an Intel Mac unable to take any update at all,
# which the appcast then advertises as a hardware requirement.
echo "▶ Building ${BUNDLE_NAME} (release, universal)…"
SWIFT_BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
swift build "${SWIFT_BUILD_FLAGS[@]}"
# Ask SwiftPM where it put the binary instead of assuming .build/release: with
# --arch that symlink is never created, and a machine that has one from an
# earlier plain build hides the difference until CI fails on a clean checkout.
BIN_PATH=$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)

if [ ! -f "${BUNDLE_NAME}.icns" ]; then
    echo "❌ Missing application icon: ${BUNDLE_NAME}.icns"
    exit 1
fi

mkdir -p "${MACOS}" "${RESOURCES}"

if ! diff -q "Info.plist" "${CONTENTS}/Info.plist" &>/dev/null; then
    cp "Info.plist" "${CONTENTS}/Info.plist"
fi

cp "${BIN_PATH}/${BUNDLE_NAME}" "${MACOS}/${BUNDLE_NAME}"
cp "${BUNDLE_NAME}.icns" "${RESOURCES}/${BUNDLE_NAME}.icns"
if [ -d "Resources" ]; then
    cp -R Resources/. "${RESOURCES}/"
fi

bash bin/embed-sparkle.sh "${APP}" "${CERT}"

# No --deep: Sparkle's nested bundles are already signed, in order, by
# embed-sparkle.sh, and --deep would re-sign them with this app's entitlements.
echo "▶ Signing (${CERT})…"
codesign --force --sign "${CERT}" \
    --options runtime \
    --entitlements "${BUNDLE_NAME}.entitlements" \
    "${APP}"

if ! codesign --verify --deep --strict "${APP}" 2>/dev/null; then
    echo "❌ Signature verification failed."
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
mkdir -p "${DIST}"
ZIP="${DIST}/${BUNDLE_NAME}-${VERSION}.zip"
DMG="${DIST}/${BUNDLE_NAME}-${VERSION}.dmg"
rm -f "${ZIP}"
rm -f "${DMG}"

STAGING=$(mktemp -d)
MOUNT=$(mktemp -d)
MOUNTED=false
cleanup() {
    if [ "${MOUNTED}" = true ]; then
        hdiutil detach "${MOUNT}" -quiet 2>/dev/null || true
    fi
    rm -rf "${STAGING}" "${MOUNT}"
}
trap cleanup EXIT

echo "▶ Packaging ${DMG}…"
ditto "${APP}" "${STAGING}/${BUNDLE_NAME}.app"
ln -s /Applications "${STAGING}/Applications"
hdiutil create \
    -volname "GitLab Alert ${VERSION}" \
    -srcfolder "${STAGING}" \
    -ov \
    -format UDZO \
    "${DMG}" >/dev/null

echo "▶ Verifying ${DMG}…"
hdiutil attach "${DMG}" -readonly -nobrowse -mountpoint "${MOUNT}" -quiet
MOUNTED=true
test -L "${MOUNT}/Applications"
codesign --verify --deep --strict "${MOUNT}/${BUNDLE_NAME}.app"
hdiutil detach "${MOUNT}" -quiet
MOUNTED=false

echo "▶ Packaging ${ZIP}…"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

# NOT notarized, and deliberately so: notarization needs a paid Developer ID,
# and this is a build-from-source tool. Anyone else downloading the zip has to
# use Privacy & Security → Open Anyway after the first blocked launch.
echo "▶ Writing checksums…"
CHECKSUMS="${DIST}/SHA256SUMS.txt"
rm -f "${CHECKSUMS}"
(cd "${DIST}" && shasum -a 256 "$(basename "${DMG}")" "$(basename "${ZIP}")" > "$(basename "${CHECKSUMS}")")
cat "${CHECKSUMS}"

echo ""
echo "▶ Done → ${DMG}"
echo "          ${ZIP}"
echo "   Signed with: ${CERT}"
echo "   Not notarized: after the first blocked launch use Privacy & Security → Open Anyway."
echo "   If still blocked: xattr -dr com.apple.quarantine \"/Applications/${BUNDLE_NAME}.app\""
