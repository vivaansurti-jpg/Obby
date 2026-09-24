#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Default: the active macOS SDK. Set OBBY_SDK to a specific SDK path to override.
SDK="${OBBY_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
mkdir -p build
swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx13.0" -parse-as-library Sources/Obby/Vault.swift Sources/Obby/Editor.swift Sources/Obby/Model.swift Sources/Obby/Ollama.swift Sources/Obby/ChatMemory.swift Sources/Obby/ModelSettings.swift Sources/Obby/SidebarDrag.swift Sources/Obby/AIProvider.swift Sources/Obby/Keychain.swift Sources/Obby/ContextBudget.swift scripts/Checks.swift -o build/ObbyChecks -framework SwiftUI -framework AppKit -framework Security -module-cache-path /tmp/obby-swift-cache
build/ObbyChecks
