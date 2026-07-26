#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="$ROOT/.build/MCGA.dmg"
CONFIGURATION="${CONFIGURATION:-release}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_DMG="${SIGN_DMG:-0}"

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
fi

cd "$ROOT"
CONFIGURATION="$CONFIGURATION" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" bash scripts/build-macos-app.sh

rm -f "$DMG_PATH"
create-dmg \
  --volname "MCGA" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "MCGA.app" 175 190 \
  --hide-extension "MCGA.app" \
  --app-drop-link 425 190 \
  "$DMG_PATH" \
  ".build/MCGA.app"

if [[ "$SIGN_DMG" == "1" ]]; then
  if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "CODESIGN_IDENTITY must be a Developer ID identity when SIGN_DMG=1" >&2
    exit 1
  fi
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

echo "$DMG_PATH"
