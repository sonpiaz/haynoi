#!/bin/bash
# Build Haynoi.app and create a DMG for distribution
set -e
cd "$(dirname "$0")/.."

echo "⚙️  Building release..."
xcodegen generate -q
xcodebuild -project Haynoi.xcodeproj -scheme Haynoi -configuration Release build 2>&1 | grep -E "error:|BUILD"

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/Haynoi-*/Build/Products/Release -name "Haynoi.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "❌ Haynoi.app not found in Release build"
    exit 1
fi

echo "📦 Creating DMG..."
DMG_DIR="dist"
mkdir -p "$DMG_DIR"
DMG_PATH="$DMG_DIR/Haynoi.dmg"
rm -f "$DMG_PATH"

# Create temp dir for DMG contents
TEMP_DIR=$(mktemp -d)
cp -R "$APP_PATH" "$TEMP_DIR/"
ln -s /Applications "$TEMP_DIR/Applications"

hdiutil create -volname "Haynoi" -srcfolder "$TEMP_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$TEMP_DIR"

echo "✅ DMG created: $DMG_PATH"
echo "   Size: $(du -h "$DMG_PATH" | cut -f1)"
