#!/usr/bin/env bash
# Package the already-notarized Haynoi.app into a signed + notarized + stapled DMG.
# Runs AFTER sign-and-notarize.sh (which leaves a stapled Haynoi.app at repo root).
#
# Requires (same env as sign-and-notarize.sh):
#   APP_IDENTITY                    — "Developer ID Application: Affitor LLC (XXXXXXXXXX)"
#   APP_STORE_CONNECT_API_KEY_P8    — contents of AuthKey_XXX.p8 (multiline)
#   APP_STORE_CONNECT_KEY_ID        — Key ID from App Store Connect
#   APP_STORE_CONNECT_ISSUER_ID     — Issuer ID from App Store Connect
#
# Output: Haynoi-<version>.dmg at repo root — the haynoi.com download artifact.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

APP_BUNDLE="${ROOT}/Haynoi.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: $APP_BUNDLE not found — run package_app.sh + sign-and-notarize.sh first." >&2
  exit 1
fi

# The app must already be stapled; a DMG of an unstapled app shows Gatekeeper friction.
xcrun stapler validate "$APP_BUNDLE" || {
  echo "ERROR: Haynoi.app is not stapled — run sign-and-notarize.sh first." >&2
  exit 1
}

APP_IDENTITY=${APP_IDENTITY:-}
if [[ -z "$APP_IDENTITY" ]]; then
  echo "ERROR: APP_IDENTITY env var required." >&2
  exit 1
fi
if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "ERROR: APP_STORE_CONNECT_* env vars required for DMG notarization." >&2
  exit 1
fi

DMG_PATH="${ROOT}/Haynoi-${MARKETING_VERSION}.dmg"
rm -f "$DMG_PATH"

echo "==> Creating DMG"
STAGE_DIR=$(mktemp -d /tmp/haynoi-dmg.XXXXXX)
API_KEY_FILE="/tmp/haynoi-dmg-api-key.p8"
trap 'rm -rf "$STAGE_DIR" "$API_KEY_FILE"' EXIT
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "Haynoi" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG_PATH"

echo "==> Notarizing DMG (1-10 min)"
echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$API_KEY_FILE"
xcrun notarytool submit "$DMG_PATH" \
  --key "$API_KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> DMG ready: $DMG_PATH"
ls -lh "$DMG_PATH"
