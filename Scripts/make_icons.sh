#!/usr/bin/env bash
# Regenerates Assets/icons/*.png and AppIcon.icns from the SVG sources. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../Assets/icons"
for state in locked unlocked paused; do
    rsvg-convert -w 18 -h 18 "menubar-$state.svg" -o "menubar-$state.png"
    rsvg-convert -w 36 -h 36 "menubar-$state.svg" -o "menubar-$state@2x.png"
done
rsvg-convert -w 1024 -h 1024 AppIcon.svg -o AppIcon-1024.png
cp AppIcon-1024.png ../../docs/AppIcon-1024.png
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    rsvg-convert -w $s -h $s AppIcon.svg -o "AppIcon.iconset/icon_${s}x${s}.png"
    rsvg-convert -w $((s * 2)) -h $((s * 2)) AppIcon.svg -o "AppIcon.iconset/icon_${s}x${s}@2x.png"
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
