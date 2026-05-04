#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-Resources}"
ICONSET="$OUT_DIR/GSDEIcon.iconset"
ICNS="$OUT_DIR/GSDEIcon.icns"

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick 'magick' is required to generate the app icon" >&2
  exit 2
fi

mkdir -p "$ICONSET"
base_png="$ICONSET/icon_1024x1024.png"

magick -size 1024x1024 \
  'gradient:#101827-#1e3a8a' \
  \( -size 820x820 xc:none -fill '#38bdf8' -draw 'roundrectangle 0,0 820,820 180,180' \) -gravity center -compose over -composite \
  \( -size 720x720 xc:none -fill '#020617' -draw 'roundrectangle 0,0 720,720 140,140' \) -gravity center -compose over -composite \
  -fill '#0f172a' -draw 'roundrectangle 220,250 804,760 72,72' \
  -fill '#1e293b' -draw 'roundrectangle 250,290 774,720 44,44' \
  -fill '#38bdf8' -draw 'circle 330,360 330,330' \
  -fill '#7dd3fc' -draw 'circle 400,360 400,330' \
  -fill '#bae6fd' -draw 'circle 470,360 470,330' \
  -fill '#e0f2fe' -draw 'polygon 330,470 430,535 330,600' \
  -fill '#38bdf8' -draw 'roundrectangle 475,575 690,620 20,20' \
  -fill '#0ea5e9' -draw 'roundrectangle 330,660 690,700 18,18' \
  "$base_png"

make_icon() {
  local size="$1"
  local scale="$2"
  local pixels=$((size * scale))
  local suffix="${size}x${size}"
  local file
  if [[ "$scale" -eq 2 ]]; then
    file="$ICONSET/icon_${suffix}@2x.png"
  else
    file="$ICONSET/icon_${suffix}.png"
  fi
  magick "$base_png" -resize "${pixels}x${pixels}" "$file"
}

make_icon 16 1
make_icon 16 2
make_icon 32 1
make_icon 32 2
make_icon 128 1
make_icon 128 2
make_icon 256 1
make_icon 256 2
make_icon 512 1
make_icon 512 2

iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Generated $ICNS"
