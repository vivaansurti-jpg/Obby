#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Obby.app and packages it as build/Obby.dmg for a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")/.."
OBBY_ARCHS="${OBBY_ARCHS:-arm64 x86_64}" ./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Obby.app "$STAGE/"
ln -s /Applications "$STAGE/Applications" # Drag-to-install shortcut inside the disk image.
hdiutil create -volname "Obby $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/Obby.dmg >/dev/null
echo "Created build/Obby.dmg (Obby $VERSION). Upload it to a GitHub Release as Obby.dmg."
