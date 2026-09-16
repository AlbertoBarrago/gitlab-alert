#!/bin/bash
set -e

cd "$(dirname "$0")/.."

BUNDLE_NAME="GitLabAlert"
APP="/Applications/${BUNDLE_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
SIGNING_CN="GitLab Alert Signing"
DIST="dist"

# A release must have a stable designated requirement: Keychain item ACLs and the
# notification grant are pinned to it, and ad-hoc's changes on every build.
# `security find-identity -v` lists revoked certs as valid from a stale OCSP
# cache, so candidates are probed by actually signing and verifying.
CERT=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${SIGNING_CN}"; then
    CERT="${SIGNING_CN}"
else
    for CANDIDATE in $(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/Apple Development/ { print $2 }'); do
        MROBE=$(mktemp)
        cp /bin/echo "${MROBE}"
        if codesign --force --sign "${CANDIDATE}" "${MROBE}" 2>/dev/null \
           && codesign --verify --strict "${MROBE}" 2>/dev/null; then
            CERT="${CANDIDATE}"
            rm -f "${MROBE}"
            break
        fi
        rm -f "${MROBE}"
    done
fi

if [ -z "${CERT}" ]; then
    echo "❌ No usable signing identity."
    echo "   Ad-hoc is not acceptable for a release: it resets the Keychain ACL"
    echo "   and the notification grant on every build."
    echo "   Run once:  bash bin/make-signing-cert.sh"
    exit 1
fi

echo "▶ Running logic tests…"
bash bin/test.sh

echo "▶ Stopping running instance…"
pkill -x "${BUNDLE_NAME}" 2>/dev/null || true
sleep 0.3

echo "▶ Building ${BUNDLE_NAME} (release)…"
swift build -c release

if [ ! -f "${BUNDLE_NAME}.icns" ]; then
    echo "❌ Missing application icon: ${BUNDLE_NAME}.icns"
    exit 1
fi

mkdir -p "${MACOS}" "${RESOURCES}"

if ! diff -q "Info.plist" "${CONTENTS}/Info.plist" &>/dev/null; then
    cp "Info.plist" "${CONTENTS}/Info.plist"
fi

cp ".build/release/${BUNDLE_NAME}" "${MACOS}/${BUNDLE_NAME}"
cp "${BUNDLE_NAME}.icns" "${RESOURCES}/${BUNDLE_NAME}.icns"
if [ -d "Resources" ]; then
    cp -R Resources/. "${RESOURCES}/"
fi

echo "▶ Signing (${CERT})…"
codesign --force --deep --sign "${CERT}" \
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
# right-click → Open on first launch, or build it themselves.
echo ""
echo "▶ Done → ${DMG}"
echo "          ${ZIP}"
echo "   Signed with: ${CERT}"
echo "   Not notarized: first launch on another Mac needs right-click → Open."
