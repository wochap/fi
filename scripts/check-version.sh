#!/usr/bin/env bash
set -euo pipefail

# Fails when the Flutter manifest MAJOR.MINOR.PATCH and the Cargo workspace
# version differ. The pubspec is the source of truth; Cargo mirrors it.
cd "$(dirname "$0")/.."

pubspec_version="$(sed -n 's/^version:[[:space:]]*\([0-9]*\.[0-9]*\.[0-9]*\)+[0-9]*[[:space:]]*$/\1/p' flutter_app/pubspec.yaml)"
cargo_version="$(awk '
  /^\[/ { in_section = ($0 == "[workspace.package]") }
  in_section && /^version[[:space:]]*=/ { gsub(/.*=[[:space:]]*"|".*/, ""); print; exit }
' Cargo.toml)"

if [[ -z "$pubspec_version" || -z "$cargo_version" || "$pubspec_version" != "$cargo_version" ]]; then
  echo "version mismatch: flutter_app/pubspec.yaml=${pubspec_version:-<missing>} Cargo.toml [workspace.package]=${cargo_version:-<missing>}" >&2
  exit 1
fi
echo "version ok: $pubspec_version"
