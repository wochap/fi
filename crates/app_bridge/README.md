# app-bridge

`app-bridge` is the narrow Flutter Rust Bridge boundary. It exposes finance
commands/queries, lifecycle streams, pairing commands/candidates/state,
trusted-device management, connection rows, and aggregate sync status.

Generated Rust and Dart files are reproducible with
`scripts/check-frb-generated.sh`. Flutter treats streams as retained state or
query invalidation; it does not calculate SAS, infer synchronization from time,
or mutate trust outside Rust commands. Infrastructure errors are mapped to safe,
actionable messages without paths, keys, secrets, ciphertext, or payload data.
