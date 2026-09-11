#!/bin/bash
set -e

# Generate a STABLE self-signed code-signing certificate for GitLab Alert.
#
# Why this exists:
# macOS pins two things to the app's code-signing designated requirement —
# Keychain item ACLs and TCC grants (notification authorization). With ad-hoc
# signing (codesign --sign -) the requirement falls back to the binary's cdhash,
# which changes on EVERY build: the app stops recognising its own stored token
# and the notification grant resets. Signing every build with the SAME
# certificate keeps the requirement constant, with no Apple Developer account.
#
# The Apple Development certs on this machine are revoked — `security
# find-identity -v` lists one as valid from a stale OCSP cache, but signing with
# it and running `codesign --verify --strict` returns CSSMERR_TP_CERT_REVOKED.
# That is why this is the primary path and not a fallback.
#
# Run this ONCE. Keep the .p12 backed up: losing it means the next build gets a
# new identity, and you re-paste the token and re-grant notifications once more.

cd "$(dirname "$0")/.."

CN="GitLab Alert Signing"
ORG="alBz"
OUT_DIR="bin/.signing"          # gitignored
P12="${OUT_DIR}/GitLabAlert-signing.p12"
PASS_FILE="${OUT_DIR}/passphrase.txt"
DAYS=3650                       # 10 years; only stability matters, not duration

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "${CN}"; then
    echo "✅ Identity \"${CN}\" is already in the keychain — nothing to do."
    echo "   Regenerating would change the signing identity and reset both the"
    echo "   Keychain ACL and the notification grant."
    exit 0
fi

if [ -f "${P12}" ]; then
    echo "▶ Found an existing ${P12} — importing it rather than generating a new one."
else
    P12_PASS=$(openssl rand -base64 24)

    echo "▶ Generating key + self-signed code-signing certificate…"
    openssl req -x509 -newkey rsa:2048 -sha256 -days "${DAYS}" -nodes \
        -keyout "${OUT_DIR}/key.pem" \
        -out "${OUT_DIR}/cert.pem" \
        -subj "/CN=${CN}/O=${ORG}" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        2>/dev/null

    echo "▶ Packaging PKCS#12 bundle…"
    # -legacy is REQUIRED: OpenSSL 3.x defaults to PKCS#12 encryption that
    # macOS's Security framework cannot import ("MAC verification failed").
    openssl pkcs12 -export -legacy \
        -inkey "${OUT_DIR}/key.pem" \
        -in "${OUT_DIR}/cert.pem" \
        -name "${CN}" \
        -out "${P12}" \
        -passout "pass:${P12_PASS}"

    rm -f "${OUT_DIR}/key.pem" "${OUT_DIR}/cert.pem"

    printf '%s' "${P12_PASS}" > "${PASS_FILE}"
    chmod 600 "${PASS_FILE}" "${P12}"
    echo "▶ Passphrase written to ${PASS_FILE} (gitignored)."
fi

echo "▶ Importing into the login keychain…"
security import "${P12}" \
    -k ~/Library/Keychains/login.keychain-db \
    -P "$(cat "${PASS_FILE}")" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Importing a self-signed identity does not make it trusted. Constrain trust to
# code signing in the current user's store; it must not become a TLS root.
openssl pkcs12 -in "${P12}" -legacy -clcerts -nokeys \
    -passin "file:${PASS_FILE}" -out "${OUT_DIR}/cert.pem"
security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "${OUT_DIR}/cert.pem"

# Without this, codesign prompts for keychain access on every single build.
# It may ask for the login password once, which is expected.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -l "${CN}" -s -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || \
    echo "⚠️  Could not set the key partition list automatically. If codesign" \
         "prompts on every build, run that command manually with your password."

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "${CN}"; then
    echo "❌ Import finished but \"${CN}\" is not a valid codesigning identity."
    echo "   Check: security find-identity -v -p codesigning"
    exit 1
fi

echo ""
echo "✅ Signing identity ready → ${CN}"
echo "   bin/make-app.sh picks it up automatically from here on."
echo "⚠️  Back up ${P12} and ${PASS_FILE} somewhere safe (password manager)."
