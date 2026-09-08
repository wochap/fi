# app-core

`app-core` is Fi's UI-independent application backend. It owns the finance
domain, Automerge root lifecycle, durable SQLite projection, permanent device
identity, private discovery, secure pairing, pinned Quinn transport, trusted
device control, discovery-secret rotation, and foreground networking policy.

The crate contains no Flutter dependency. Platform code calls it through
[`app_bridge`](../app_bridge/README.md), and its generic document persistence
and replication are delegated to
[`automerge-repo`](../automerge_repo/README.md).

## Software stack and dependencies

| Area | Crates / technology | Purpose |
| --- | --- | --- |
| Async runtime | Tokio, `async-trait` | Application tasks, actors, ports, and event streams |
| Authoritative data | Automerge, `automerge-repo` | Local-first documents and peer convergence |
| Query projection | `rusqlite` with bundled SQLite | Rebuildable transaction/category views and aggregates |
| Peer transport | Quinn, Rustls, `x509-parser`, `rcgen` | Authenticated QUIC sessions and certificate identity |
| LAN discovery | `mdns-sd`, `data-encoding` | Private group selectors and peer endpoints |
| Identity and pairing | Ed25519, HKDF, HMAC, SHA-2, `rand_core`, `subtle` | Device keys, transcript-derived SAS, and provisioning |
| Secret storage | `secret-service`, `zeroize` | Linux secure storage and plaintext cleanup; Android uses a platform adapter |
| Data and diagnostics | Serde, UUID v7, `thiserror`, Tracing | Stable models, typed errors, identifiers, and safe diagnostics |

Dependency versions shared with the application are pinned in the workspace
[`../../Cargo.toml`](../../Cargo.toml).

## Data ownership

Durable state is intentionally split:

```text
<application-data>/
├── automerge/documents/   authoritative finance snapshots
├── control.sqlite         bootstrap, public trust, pairing, and discovery state
└── read-model.sqlite      disposable query projection
```

Automerge snapshots are authoritative. `read-model.sqlite` is rebuilt whenever
it is absent, corrupt, or stale. `control.sqlite` stores bootstrap state, public
identity and trust records, connection metadata, pairing journals, and
discovery epochs. Private Ed25519 keys and discovery-secret bytes remain behind
the `SecureKeyStore` port and are never written to SQLite.

## Module map

| Module | Responsibility |
| --- | --- |
| `domain` | Finance commands, entities, filters, and validation |
| `application` | `AppCore` orchestration and public application API |
| `projection` | SQLite read model, checkpoints, rebuilds, and aggregates |
| `control` / `adapters` | Durable control records and platform implementations |
| `identity` | Permanent device identity and secure-store ports |
| `discovery` / `discovery_control` | Private DNS-SD and secret rotation messages |
| `pairing` / `pairing_manager` | SAS state machine, provisioning, and trust commit |
| `quinn_transport` / `routing` | Pinned QUIC sessions, endpoint choice, and sync state |
| `events` / `ports` | Typed lifecycle notifications and infrastructure boundaries |

## Security and lifecycle invariants

Revocation commits local revoked status before closing the peer and removing
its routes. A new discovery secret and monotonic epoch are then journaled and
stored, distributed only across pinned trusted control streams, and
acknowledged only after recipient persistence. The previous selector is
browse-only during a bounded migration window and its secret is removed at
expiry.

Operational tracing uses stable public identifiers and state names. Secret
wrappers redact `Debug` output and zeroize owned plaintext. Finance payloads,
SAS codes, private keys, discovery secrets, TLS/exporter material, and
provisioning bytes must never appear as tracing fields.

## Development build

From the workspace root:

```sh
nix develop
cargo build -p app-core
cargo test -p app-core
```

Useful focused integration tests are:

```sh
cargo test -p app-core --test finance_core
cargo test -p app-core --test private_pairing
cargo test -p app-core --test quinn_core
cargo test -p app-core --test secret_tracing
```

## Production build

Build the optimized Rust library with:

```sh
cargo build -p app-core --release
```

The result is an internal library under `target/release/`, not a standalone
service or executable. Fi applications consume it through `app_bridge`; build
the Linux or Android application from `flutter_app` to obtain an installable
artifact.

## Quality checks

```sh
cargo fmt --all --check
cargo clippy -p app-core --all-targets --all-features -- -D warnings
cargo test -p app-core
```

The end-to-end storage, permission, pairing, recovery, and platform contract is
documented in [`../../docs/operations.md`](../../docs/operations.md).
