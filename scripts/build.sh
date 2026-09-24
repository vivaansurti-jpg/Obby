#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Default: the active macOS SDK. Set OBBY_SDK to a specific SDK path to override.
SDK="${OBBY_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
# Default: this Mac's architecture. OBBY_ARCHS="arm64 x86_64" builds a universal app (used by make_dmg.sh).
ARCHS="${OBBY_ARCHS:-$(uname -m)}"
BIN=build/Obby.app/Contents/MacOS/Obby
mkdir -p build/Obby.app/Contents/MacOS build/Obby.app/Contents/Resources
PARTS=()
for ARCH in $ARCHS; do
  swiftc -O -sdk "$SDK" -target "$ARCH-apple-macosx13.0" -parse-as-library Sources/Obby/*.swift -o "build/Obby-$ARCH" -framework SwiftUI -framework AppKit -framework Security -module-cache-path "/tmp/obby-swift-cache-$ARCH"
  PARTS+=("build/Obby-$ARCH")
done
lipo -create "${PARTS[@]}" -output "$BIN"
rm -f "${PARTS[@]}"
cp Info.plist build/Obby.app/Contents/Info.plist
cp Resources/AppIcon.icns build/Obby.app/Contents/Resources/AppIcon.icns
codesign --force --sign - build/Obby.app
