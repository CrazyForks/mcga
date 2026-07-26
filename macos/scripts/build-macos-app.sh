#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
CODESIGN_OPTIONS=()
APP_DIR="$ROOT/.build/MCGA.app"
EXECUTABLE="$ROOT/.build/$CONFIGURATION/MCGA"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product MCGA

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$ROOT/Packaging/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/MCGA"

if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  CODESIGN_OPTIONS+=(--options runtime --timestamp)
fi

codesign --force --deep "${CODESIGN_OPTIONS[@]}" --sign "$CODESIGN_IDENTITY" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
