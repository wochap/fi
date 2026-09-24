#!/usr/bin/env bash
# Install the fi icons and .desktop entries into the user's XDG dirs so Wayland
# compositors/bars (Hyprland, quickshell, ...) can resolve an app_id to an icon.
# Wayland has no per-window icon protocol; icons are looked up by app_id in the
# icon theme.
#
# Two entries: "com.wochap.fi" runs the release bundle, "com.wochap.fi.debug"
# (the app_id of Debug builds, see flutter_app/linux/CMakeLists.txt) runs the
# debug bundle and shows the DEBUG-ribbon icon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.wochap.fi"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
BUILD="$ROOT/flutter_app/build/linux/x64"

install_entry() { # install_entry <app_id> <name> <icon.png> <binary>
  local id="$1" name="$2" src="$3" bin="$4"
  for size in 16 24 32 48 64 96 128 192 256 512; do
    mkdir -p "$ICON_DIR/${size}x${size}/apps"
    magick "$src" -resize "${size}x${size}" "$ICON_DIR/${size}x${size}/apps/$id.png"
  done
  sed -e "s|^Exec=.*|Exec=$bin|" \
    -e "s|^Name=.*|Name=$name|" \
    -e "s|^Icon=.*|Icon=$id|" \
    -e "s|^StartupWMClass=.*|StartupWMClass=$id|" \
    "$ROOT/flutter_app/linux/$APP_ID.desktop" > "$APP_DIR/$id.desktop"
}

mkdir -p "$APP_DIR" "$ICON_DIR/scalable/apps"
install_entry "$APP_ID" "fi" "$ROOT/flutter_app/assets/icon/icon.png" "$BUILD/release/bundle/fi"
cp "$ROOT/flutter_app/assets/icon/icon.svg" "$ICON_DIR/scalable/apps/$APP_ID.svg"
install_entry "$APP_ID.debug" "fi (debug)" "$ROOT/flutter_app/assets/icon/icon-debug.png" "$BUILD/debug/bundle/fi"

command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true
command -v update-desktop-database >/dev/null && update-desktop-database "$APP_DIR" 2>/dev/null || true

echo "installed $APP_ID and $APP_ID.debug icons -> $ICON_DIR, desktop entries -> $APP_DIR"
