#!/usr/bin/env bash
# Package Haynoi.app for distribution.
#
# Inputs:
#   $1 — configuration ("release" default). Reserved for future debug bundles.
# Env:
#   ARCHES — space-separated archs to build, e.g. "arm64 x86_64".
#            Default = host arch only. CI release uses universal.
#
# Output: Haynoi.app at repo root, ready for codesign + notarize.
set -euo pipefail

CONF=${1:-release}
# macOS ships bash 3.2 — no ${CONF^} uppercase expansion here.
case "$CONF" in
  release) CONF_TITLE="Release" ;;
  debug)   CONF_TITLE="Debug" ;;
  *)       CONF_TITLE="$CONF" ;;
esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  case "$HOST_ARCH" in
    arm64) ARCH_LIST=(arm64) ;;
    x86_64) ARCH_LIST=(x86_64) ;;
    *) ARCH_LIST=("$HOST_ARCH") ;;
  esac
fi

echo "==> Generating Xcode project"
xcodegen generate -q

echo "==> Building Haynoi for archs: ${ARCH_LIST[*]}"
SCHEME=Haynoi
ARCHIVE_DIR="${ROOT}/.build/archive"
rm -rf "$ARCHIVE_DIR"
mkdir -p "$ARCHIVE_DIR"

# Build per-arch archives, then merge with lipo for universal binary.
for ARCH in "${ARCH_LIST[@]}"; do
  xcodebuild archive \
    -project "${ROOT}/Haynoi.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONF_TITLE" \
    -archivePath "${ARCHIVE_DIR}/Haynoi-${ARCH}.xcarchive" \
    -arch "$ARCH" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    | grep -E "error:|warning:|BUILD" || true
done

APP_DIR="${ROOT}/Haynoi.app"
rm -rf "$APP_DIR"
cp -R "${ARCHIVE_DIR}/Haynoi-${ARCH_LIST[0]}.xcarchive/Products/Applications/Haynoi.app" "$APP_DIR"

if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
  echo "==> Merging universal binary via lipo"
  BINARY="$APP_DIR/Contents/MacOS/Haynoi"
  LIPO_INPUTS=()
  for ARCH in "${ARCH_LIST[@]}"; do
    LIPO_INPUTS+=("${ARCHIVE_DIR}/Haynoi-${ARCH}.xcarchive/Products/Applications/Haynoi.app/Contents/MacOS/Haynoi")
  done
  lipo -create -output "$BINARY" "${LIPO_INPUTS[@]}"
  echo "  lipo info: $(lipo -info "$BINARY")"
fi

# Stamp version into Info.plist. Info.plist uses $(MARKETING_VERSION) /
# $(CURRENT_PROJECT_VERSION) placeholders resolved at build time; this stamp
# is the authoritative backstop so the bundle always matches version.env.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"

echo "==> Built: $APP_DIR"
echo "    version: $MARKETING_VERSION ($BUILD_NUMBER)"
