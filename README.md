# fi-repo

`fi-repo` is a native Rust repository around Automerge 0.11. Each loaded
document is exclusively owned by a bounded Tokio actor. A coordinator manages
explicit bootstrap and whole-collection replication over application-supplied
authenticated transport and storage ports.

## Stage 1 API

Fresh storage requires an explicit application decision. Initialize the first
device, then create and mutate documents through actor handles:

```no_run
use std::sync::Arc;
use automerge::{ROOT, transaction::Transactable};
use fi_repo::{Error, Repo, RepoConfig, testing::{MemoryStore, MemoryTransport}};

# async fn example() -> fi_repo::Result<()> {
let documents = Arc::new(MemoryStore::default());
let control = Arc::new(MemoryStore::default());
let (transport, _remote) = MemoryTransport::pair("local", "remote", 128);
let repo = Repo::open(documents, control, transport, RepoConfig::default()).await?;
let _root = repo.initialize_new().await?;

let document = repo.create().await?;
let mut changes = document.subscribe();
document.change(|tx| {
    tx.put(ROOT, "title", "Offline first")
        .map_err(|error| Error::Change(error.to_string()))
}).await?;
let event = changes.recv().await.expect("subscriber remains live");
assert_eq!(event.document, document.id());

repo.flush().await?;
repo.shutdown().await?;
# Ok(())
# }
```

A later device observes retained offers from authenticated ready peers and joins
only after the application accepts the root:

```no_run
# use std::sync::Arc;
# use fi_repo::{Repo, RepoConfig, testing::{MemoryStore, MemoryTransport}};
# async fn example() -> fi_repo::Result<()> {
# let documents = Arc::new(MemoryStore::default());
# let control = Arc::new(MemoryStore::default());
# let (transport, _remote) = MemoryTransport::pair("joining", "ready", 128);
let repo = Repo::open(documents, control, transport, RepoConfig::default()).await?;
if let Some(offer) = repo.bootstrap_offers().await?.first() {
    let root = repo.join_existing(offer.root).await?;
    root.ready().await?;
}
# Ok(())
# }
```

Read and change callbacks are synchronous and must not block. They execute on a
single document actor, while actors for other documents remain independent.
`read` can return only owned `Send + 'static` values, so Automerge references
and transactions cannot escape. A callback error rolls back its transaction.

`DocumentEvent::Remote(peer)` names the immediate authenticated peer that
delivered the change, not the original Automerge actor. Event delivery uses a
bounded Tokio broadcast channel. A lagging subscriber receives Tokio's
`Lagged` error and should rebuild its materialized view with `DocHandle::read`.

## Adapter contracts

`StorageAdapter` stores complete Automerge snapshots; `ControlStore` separately
stores bootstrap transitions. Implementations are asynchronous, thread-safe,
and must make each `store` atomic. `NetworkTransport` supplies authenticated
peer IDs and reliable, ordered, complete frames with bounded backpressure. It
must expose only one active session per peer and must not emit stale events from
a replaced session.

The documentation-hidden `testing` module provides deterministic memory stores,
paired transports, and a multi-peer network. Tests can inspect queues, manually
deliver frames, replace connections, and inject or block storage operations.

## Durability boundary

Stage 1 synchronously stores creation and bootstrap readiness and offers explicit
`flush` and orderly `shutdown` barriers. It does not promise crash-safe files,
automatic persistence scheduling, retry/backoff, compaction, or hardened queue
draining. Those production durability guarantees belong to Stage 2 without
changing document ownership or the public adapter boundaries.
