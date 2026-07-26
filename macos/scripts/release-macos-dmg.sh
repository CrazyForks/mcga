#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mcga-notary}"
DMG_PATH="$ROOT/.build/MCGA.dmg"

detect_developer_id_identity() {
  local identities
  local count

  identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')"
  count="$(printf '%s\n' "$identities" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$count" == "1" ]]; then
    printf '%s\n' "$identities"
    return 0
  fi

  if [[ "$count" == "0" ]]; then
    echo 'No Developer ID Application identity found in the keychain.' >&2
  else
    echo 'Multiple Developer ID Application identities found. Set CODESIGN_IDENTITY explicitly.' >&2
    printf '%s\n' "$identities" >&2
  fi
  return 1
}

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(detect_developer_id_identity)}"

if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo 'CODESIGN_IDENTITY must be set to a Developer ID Application identity.' >&2
  echo 'Example: CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/release-macos-dmg.sh' >&2
  exit 1
fi

cd "$ROOT"

CONFIGURATION="$CONFIGURATION" \
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
SIGN_DMG=1 \
bash scripts/package-macos-dmg.sh

echo "==> Notarizing $DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"

echo "==> Verifying release artifact"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo "$DMG_PATH"
