# app-core

`app-core` is Fi's UI-independent backend. It owns collection schemas and typed
records, application lifecycle, SQLite projections, device identity, private
discovery, pairing, trusted-device control, and authenticated QUIC
synchronization.

Flutter calls it through [`app_bridge`](../app_bridge/README.md). Generic
Automerge persistence and replication live in
[`automerge-repo`](../automerge_repo/README.md).

## Software stack

| Area | Technology |
| --- | --- |
| Async and data | Tokio, Automerge, `automerge-repo` |
| Projection | `rusqlite` with bundled SQLite |
| Networking | Quinn, Rustls, private DNS-SD |
| Identity and pairing | Ed25519, HKDF, HMAC, SHA-2 |
| Secrets | Linux Secret Service, Android platform adapter, `zeroize` |
| Models and diagnostics | Serde, UUID, `thiserror`, Tracing |

## Storage model

```text
<application-data>/
├── automerge/documents/   authoritative schema and record snapshots
├── control.sqlite         bootstrap, trust, pairing, and discovery metadata
└── read-model.sqlite      disposable query projection
```

Private keys and discovery secrets remain behind `SecureKeyStore`; they are
never stored in SQLite. Operational details and recovery behavior are in
[`../../docs/operations.md`](../../docs/operations.md).

## Build and test

From the repository root:

```sh
nix develop
cargo build -p app-core
cargo test -p app-core
cargo clippy -p app-core --all-targets --all-features -- -D warnings
```

Optimized library build:

```sh
cargo build -p app-core --release
```

This produces an internal Rust library, not an executable. Use the
[Flutter build guide](../../flutter_app/README.md) for installable applications.

## Security invariants

- Revocation is durable before disconnect and route removal.
- Discovery-secret rotation excludes revoked devices.
- Pairing trust is committed only after SAS confirmation.
- Traces must never contain record values, SAS codes, private keys, discovery
  secrets, TLS material, or provisioning bytes.
