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

echo "==> Creating branded DMG (background + arrow + icon layout)"
STAGE_DIR=$(mktemp -d /tmp/haynoi-dmg.XXXXXX)
API_KEY_FILE="/tmp/haynoi-dmg-api-key.p8"
RW_DMG=$(mktemp -u /tmp/haynoi-rw.XXXXXX).dmg
trap 'rm -rf "$STAGE_DIR" "$API_KEY_FILE" "$RW_DMG"; hdiutil detach "/Volumes/Haynoi" >/dev/null 2>&1 || true' EXIT
cp -R "$APP_BUNDLE" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$STAGE_DIR/.background"
cp "${ROOT}/Resources/dmg/background.png" "$STAGE_DIR/.background/background.png"

# Writable image → style via Finder AppleScript → compress to read-only UDZO.
hdiutil create -volname "Haynoi" -srcfolder "$STAGE_DIR" -ov -format UDRW -fs HFS+ "$RW_DMG" >/dev/null
hdiutil attach "$RW_DMG" -noautoopen -mountpoint "/Volumes/Haynoi" >/dev/null
osascript <<'APPLESCRIPT' || true
tell application "Finder"
  tell disk "Haynoi"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 180, 1000, 580}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "Haynoi.app" of container window to {150, 205}
    set position of item "Applications" of container window to {450, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "/Volumes/Haynoi" >/dev/null 2>&1 || true
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -ov >/dev/null
rm -f "$RW_DMG"

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

# Stable-name copy: haynoi.com links to releases/latest/download/Haynoi.dmg,
# which only resolves if every release carries an asset with this exact name.
cp "$DMG_PATH" "${ROOT}/Haynoi.dmg"
echo "==> Stable-name copy: ${ROOT}/Haynoi.dmg"
