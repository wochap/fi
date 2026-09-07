#!/usr/bin/env bash
set -euo pipefail

test -f Cargo.toml
snapshot_dir="$(mktemp -d)"
trap 'rm -rf "$snapshot_dir"' EXIT
cp crates/app_bridge/src/frb_generated.rs "$snapshot_dir/frb_generated.rs"
cp -R flutter_app/lib/src/rust "$snapshot_dir/dart"
(
  cd flutter_app
  flutter_rust_bridge_codegen generate
)
cargo fmt --all
diff -u "$snapshot_dir/frb_generated.rs" crates/app_bridge/src/frb_generated.rs
diff -ru "$snapshot_dir/dart" flutter_app/lib/src/rust
