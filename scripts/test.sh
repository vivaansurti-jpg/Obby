#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Obby tests run only on macOS." >&2
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
    if printf 'import Foundation\n' | swiftc -sdk "$candidate" -target "$(uname -m)-apple-macosx13.0" -module-cache-path /tmp/obby-swift-cache -typecheck - >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "No installed macOS SDK is compatible with this Swift compiler." >&2
  echo "Update Xcode or the Command Line Tools, or set OBBY_SDK to a matching SDK." >&2
  exit 1
}

SDK="$(resolve_sdk)"
mkdir -p build
swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -parse-as-library Sources/Obby/Vault.swift Sources/Obby/Editor.swift Sources/Obby/RichMarkdown.swift Sources/Obby/Model.swift Sources/Obby/Ollama.swift Sources/Obby/ChatMemory.swift Sources/Obby/ModelSettings.swift Sources/Obby/SidebarDrag.swift Sources/Obby/AIProvider.swift Sources/Obby/Keychain.swift Sources/Obby/ContextBudget.swift Sources/Obby/NoteIndex.swift scripts/Checks.swift scripts/RegressionChecks.swift -o build/ObbyChecks -framework SwiftUI -framework AppKit -framework Security -module-cache-path /tmp/obby-swift-cache
build/ObbyChecks
