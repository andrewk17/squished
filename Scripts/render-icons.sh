#!/usr/bin/env bash
# Renders Resources/AppIcon.icns and the site's PNG/ICO icons from the SVG sources:
#   Resources/AppIcon.svg         the 1024 px macOS icon (64 px and up)
#   Resources/AppIcon-small.svg   artwork drawn for 16 and 32 px
#   Resources/AppIcon-square.svg  full-bleed square for apple-touch-icon.png
#   site/public/favicon.svg       the site icon and favicon.ico (same art as the small icon)
# Needs macOS (iconutil, sips), Google Chrome and ImageMagick.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Chrome keeps transparent corners; Quick Look and ImageMagick's SVG renderer don't.
render() { # svg size out.png
    "$CHROME" --headless=new --hide-scrollbars --force-device-scale-factor=1 \
        --default-background-color=00000000 --window-size="$2,$2" \
        --screenshot="$3" "file://$1" >/dev/null 2>&1
}
scale() { sips -z "$2" "$2" "$1" --out "$3" >/dev/null; }
# Small sizes are rasterised at their true size so the pixel hints in the small
# artwork survive (scaling a large render down blurs them).
true_size() { # svg size out.png
    printf '<body style="margin:0"><img src="file://%s" width=%s height=%s>' "$1" "$2" "$2" > "$TMP/t.html"
    render "$TMP/t.html" 512 "$TMP/t.png"
    magick "$TMP/t.png" -crop "$2x$2+0+0" +repage "$3"
}

render "$ROOT/Resources/AppIcon.svg" 1024 "$TMP/large.png"
# Chrome has a minimum window size, so render at 512 and scale down.
render "$ROOT/Resources/AppIcon-square.svg" 512 "$TMP/square.png"

SET="$TMP/AppIcon.iconset"
mkdir "$SET"
true_size "$ROOT/Resources/AppIcon-small.svg" 16 "$SET/icon_16x16.png"
true_size "$ROOT/Resources/AppIcon-small.svg" 32 "$SET/icon_16x16@2x.png"
cp "$SET/icon_16x16@2x.png" "$SET/icon_32x32.png"
for s in 64 128 256 512 1024; do scale "$TMP/large.png" $s "$TMP/l$s.png"; done
cp "$TMP/l64.png" "$SET/icon_32x32@2x.png"
cp "$TMP/l128.png" "$SET/icon_128x128.png"
cp "$TMP/l256.png" "$SET/icon_128x128@2x.png"
cp "$TMP/l256.png" "$SET/icon_256x256.png"
cp "$TMP/l512.png" "$SET/icon_256x256@2x.png"
cp "$TMP/l512.png" "$SET/icon_512x512.png"
cp "$TMP/l1024.png" "$SET/icon_512x512@2x.png"
scale "$TMP/square.png" 180 "$ROOT/site/public/apple-touch-icon.png"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"

for s in 16 32 48; do true_size "$ROOT/site/public/favicon.svg" $s "$TMP/f$s.png"; done
magick "$TMP/f16.png" "$TMP/f32.png" "$TMP/f48.png" "$ROOT/site/public/favicon.ico"
printf 'Rendered AppIcon.icns, apple-touch-icon.png and favicon.ico\n'
