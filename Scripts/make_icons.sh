#!/usr/bin/env bash
# Regenerates Assets/icons/*.png and AppIcon.icns from the SVG sources. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../Assets/icons"

# Keep only the image chunks (IHDR, PLTE, tRNS, IDAT, IEND): no colour profile, EXIF, background or text metadata.
# For .icns files, the same for every embedded PNG, and iconutil's "info" element is dropped.
strip_png() {
    python3 - "$@" <<'PY'
import struct, sys
def png(data):
    out, i = [data[:8]], 8
    while i < len(data):
        size, kind = struct.unpack(">I4s", data[i:i + 8])
        if kind in (b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND"):
            out.append(data[i:i + 12 + size])
        i += 12 + size
    return b"".join(out)
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    if path.endswith(".icns"):
        elements, i = [], 8
        while i < len(data):
            kind, size = struct.unpack(">4sI", data[i:i + 8])
            body = data[i + 8:i + size]
            if kind != b"info":
                body = png(body) if body.startswith(b"\x89PNG") else body
                elements.append(kind + struct.pack(">I", len(body) + 8) + body)
            i += size
        body = b"".join(elements)
        data = b"icns" + struct.pack(">I", len(body) + 8) + body
    else:
        data = png(data)
    open(path, "wb").write(data)
PY
}

# menubar-locked is a template image; notebook + unlocked/paused are layered at runtime (tinted notebook, colour badge).
for name in locked notebook unlocked paused; do
    rsvg-convert -w 18 -h 18 "menubar-$name.svg" -o "menubar-$name.png"
    rsvg-convert -w 36 -h 36 "menubar-$name.svg" -o "menubar-$name@2x.png"
done
rsvg-convert -w 1024 -h 1024 AppIcon.svg -o AppIcon-1024.png
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
    rsvg-convert -w $s -h $s AppIcon.svg -o "AppIcon.iconset/icon_${s}x${s}.png"
    rsvg-convert -w $((s * 2)) -h $((s * 2)) AppIcon.svg -o "AppIcon.iconset/icon_${s}x${s}@2x.png"
done
strip_png menubar-*.png AppIcon-1024.png AppIcon.iconset/*.png ../../docs/screenshots/*.png
cp AppIcon-1024.png ../../docs/AppIcon-1024.png
iconutil -c icns AppIcon.iconset -o AppIcon.icns
strip_png AppIcon.icns
rm -rf AppIcon.iconset
