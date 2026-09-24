#!/usr/bin/env bash
# Install the fi icon and .desktop entry into the user's XDG dirs so Wayland
# compositors/bars (Hyprland, quickshell, ...) can resolve the app_id
# "com.wochap.fi" to an icon. Wayland has no per-window icon protocol; icons are
# looked up by app_id in the icon theme.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/flutter_app/assets/icon/icon.png"
APP_ID="com.wochap.fi"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

for size in 16 24 32 48 64 96 128 192 256 512; do
  mkdir -p "$ICON_DIR/${size}x${size}/apps"
  magick "$SRC" -resize "${size}x${size}" "$ICON_DIR/${size}x${size}/apps/$APP_ID.png"
done
mkdir -p "$ICON_DIR/scalable/apps"
cp "$ROOT/flutter_app/assets/icon/icon.svg" "$ICON_DIR/scalable/apps/$APP_ID.svg"

mkdir -p "$APP_DIR"
BIN="$ROOT/flutter_app/build/linux/x64/debug/bundle/fi"
sed "s|^Exec=.*|Exec=$BIN|" "$ROOT/flutter_app/linux/$APP_ID.desktop" > "$APP_DIR/$APP_ID.desktop"

command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true
command -v update-desktop-database >/dev/null && update-desktop-database "$APP_DIR" 2>/dev/null || true

echo "installed $APP_ID icon -> $ICON_DIR, desktop entry -> $APP_DIR/$APP_ID.desktop"
