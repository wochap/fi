# automerge-repo

`automerge-repo` is a native Rust repository around Automerge 0.11. Each loaded
document is exclusively owned by a bounded Tokio actor. A coordinator manages
explicit bootstrap and whole-collection replication over application-supplied
authenticated transport and storage ports.

## Durable repository API

Fresh storage requires an explicit application decision. Initialize the first
device, then create and mutate documents through actor handles:

```no_run
use std::sync::Arc;
use automerge::{ROOT, transaction::Transactable};
use automerge_repo::{Error, Repo, RepoConfig, testing::{MemoryStore, MemoryTransport}};

# async fn example() -> automerge_repo::Result<()> {
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
// The transaction is committed to the actor here. Automatic snapshot storage
// runs independently and peer synchronization is a separate process.
let event = changes.recv().await.expect("subscriber remains live");
assert_eq!(event.document, document.id());

repo.flush().await?;
// Every revision captured by flush is now installed and the storage barriers
// have succeeded. A failed barrier leaves durability uncertain and is reported.
repo.shutdown().await?;
# Ok(())
# }
```

A later device observes retained offers from authenticated ready peers and joins
only after the application accepts the root:

```no_run
# use std::sync::Arc;
# use automerge_repo::{Repo, RepoConfig, testing::{MemoryStore, MemoryTransport}};
# async fn example() -> automerge_repo::Result<()> {
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

## Durability and lifecycle

Every head-changing local or remote commit advances an actor-owned revision.
Automatic snapshots are coalesced by `RepoConfig::persistence_debounce`; failed
automatic saves stay dirty, emit a typed `Error::Persistence`, and retry with
capped exponential backoff. Storage I/O runs in one private worker per document,
so a blocked save does not block later commands for that document or other
documents.

`Repo::flush` has one repository-wide capture point. It immediately targets
every revision accepted before that point, waits for document attempts, invokes
the applicable durability barriers, and returns all independent failures in a
stable aggregate. A successful consuming `Repo::shutdown(self)` additionally
drains commands already admitted to bounded mailboxes, flushes dirty actors,
closes every subsystem, and marks all handles closed. Once shutdown changes the
shared lifecycle to Closing, new repository, document, and inbound-network work
is rejected. An operation is accepted only once its mailbox send succeeds.

`Repo::remove_local` is local maintenance, not distributed deletion. It rejects
the root and any connected authenticated peer, closes and orders the document's
persistence worker, removes and synchronizes its snapshot, then evicts the
actor. A failed removal leaves the actor closed and evicted; explicitly reopen
the surviving snapshot before inspecting it or retrying removal.

Creation, initialization, joining readiness, flush, and successful shutdown are
durability boundaries. In contrast, transaction commit, peer convergence, and
an automatic snapshot `store` are not themselves crash-durability guarantees.
Because generic barriers cannot reveal whether earlier writes reached stable
storage, a failed barrier reports an uncertain outcome; bootstrap recovery and
creation cleanup are designed to be safely repeatable.

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

## Filesystem storage

`FilesystemStorage` implements both existing persistence traits beneath one
repository directory:

```text
<repo>/
  automerge/<lowercase-hyphenated-uuid>.automerge
  control/bootstrap-v1.bin
```

Each replacement uses an exclusively created recognizable sibling temporary,
a complete write and file sync, atomic rename, then containing-directory sync.
On Unix, directories use mode `0700` and files use `0600`. Startup ignores
unrelated document-directory files, removes only exact adapter temporary names,
rejects malformed `.automerge` names, and strictly validates every listed
snapshot.

The control file is exactly 24 bytes: `FIBC`, big-endian version `1`, state byte
(`0` Creating, `1` Joining, `2` Ready), zero reserved byte, and the 16 root UUID
bytes. Invalid length, magic, version, state, or reserved data is preserved and
reported with path context. All filesystem work is isolated through Tokio's
blocking execution facility.
