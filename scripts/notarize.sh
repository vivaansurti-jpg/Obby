#!/bin/bash
# Submits the signed release DMG to Apple, staples the approval ticket, and verifies it.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname)" != "Darwin" ]]; then
  echo "Notarization runs only on macOS." >&2
  exit 1
fi

if [[ ! -f build/Obby.dmg ]]; then
  echo "Missing build/Obby.dmg. Build a signed release first." >&2
  exit 1
fi

if [[ -z "${OBBY_NOTARY_PROFILE:-}" ]]; then
  echo "Set OBBY_NOTARY_PROFILE to a notarytool Keychain profile." >&2
  exit 1
fi

xcrun notarytool submit build/Obby.dmg --keychain-profile "$OBBY_NOTARY_PROFILE" --wait
xcrun stapler staple build/Obby.dmg
xcrun stapler validate build/Obby.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 build/Obby.dmg
echo "Notarized and stapled build/Obby.dmg. It is ready to upload as a GitHub Release asset."
