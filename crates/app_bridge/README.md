# app-bridge

`app_bridge` is Fi's narrow, platform-neutral Flutter Rust Bridge boundary. It
maps Flutter calls and streams onto `app-core` without exposing Automerge,
SQLite, Quinn, repository handles, or other infrastructure types.

The crate builds as an `rlib`, `cdylib`, and `staticlib`. Flutter's Cargokit
integration selects and packages the appropriate native artifact for Linux or
Android.

## Responsibilities

- Initialize and shut down the Rust application core.
- Expose finance commands, queries, and lifecycle streams.
- Expose pairing candidates/state, trusted-device commands, connection rows,
  and aggregate synchronization status.
- Convert domain values into bridge-safe DTOs.
- Map internal failures to actionable messages without leaking paths, keys,
  secrets, ciphertext, or finance payloads.

Flutter treats streams as retained state or query invalidation. It does not
calculate SAS values, infer synchronization from time, or mutate trust outside
Rust commands.

## Software stack and dependencies

| Dependency | Purpose |
| --- | --- |
| [`app-core`](../app_core/README.md) | Finance, persistence, trust, pairing, and network behavior |
| `flutter_rust_bridge` 2.12 | Dart bindings, FFI dispatch, and async stream support |
| Tokio | Async runtime used by bridge entry points |
| `tracing-subscriber` | Safe native diagnostic initialization |
| `thiserror` | Bridge-facing error definitions |

Public functions and DTOs live in `src/api/`. Generated Rust dispatch code is
in `src/frb_generated.rs`; generated Dart files live in
`../../flutter_app/lib/src/rust/`.

## Development build

Enter the repository's Nix shell and build or test this package from the
workspace root:

```sh
nix develop
cargo build -p app_bridge
cargo test -p app_bridge
```

After changing anything in `src/api/`, regenerate and verify both sides of the
boundary:

```sh
scripts/check-frb-generated.sh
```

The script runs code generation, formats Rust, and fails if generated Rust or
Dart output differs from the committed files.

## Production build

Build optimized native library forms directly with:

```sh
cargo build -p app_bridge --release
```

Linux artifacts are placed under `target/release/`, including
`libapp_bridge.so` and Rust library forms. These files alone are not the Fi
application. Supported Linux and Android deliverables must be built from
`flutter_app`, which invokes this crate through Cargokit:

```sh
cd flutter_app
flutter build linux --release
flutter build apk --release
```

See [`../../flutter_app/README.md`](../../flutter_app/README.md) for device,
signing, packaging, and installation details.

## Boundary checks

```sh
cargo test -p app_bridge
cargo clippy -p app_bridge --all-targets --all-features -- -D warnings
```

The crate includes a dependency-boundary test that rejects infrastructure types
in its public API surface.
