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

Application features—including finance domain logic, projections, identity,
pairing, discovery, platform integration, and authentication—are intentionally
deferred. The generic Repo crate must not acquire those concerns.

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
