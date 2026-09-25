#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Obby tests run only on macOS." >&2
  exit 1
fi
resolve_sdk() {
  local candidate active_sdk sdk_dir
  local -a candidates
  if [[ -n "${OBBY_SDK:-}" ]]; then candidates=("$OBBY_SDK"); else
    active_sdk="$(xcrun --sdk macosx --show-sdk-path)"; sdk_dir="$(dirname "$active_sdk")"; candidates=("$active_sdk")
    while IFS= read -r candidate; do [[ "$candidate" == "$active_sdk" ]] || candidates+=("$candidate"); done < <(find "$sdk_dir" -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -r)
  fi
  for candidate in "${candidates[@]}"; do
    if printf 'import Foundation\n' | swiftc -sdk "$candidate" -target "$(uname -m)-apple-macosx13.0" -module-cache-path /tmp/obby-swift-cache -typecheck - >/dev/null 2>&1; then printf '%s\n' "$candidate"; return; fi
  done
  echo "No installed macOS SDK is compatible with this Swift compiler." >&2; exit 1
}
SDK="$(resolve_sdk)"
mkdir -p build
swiftc -swift-version 5 -sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -parse-as-library Sources/Obby/Vault.swift Sources/Obby/NoteIndex.swift Sources/Obby/QuickAction.swift scripts/FeatureChecks.swift -o build/ObbyFeatureChecks -framework SwiftUI -framework AppKit -framework Security -module-cache-path /tmp/obby-swift-cache
build/ObbyFeatureChecks
