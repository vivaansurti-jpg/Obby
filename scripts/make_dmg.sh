#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Obby.app and packages it as build/Obby.dmg for a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${OBBY_SIGN_IDENTITY:-}" || "${OBBY_SIGN_IDENTITY}" == "-" ]]; then
  echo "A Developer ID Application signing identity is required for a release." >&2
  echo "Set OBBY_SIGN_IDENTITY, then run this script again." >&2
  exit 1
fi
OBBY_ARCHS="${OBBY_ARCHS:-arm64 x86_64}" ./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Obby.app "$STAGE/"
ln -s /Applications "$STAGE/Applications" # Drag-to-install shortcut inside the disk image.
hdiutil create -volname "Obby $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/Obby.dmg >/dev/null
codesign --verify --deep --strict --verbose=2 build/Obby.app
echo "Created signed build/Obby.dmg (Obby $VERSION). Run ./scripts/notarize.sh before uploading it to a GitHub Release."
