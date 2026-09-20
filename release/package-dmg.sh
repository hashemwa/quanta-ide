#!/usr/bin/env bash

set -euo pipefail

IDENTITY="${QUANTA_SIGN_IDENTITY:-}"
APP="${1:-}"

if [[ -z "$IDENTITY" ]]; then
  echo "Set QUANTA_SIGN_IDENTITY to the Developer ID to sign with, for example:"
  echo "  export QUANTA_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\""
  echo "List the identities in your keychain with:  security find-identity -v -p codesigning"
  exit 1
fi

if [[ -z "$APP" ]]; then
  PRODUCTS="$(xcodebuild -showBuildSettings \
    -project "$(cd "$(dirname "$0")/.." && pwd)/Quanta.xcodeproj" \
    -scheme Quanta -configuration Release 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
  APP="$PRODUCTS/Quanta.app"
  echo "==> Using the Release build: $APP"
fi

if [[ ! -d "$APP" ]]; then
  echo "No app at '$APP'. Build one first:  ./scripts/quanta release"
  echo "Usage: $0 [path/to/Quanta.app] [version]   (requires: brew install create-dmg)"
  echo "Optional: release/dmg-background.png (1200x800) for the branded backdrop."
  exit 1
fi

"$(cd "$(dirname "$0")/.." && pwd)/scripts/native-tools" verify "$APP"

VERSION="${2:-$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)}"
OUT="$HOME/Desktop/Quanta-${VERSION}.dmg"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

echo "==> Code-signing Quanta.app with: $IDENTITY"
codesign --force --deep --options runtime --timestamp \
  --sign "$IDENTITY" "$STAGE/Quanta.app"
codesign --verify --strict --verbose=1 "$STAGE/Quanta.app"

BG_ARGS=()
BG="$(cd "$(dirname "$0")" && pwd)/dmg-background.png"
if [[ -f "$BG" ]]; then
  BG_ARGS=(--background "$BG")
  echo "==> Using background image: $BG"
else
  echo "==> No release/dmg-background.png found — building with positioned icons only."
fi

rm -f "$OUT"
create-dmg \
  --volname "Quanta" \
  --window-size 600 400 \
  --icon-size 110 \
  --icon "Quanta.app" 150 190 \
  --app-drop-link 450 190 \
  --hide-extension "Quanta.app" \
  ${BG_ARGS[@]+"${BG_ARGS[@]}"} \
  "$OUT" \
  "$STAGE/"

echo "==> Code-signing the DMG..."
codesign --force --timestamp --sign "$IDENTITY" "$OUT"

echo "==> Built + signed: $OUT"
echo "    Next:  ./release/notarize-dmg.sh \"$OUT\""
