#!/bin/bash
# Copies Sparkle.framework into an assembled bundle and signs it inside-out.
#
# Usage: embed-sparkle.sh <app bundle> <signing identity>
#
# Sparkle arrives as an xcframework in SwiftPM's artifact cache. Only the macOS
# slice belongs in the bundle, in Contents/Frameworks, which is where the
# executable's rpath (-rpath @executable_path/../Frameworks, set in
# Package.swift) looks for it.
#
# The framework carries its own nested bundles: an Updater.app, the Autoupdate
# binary and two XPC services. Every one of them has to be signed before the
# thing that contains it, deepest first, or macOS rejects the outer seal. This
# is also why the app itself must NOT be signed with --deep: that would re-sign
# these nested bundles with the app's own entitlements and undo the order.
set -e

APP="${1:?usage: embed-sparkle.sh <app bundle> <signing identity>}"
CERT="${2:?usage: embed-sparkle.sh <app bundle> <signing identity>}"
CONTENTS="${APP}/Contents"
FRAMEWORKS="${CONTENTS}/Frameworks"

# The universal slice, whatever its directory happens to be called: the name
# encodes the architectures and changes between Sparkle releases.
SOURCE=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*Sparkle.xcframework/macos-*" 2>/dev/null | head -n 1)
if [ -z "${SOURCE}" ]; then
    echo "❌ Sparkle.framework not found in .build/artifacts."
    echo "   Run a build first: swift build resolves and unpacks the xcframework."
    exit 1
fi

echo "▶ Embedding Sparkle…"
mkdir -p "${FRAMEWORKS}"
# --delete so a Sparkle upgrade cannot leave the previous version's files
# behind inside the bundle.
rsync -a --delete "${SOURCE}" "${FRAMEWORKS}/"

FRAMEWORK="${FRAMEWORKS}/Sparkle.framework"
# Resolve the versioned directory rather than assuming "A" or "B": Sparkle has
# shipped both.
VERSION_DIR=$(/usr/bin/readlink "${FRAMEWORK}/Versions/Current" || echo "")
if [ -z "${VERSION_DIR}" ]; then
    echo "❌ Sparkle.framework has no Versions/Current symlink."
    exit 1
fi
CURRENT="${FRAMEWORK}/Versions/${VERSION_DIR}"

echo "▶ Signing Sparkle inside-out (${CERT})…"
for NESTED in \
    "${CURRENT}/XPCServices/Downloader.xpc" \
    "${CURRENT}/XPCServices/Installer.xpc" \
    "${CURRENT}/Updater.app" \
    "${CURRENT}/Autoupdate"
do
    [ -e "${NESTED}" ] || continue
    codesign --force --options runtime --sign "${CERT}" "${NESTED}"
done
codesign --force --options runtime --sign "${CERT}" "${FRAMEWORK}"

# Fail here rather than at the user's first update: a framework whose seal does
# not verify makes the whole app unlaunchable once it is sealed inside.
if ! codesign --verify --strict "${FRAMEWORK}"; then
    echo "❌ Sparkle.framework signature verification failed."
    exit 1
fi
