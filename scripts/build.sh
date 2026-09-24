#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Obby builds only on macOS." >&2
  exit 1
fi

# Uses OBBY_SDK when set. Otherwise, prefers the active SDK and falls back to
# another installed macOS SDK that the selected Swift compiler can load.
resolve_sdk() {
  local candidate
  local active_sdk
  local sdk_dir
  local -a candidates

  if [[ -n "${OBBY_SDK:-}" ]]; then
    candidates=("$OBBY_SDK")
  else
    active_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    sdk_dir="$(dirname "$active_sdk")"
    candidates=("$active_sdk")
    while IFS= read -r candidate; do
      [[ "$candidate" == "$active_sdk" ]] || candidates+=("$candidate")
    done < <(find "$sdk_dir" -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -r)
  fi

  for candidate in "${candidates[@]}"; do
    if printf 'import Foundation\n' | swiftc -sdk "$candidate" -target "$(uname -m)-apple-macosx13.0" -typecheck - >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "No installed macOS SDK is compatible with this Swift compiler." >&2
  echo "Update Xcode or the Command Line Tools, or set OBBY_SDK to a matching SDK." >&2
  exit 1
}

SDK="$(resolve_sdk)"
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
