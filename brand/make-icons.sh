#!/bin/bash
# Regenerate all raster brand assets from brand/haynoi-icon.svg.
# Outputs: Resources/Assets.xcassets/AppIcon.appiconset/*.png + site/icon.png
# Requires: rsvg-convert (brew install librsvg)
set -euo pipefail

cd "$(dirname "$0")/.."
SRC=brand/haynoi-icon.svg
OUT=Resources/Assets.xcassets/AppIcon.appiconset

for size in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $size -h $size "$SRC" -o "$OUT/icon_${size}x${size}.png"
done

rsvg-convert -w 512 -h 512 "$SRC" -o site/icon.png

echo "Done: $OUT/icon_{16..1024}.png + site/icon.png"
