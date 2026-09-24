#!/usr/bin/env bash
# Render every platform icon from the SVG sources in flutter_app/assets/icon.
#
#   icon.svg            full tile (Linux, legacy Android launcher, docs)
#   icon_background.svg Android adaptive background layer
#   icon_foreground.svg Android adaptive foreground layer
#   icon_monochrome.svg Android 13+ themed icon layer
#
# Debug builds get the same icons with an amber DEBUG ribbon: a corner ribbon on
# the full tile, a band under the glyph on the adaptive foreground (a corner
# would be cut by the launcher mask). Android picks them up from the debug
# source set; Linux installs icon-debug.png for Debug CMake builds.
#
# Requires inkscape and imagemagick (both in the NixOS system profile).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$ROOT/flutter_app/assets/icon"
RES="$ROOT/flutter_app/android/app/src/main/res"
DEBUG_RES="$ROOT/flutter_app/android/app/src/debug/res"
FONT="$ROOT/flutter_app/assets/fonts/Inter-Medium.ttf"
RIBBON="#F5A623"
RIBBON_TEXT="#232532"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() { # render <svg> <size> <out.png>
  inkscape "$1" -w "$2" -h "$2" -o "$3" >/dev/null 2>&1
}

# Master raster, used by scripts/install-linux-desktop.sh and the README.
render "$ICON_DIR/icon.svg" 1024 "$ICON_DIR/icon.png"

# Debug masters at 1024, downscaled below like the release renders.
render "$ICON_DIR/icon_foreground.svg" 1024 "$TMP/foreground.png"
magick -size 1500x150 "xc:$RIBBON" -font "$FONT" -pointsize 92 -fill "$RIBBON_TEXT" \
  -gravity center -annotate 0 DEBUG -background none -rotate 45 "$TMP/band.png"
# Corner ribbon, clipped to the tile's rounded shape.
magick "$ICON_DIR/icon.png" \
  \( -size 1024x1024 xc:none "$TMP/band.png" -gravity center -geometry +250-250 \
     -compose Over -composite +geometry "$ICON_DIR/icon.png" -compose DstIn -composite \) \
  +geometry -compose Over -composite "$ICON_DIR/icon-debug.png"
# Band inside the adaptive safe zone, below the glyph.
magick "$TMP/foreground.png" \
  \( -size 1024x112 "xc:$RIBBON" -font "$FONT" -pointsize 80 -fill "$RIBBON_TEXT" \
     -gravity center -annotate 0 DEBUG \) \
  -gravity north -geometry +0+690 -compose Over -composite "$TMP/foreground-debug.png"

# Linux window icon (X11 only; Wayland resolves by app_id -> icon theme).
render "$ICON_DIR/icon.svg" 256 "$ROOT/flutter_app/linux/runner/icon.png"
magick "$ICON_DIR/icon-debug.png" -resize 256x256 "$ROOT/flutter_app/linux/runner/icon-debug.png"

# Android. Legacy launcher icon is 48dp, adaptive layers are 108dp.
declare -A DPI=([mdpi]=1 [hdpi]=1.5 [xhdpi]=2 [xxhdpi]=3 [xxxhdpi]=4)
for d in "${!DPI[@]}"; do
  scale=${DPI[$d]}
  legacy=$(printf '%.0f' "$(echo "48 * $scale" | bc -l)")
  layer=$(printf '%.0f' "$(echo "108 * $scale" | bc -l)")
  out="$RES/mipmap-$d"
  mkdir -p "$out"
  render "$ICON_DIR/icon.svg" "$legacy" "$out/ic_launcher.png"
  render "$ICON_DIR/icon_background.svg" "$layer" "$out/ic_launcher_background.png"
  render "$ICON_DIR/icon_foreground.svg" "$layer" "$out/ic_launcher_foreground.png"
  render "$ICON_DIR/icon_monochrome.svg" "$layer" "$out/ic_launcher_monochrome.png"
  # Debug overrides; background, monochrome and the adaptive XML fall through
  # from main.
  debug_out="$DEBUG_RES/mipmap-$d"
  mkdir -p "$debug_out"
  magick "$ICON_DIR/icon-debug.png" -resize "${legacy}x${legacy}" "$debug_out/ic_launcher.png"
  magick "$TMP/foreground-debug.png" -resize "${layer}x${layer}" "$debug_out/ic_launcher_foreground.png"
done

mkdir -p "$RES/mipmap-anydpi-v26"
cat > "$RES/mipmap-anydpi-v26/ic_launcher.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
EOF

echo "icons rendered from $ICON_DIR"
