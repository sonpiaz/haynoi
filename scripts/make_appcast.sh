#!/usr/bin/env bash
# Generate appcast.xml entry for the current version + sign zip with EdDSA.
#
# Inputs:
#   $1 — path to the signed/notarized zip (e.g. Haynoi-0.1.0-universal.zip)
# Env:
#   SPARKLE_PRIVATE_KEY_FILE — path to ed25519 private key (one base64 line).
#                              In CI, written from secret SPARKLE_PRIVATE_KEY.
#
# Output: updates ./appcast.xml with new <item>. Caller commits + pushes.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

ZIP=${1:?"Usage: $0 Haynoi-<version>-universal.zip"}
if [[ ! -f "$ZIP" ]]; then
  echo "ERROR: $ZIP not found." >&2
  exit 1
fi

PRIVATE_KEY_FILE=${SPARKLE_PRIVATE_KEY_FILE:-}
if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "ERROR: SPARKLE_PRIVATE_KEY_FILE env var required." >&2
  echo "       In CI: write secret SPARKLE_PRIVATE_KEY to a temp file first." >&2
  exit 1
fi
if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
  echo "ERROR: Sparkle key file not found: $PRIVATE_KEY_FILE" >&2
  exit 1
fi

# Find generate_appcast — bundled with Sparkle artifacts after Xcode resolves SPM.
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" -type f 2>/dev/null | head -1)
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "ERROR: generate_appcast not found. Build the app first (xcodebuild) so Sparkle SPM artifacts are extracted." >&2
  exit 1
fi

# Update zips download from GitHub release assets; the appcast itself is served
# at https://haynoi.com/appcast.xml (must match SUFeedURL in Info.plist).
DOWNLOAD_URL_PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-"https://github.com/sonpiaz/haynoi/releases/download/v${MARKETING_VERSION}/"}
FEED_URL="https://haynoi.com"

WORK_DIR=$(mktemp -d /tmp/haynoi-appcast.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$ZIP" "$WORK_DIR/"
if [[ -f "$ROOT/appcast.xml" ]]; then
  cp "$ROOT/appcast.xml" "$WORK_DIR/appcast.xml"
fi

# Convert CHANGELOG section for current version → HTML release notes.
NOTES_HTML="${WORK_DIR}/$(basename "$ZIP" .zip).html"
if [[ -x "$ROOT/scripts/changelog-to-html.sh" ]]; then
  "$ROOT/scripts/changelog-to-html.sh" "$MARKETING_VERSION" >"$NOTES_HTML"
fi

echo "==> Running generate_appcast"
"$GENERATE_APPCAST" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$FEED_URL" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  "$WORK_DIR"

cp "$WORK_DIR/appcast.xml" "$ROOT/appcast.xml"
echo "==> appcast.xml updated"
