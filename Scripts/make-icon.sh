#!/bin/bash
# Draws the app icon and builds AppIcon.icns.
#
# Generated from this script rather than checked in as a binary, so it can be
# read, changed and rebuilt. Uses only what ships with macOS: a PDF drawn by
# hand here, rasterised by sips, assembled by iconutil.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-dist/AppIcon.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# One source at a mark radiating to many receivers: what multicast is.
cat > "$WORK/icon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3d8ae8"/>
      <stop offset="1" stop-color="#1f5fb0"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="1024" height="1024" rx="228" fill="url(#bg)"/>
  <g fill="none" stroke="#ffffff" stroke-linecap="round" opacity="0.92">
    <circle cx="512" cy="512" r="118" stroke-width="34"/>
    <path d="M 302 302 A 297 297 0 0 0 302 722" stroke-width="40" opacity="0.75"/>
    <path d="M 722 302 A 297 297 0 0 1 722 722" stroke-width="40" opacity="0.75"/>
    <path d="M 196 196 A 447 447 0 0 0 196 828" stroke-width="40" opacity="0.42"/>
    <path d="M 828 196 A 447 447 0 0 1 828 828" stroke-width="40" opacity="0.42"/>
  </g>
  <circle cx="512" cy="512" r="46" fill="#ffffff"/>
</svg>
SVG

# sips reads SVG on recent macOS; fall back to a PDF wrapper if it does not.
if ! sips -s format png --resampleHeightWidth 1024 1024 "$WORK/icon.svg" --out "$WORK/1024.png" >/dev/null 2>&1; then
    echo "error: this macOS sips cannot rasterise SVG; install librsvg or supply a PNG" >&2
    exit 1
fi

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 64 128 256 512 1024; do
    sips -z "$size" "$size" "$WORK/1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
done
# iconutil wants the @2x names too.
cp "$SET/icon_32x32.png"     "$SET/icon_16x16@2x.png"
cp "$SET/icon_64x64.png"     "$SET/icon_32x32@2x.png"
cp "$SET/icon_256x256.png"   "$SET/icon_128x128@2x.png"
cp "$SET/icon_512x512.png"   "$SET/icon_256x256@2x.png"
cp "$SET/icon_1024x1024.png" "$SET/icon_512x512@2x.png"
rm "$SET/icon_64x64.png" "$SET/icon_1024x1024.png"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
echo "icon -> $OUT"
