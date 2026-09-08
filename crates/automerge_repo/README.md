# automerge-repo

`automerge-repo` is a reusable Rust repository around Automerge 0.11. Each
loaded document is owned by a bounded Tokio actor; a coordinator manages
bootstrap, persistence, lifecycle, and peer replication through
application-provided ports.

Fi-specific finance, identity, discovery, and transport policy belongs to
[`app-core`](../app_core/README.md).

## Software stack

- Automerge: conflict-free documents and sync protocol.
- Tokio: actors, channels, storage workers, and lifecycle coordination.
- `async-trait`: storage and authenticated transport ports.
- `bytes`, UUID, and `thiserror`: frames, identifiers, and typed errors.

The crate does not open sockets or choose an application database.

## Basic API

Fresh storage requires an explicit initialize or join decision:

```no_run
use std::sync::Arc;
use automerge::{transaction::Transactable, ROOT};
use automerge_repo::{testing::{MemoryStore, MemoryTransport}, Repo, RepoConfig};

# async fn example() -> automerge_repo::Result<()> {
let documents = Arc::new(MemoryStore::default());
let control = Arc::new(MemoryStore::default());
let (transport, _remote) = MemoryTransport::pair("local", "remote", 128);
let repo = Repo::open(documents, control, transport, RepoConfig::default()).await?;

repo.initialize_new().await?;
let document = repo.create().await?;
document.change(|tx| {
    tx.put(ROOT, "title", "Offline first")
        .map_err(|error| automerge_repo::Error::Change(error.to_string()))
}).await?;

repo.flush().await?;
repo.shutdown().await?;
# Ok(())
# }
```

Read and change callbacks are synchronous and must not block. Changes are
serialized per document; separate document actors remain independent.

## Contracts

- `StorageAdapter` stores complete, atomically replaced Automerge snapshots.
- `ControlStore` persists bootstrap transitions separately from documents.
- `NetworkTransport` provides authenticated peer IDs and reliable, ordered,
  complete frames with bounded backpressure.
- `flush` captures accepted revisions and waits for their durability barriers.
- `shutdown` stops new work, drains accepted commands, flushes, and closes all
  handles.
- `remove_local` is local maintenance, not distributed deletion.
- A lagging event subscriber must rebuild its view with `DocHandle::read`.

Automatic snapshots are debounced and retried after failure. Transaction commit
and peer convergence are not themselves crash-durability guarantees.

## Filesystem storage

`FilesystemStorage` uses:

```text
<repo>/
├── automerge/<document-uuid>.automerge
└── control/bootstrap-v1.bin
```

On Unix, directories use mode `0700` and files use `0600`. Replacements use a
temporary sibling, file sync, atomic rename, and directory sync.

## Build and test

From the repository root:

```sh
nix develop
cargo build -p automerge-repo
cargo test -p automerge-repo
cargo clippy -p automerge-repo --all-targets --all-features -- -D warnings
```

Optimized library and API documentation:

```sh
cargo build -p automerge-repo --release
cargo doc -p automerge-repo --no-deps
```

The output is an embeddable Rust library, not a standalone service.
