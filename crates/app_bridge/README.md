# app-bridge

`app_bridge` is Fi's narrow Flutter Rust Bridge boundary. It exposes finance,
lifecycle, pairing, trusted-device, and sync APIs without leaking Automerge,
SQLite, Quinn, or repository types to Dart.

## Software stack

- [`app-core`](../app_core/README.md): application behavior.
- `flutter_rust_bridge` 2.12: FFI dispatch, DTOs, and streams.
- Tokio, `tracing-subscriber`, and `thiserror`: async execution, diagnostics,
  and safe bridge errors.

The crate builds as an `rlib`, `cdylib`, and `staticlib`. Public APIs live in
`src/api/`; generated Rust and Dart bindings live in `src/frb_generated.rs` and
`../../flutter_app/lib/src/rust/`.

## Build and test

From the repository root:

```sh
nix develop
cargo build -p app_bridge
cargo test -p app_bridge
cargo clippy -p app_bridge --all-targets --all-features -- -D warnings
```

Optimized library build:

```sh
cargo build -p app_bridge --release
```

After changing `src/api/`, verify generated bindings:

```sh
scripts/check-frb-generated.sh
```

Installable Linux and Android artifacts are produced by Flutter, not this crate.
See the [Flutter build guide](../../flutter_app/README.md).
