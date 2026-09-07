# fi workspace

This repository is a virtual Cargo workspace with three Rust members:

- `crates/automerge_repo` owns the reusable Automerge repository, persistence,
  synchronization, lifecycle, protocol, transport abstractions, and their tests.
- `crates/app_core` owns the local finance application backend and depends on
  `automerge-repo`.
- `crates/app_bridge` is the generated Flutter-facing adapter and depends on
  `app-core`.

The dependency direction is strictly:

```text
Flutter -> app_bridge -> app_core -> automerge_repo -> automerge
```

Application finance logic, SQLite projections, permanent device identity,
private discovery, SAS pairing, pinned Quinn sessions, device revocation, and
foreground platform lifecycle are owned above the generic Repo crate. The Repo
crate intentionally does not acquire those application concerns.

The delivered alpha is foreground-only on Android: LAN discovery and sync start
on resume and stop on backgrounding. It does not install WorkManager, a
foreground service, or another always-running daemon. See
[`docs/operations.md`](docs/operations.md) for storage, pairing, permissions,
recovery, and platform verification.

Run workspace checks from this directory:

```sh
cargo fmt --all --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

The Nix development shell provides Flutter, Rust, Android, Linux, and FRB
code-generation tools. Regenerate bridge bindings from the repository root with:

```sh
nix develop -c scripts/check-frb-generated.sh
```

Run Dart formatting, analysis, and tests together with:

```sh
nix develop -c scripts/check-flutter.sh
```
