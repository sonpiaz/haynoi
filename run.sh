#!/bin/bash
# Quick build & run Haynoi
set -e
cd "$(dirname "$0")"

echo "⚙️  Building..."
xcodegen generate -q 2>/dev/null
xcodebuild -project Haynoi.xcodeproj -scheme Haynoi -configuration Debug build 2>&1 | grep -E "error:|BUILD"

echo "🚀 Launching..."
osascript -e 'tell application "Haynoi" to quit' 2>/dev/null || true
sleep 0.5
open ~/Library/Developer/Xcode/DerivedData/Haynoi-*/Build/Products/Debug/Haynoi.app
echo "✅ Haynoi is running"
