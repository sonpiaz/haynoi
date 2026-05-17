#!/usr/bin/env bash
# Sign + notarize Haynoi.app, then package as zip for distribution.
#
# Requires (set as GitHub Action secrets in CI):
#   APP_IDENTITY                    — e.g. "Developer ID Application: Affitor LLC (XXXXXXXXXX)"
#   APP_STORE_CONNECT_API_KEY_P8    — contents of AuthKey_XXX.p8 file (multiline)
#   APP_STORE_CONNECT_KEY_ID        — Key ID from App Store Connect
#   APP_STORE_CONNECT_ISSUER_ID     — Issuer ID from App Store Connect
#
# Output:
#   Haynoi-<version>-universal.zip   — distribution archive (Sparkle-friendly)
#   Haynoi-<version>-universal.dSYM.zip — crash symbols for Sentry/etc.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

APP_BUNDLE="${ROOT}/Haynoi.app"
APP_NAME="Haynoi"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: $APP_BUNDLE not found — run Scripts/package_app.sh first." >&2
  exit 1
fi

APP_IDENTITY=${APP_IDENTITY:-}
if [[ -z "$APP_IDENTITY" ]]; then
  echo "ERROR: APP_IDENTITY env var required (e.g. 'Developer ID Application: Affitor LLC (XXXXXXXXXX)')" >&2
  exit 1
fi

if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" || -z "${APP_STORE_CONNECT_KEY_ID:-}" || -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "ERROR: APP_STORE_CONNECT_* env vars required for notarization." >&2
  exit 1
fi

echo "==> Signing $APP_NAME.app with: $APP_IDENTITY"
codesign --force --timestamp --options runtime \
  --entitlements "${ROOT}/Resources/Haynoi.entitlements" \
  --sign "$APP_IDENTITY" \
  "$APP_BUNDLE"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" || true  # warns until notarized

echo "==> Preparing notarization zip"
NOTARIZE_ZIP="/tmp/${APP_NAME}-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

echo "==> Writing API key to /tmp"
API_KEY_FILE="/tmp/haynoi-api-key.p8"
trap 'rm -f "$API_KEY_FILE" "$NOTARIZE_ZIP"' EXIT
echo "$APP_STORE_CONNECT_API_KEY_P8" | sed 's/\\n/\n/g' > "$API_KEY_FILE"

echo "==> Submitting to Apple notary (this can take 1-10 min)"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --key "$API_KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

echo "==> Stapling notarization ticket to app"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

echo "==> Verifying notarized app"
spctl --assess --type execute --verbose "$APP_BUNDLE"

# Final distribution archive (Sparkle expects .zip).
DIST_ZIP="${ROOT}/Haynoi-${MARKETING_VERSION}-universal.zip"
rm -f "$DIST_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DIST_ZIP"

# Crash symbols (for Sentry/Crashlytics).
DSYM_DIR=".build/archive/Haynoi-$(uname -m).xcarchive/dSYMs/Haynoi.app.dSYM"
if [[ -d "$DSYM_DIR" ]]; then
  DSYM_ZIP="${ROOT}/Haynoi-${MARKETING_VERSION}-universal.dSYM.zip"
  rm -f "$DSYM_ZIP"
  ditto -c -k --sequesterRsrc "$DSYM_DIR" "$DSYM_ZIP"
fi

echo "==> Distribution archive: $DIST_ZIP"
ls -lh "$DIST_ZIP"
