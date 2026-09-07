# app-core

`app-core` owns the finance domain, Automerge root lifecycle, durable SQLite
projection, permanent identity, pinned Quinn transport, private discovery,
pairing, device control, discovery-secret rotation, and foreground networking
policy.

Durable state is split deliberately: Automerge snapshots are authoritative
finance data; `control.sqlite` stores bootstrap, public identity/trust,
connection metadata, pairing journals, and discovery epochs; `read-model.sqlite`
is disposable and rebuilt whenever absent, corrupt, or stale. Private Ed25519
and discovery-secret bytes are held behind `SecureKeyStore`, never in SQLite.

Revocation commits local revoked status before closing the peer and removing its
routes. A new discovery secret and monotonic epoch are then journaled and stored,
distributed only across pinned trusted control streams, and acknowledged only
after recipient persistence. The previous selector is browse-only during a
bounded migration window and its secret is removed at expiry.

Operational tracing uses stable public identifiers and state names. Secret
wrappers redact Debug output and zeroize owned plaintext; finance payloads, SAS,
private keys, discovery secrets, TLS/exporter material, and provisioning bytes
must never be fields in tracing events.
