## Purpose

TBD: Define Stage 1 repository storage, control, transport, test-adapter, inventory, loading, flush, and shutdown ports.

## Requirements

### Requirement: Document storage port
The library SHALL define an asynchronous thread-safe storage port for listing, loading, atomically storing, removing, synchronizing, and closing complete Automerge snapshots by `DocumentId`.

#### Scenario: Missing snapshot
- **WHEN** the repository loads an ID absent from storage
- **THEN** the storage port returns `None` rather than an empty or fabricated document

#### Scenario: Stored snapshot round trip
- **WHEN** a complete Automerge snapshot is stored and loaded through the in-memory adapter
- **THEN** the exact stored bytes are returned

#### Scenario: Adapter failure
- **WHEN** a storage operation fails
- **THEN** the repository returns or emits a structured storage error retaining operation and document context

### Requirement: Separate bootstrap control port
The library SHALL define a control-store port for loading and atomically storing bootstrap records independently of Automerge document snapshots.

#### Scenario: No control record
- **WHEN** control storage has never received a bootstrap record
- **THEN** loading bootstrap returns `None`

#### Scenario: Bootstrap record round trip
- **WHEN** Creating, Joining, or Ready is stored through the in-memory control adapter
- **THEN** a subsequent load returns the same variant and root ID

### Requirement: Authenticated transport port
The transport SHALL expose authenticated peer lifecycle events and complete payload bytes while providing ordered send, peer close, and transport shutdown operations.

#### Scenario: Message source
- **WHEN** the transport emits a message event
- **THEN** it includes the authenticated `PeerId` supplied by the adapter rather than identity derived from the payload

#### Scenario: Event receiver ownership
- **WHEN** the repository takes the transport event receiver once
- **THEN** a repeated attempt fails with a structured transport lifecycle error

#### Scenario: Connection replacement
- **WHEN** the transport emits a replacement connection for an already connected peer
- **THEN** no stale message or disconnect from the replaced stream is emitted after the replacement event

### Requirement: Deterministic in-memory adapters
The library SHALL provide documentation-hidden in-memory adapters usable by integration tests for storage faults and deterministic paired transport delivery.

#### Scenario: Paired delivery
- **WHEN** one endpoint sends a frame and the deterministic link permits delivery
- **THEN** the paired endpoint receives the same complete bytes with the sender's authenticated peer ID

#### Scenario: Controlled disconnection
- **WHEN** a test disconnects a paired endpoint with messages pending
- **THEN** it can deterministically discard, delay, or later deliver only those messages allowed by the configured connection schedule

#### Scenario: Storage blocking and failure
- **WHEN** a test configures the in-memory store to block or fail a selected operation
- **THEN** the adapter exposes deterministic control and observation without sleeps

### Requirement: Repository inventory and loading
The repository SHALL use the storage and control ports during opening and SHALL maintain a deterministic list of known document IDs.

#### Scenario: Open stored documents
- **WHEN** storage lists valid saved documents for a ready repository
- **THEN** the coordinator can open and cache handles for those IDs and `document_ids()` returns them in deterministic order

#### Scenario: Get missing document
- **WHEN** `get(id)` is called for an ID absent from the cache and storage
- **THEN** it returns `None` and does not create a remote placeholder

#### Scenario: Explicit open missing document
- **WHEN** `open_document(id)` is called for an ID absent from the cache and storage
- **THEN** it returns a structured not-found error

### Requirement: Stage 1 repository barriers
Stage 1 SHALL provide compile-tested `flush()` and `shutdown()` operations using its in-memory adapters while reserving production scheduling and crash guarantees for Stage 2.

#### Scenario: Explicit flush
- **WHEN** `flush()` is called on an open Stage 1 repository
- **THEN** it stores current complete actor snapshots and invokes the in-memory storage and control barriers

#### Scenario: Basic shutdown
- **WHEN** `shutdown()` succeeds
- **THEN** the repository stops admitting operations, closes document handles, transport, storage, and control resources, and later operations fail with lifecycle errors
