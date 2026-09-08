#!/usr/bin/env bash
set -euo pipefail

bundle="flutter_app/build/linux/x64/debug/bundle"
binary="$bundle/fi"
test -x "$binary"
test -f "$bundle/lib/libapp_bridge.so"

runtime_dir="$(mktemp -d)"
weston_log="$runtime_dir/weston.log"
app_log="$runtime_dir/app.log"
chmod 700 "$runtime_dir"
XDG_RUNTIME_DIR="$runtime_dir" weston \
  --backend=headless-backend.so \
  --socket=fi-wayland \
  --idle-time=0 >"$weston_log" 2>&1 &
weston_pid=$!
trap 'kill "$weston_pid" 2>/dev/null || true; rm -rf "$runtime_dir"' EXIT

for _ in $(seq 1 100); do
  test -S "$runtime_dir/fi-wayland" && break
  sleep 0.05
done
test -S "$runtime_dir/fi-wayland"

set +e
XDG_RUNTIME_DIR="$runtime_dir" \
  XDG_DATA_HOME="$runtime_dir/data" \
  WAYLAND_DISPLAY=fi-wayland \
  GDK_BACKEND=wayland \
  timeout 5 "$binary" >"$app_log" 2>&1
status=$?
set -e

if test "$status" -ne 0 && test "$status" -ne 124; then
  sed -n '1,200p' "$app_log"
  exit "$status"
fi

test -f "$runtime_dir/data/com.gean.fi/control.sqlite"
