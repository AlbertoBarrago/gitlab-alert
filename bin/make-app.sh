#!/bin/bash
set -e

cd "$(dirname "$0")/.."

BUNDLE_NAME="GitLabAlert"
APP="/Applications/${BUNDLE_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
SIGNING_CN="GitLab Alert Signing"

# Identity selection, in order of preference:
#   1. our own stable self-signed cert — a constant designated requirement, so
#      the Keychain ACL and the notification grant survive every rebuild;
#   2. a genuinely valid Apple Development cert;
#   3. ad-hoc, which breaks both and is only tolerable for a throwaway build.
#
# `security find-identity -v` is NOT trustworthy for step 2: it lists revoked
# certs as valid from a stale OCSP cache. The only reliable test is to sign
# something and run `codesign --verify --strict`, so that is what we do.
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
    CERT="-"
    echo "⚠️  No usable signing identity — falling back to ad-hoc."
    echo "   Consequence: the code signature changes on every build, so macOS"
    echo "   re-prompts for the Keychain item and the notification grant resets."
    # Say what was actually there. This fell back silently for weeks because
    # bin/.signing held a sibling project's bundle, whose common name does not
    # match SIGNING_CN — a state that looks exactly like "no certificate yet".
    if [ -f "bin/.signing/GitLabAlert-signing.p12" ] && [ -f "bin/.signing/passphrase.txt" ]; then
        FOUND_CN=$(openssl pkcs12 -in bin/.signing/GitLabAlert-signing.p12 -legacy -clcerts -nokeys \
            -passin file:bin/.signing/passphrase.txt 2>/dev/null \
            | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
            | awk -F' = ' '/commonName/ { print $2 }')
        if [ -n "${FOUND_CN}" ] && [ "${FOUND_CN}" != "${SIGNING_CN}" ]; then
            echo "   bin/.signing holds \"${FOUND_CN}\", which is not \"${SIGNING_CN}\":"
            echo "   that bundle belongs to another app and cannot sign this one."
        fi
    fi
    echo "   Fix it once with:  bash bin/make-signing-cert.sh"
fi

echo "▶ Building ${BUNDLE_NAME} (debug)…"
swift build -c debug

if [ ! -f "${BUNDLE_NAME}.icns" ]; then
    echo "❌ Missing application icon: ${BUNDLE_NAME}.icns"
    exit 1
fi

mkdir -p "${MACOS}" "${RESOURCES}"

if ! diff -q "Info.plist" "${CONTENTS}/Info.plist" &>/dev/null; then
    cp "Info.plist" "${CONTENTS}/Info.plist"
fi

cp ".build/debug/${BUNDLE_NAME}" "${MACOS}/${BUNDLE_NAME}"
cp "${BUNDLE_NAME}.icns" "${RESOURCES}/${BUNDLE_NAME}.icns"
# Loose resources (the menu bar glyph), read back through Bundle.main.
if [ -d "Resources" ]; then
    cp -R Resources/. "${RESOURCES}/"
fi

echo "▶ Signing (${CERT})…"
codesign --force --deep --sign "${CERT}" \
    --options runtime \
    --entitlements "${BUNDLE_NAME}.entitlements" \
    "${APP}"

# Reject a silently-invalid signature before the user tries to launch: a
# revoked cert signs happily and only fails here.
if ! codesign --verify --deep --strict "${APP}" 2>/dev/null; then
    echo "❌ Signature verification failed — macOS will kill the app on launch."
    echo "   Most likely a revoked certificate. Run: bash bin/make-signing-cert.sh"
    exit 1
fi

echo "▶ Done → ${APP}"
