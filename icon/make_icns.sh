#!/usr/bin/env bash
#
# make_icns.sh — turn icon/icon.svg into icon/DataSyncer.icns (every size macOS wants, 16 px to 1024 px).
#
# Needs a browser that can draw the SVG (Chrome, Edge, Brave or Arc) and the Mac's own sips and iconutil.
# The result is committed, so this only has to run again when icon.svg changes.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVG="$HERE/icon.svg"; OUT="$HERE/DataSyncer.icns"; SET="$HERE/DataSyncer.iconset"; PNG="$HERE/icon-1024.png"

browser=""
for b in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
         "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" "/Applications/Arc.app/Contents/MacOS/Arc"; do
  [[ -x "$b" ]] && { browser="$b"; break; }
done
[[ -n "$browser" ]] || { echo "No Chrome/Edge/Brave/Arc found to draw the icon with." >&2; exit 1; }

# a page with the SVG filling a 1024×1024 window, drawn once at 1024 px
page="$(mktemp -d)/icon.html"
cat > "$page" <<EOF
<html><body style="margin:0;background:transparent"><img src="file://$SVG" width="1024" height="1024"></body></html>
EOF
"$browser" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$PNG" "file://$page" >/dev/null 2>&1
[[ -s "$PNG" ]] || { echo "The browser did not produce the picture." >&2; exit 1; }

rm -rf "$SET"; mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PNG" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$PNG" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$OUT"
rm -rf "$SET"
echo "Wrote $OUT"
