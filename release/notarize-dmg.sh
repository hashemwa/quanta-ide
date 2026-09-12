#!/usr/bin/env bash

set -euo pipefail

PROFILE="${QUANTA_NOTARY_PROFILE:-quanta}"
DMG="${1:-$(ls -t "$HOME"/Desktop/Quanta-*.dmg 2>/dev/null | head -1)}"

if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "Usage: $0 path/to/file.dmg   (or run ./release/package-dmg.sh first)"
  echo
  echo "One-time setup of the \"$PROFILE\" keychain profile:"
  echo "  xcrun notarytool store-credentials \"$PROFILE\" \\"
  echo "    --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password APP_SPECIFIC_PASSWORD"
  exit 1
fi

echo "==> Submitting $(basename "$DMG") to Apple notary service (typically 1-5 min)..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the notarization ticket onto the DMG..."
xcrun stapler staple "$DMG"

echo "==> Verifying Gatekeeper acceptance..."
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "==> Done. '$DMG' is notarized, stapled, and ready to ship."
