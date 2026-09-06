## Purpose

TBD: Define Stage 1 repository storage, control, transport, test-adapter, inventory, loading, flush, and shutdown ports.

## Requirements

### Requirement: Document storage port
The library SHALL define an asynchronous thread-safe storage port for listing, loading, atomically storing, removing, synchronizing, and closing complete Automerge snapshots by `DocumentId`. Successful `store` SHALL install one complete value atomically, while successful `flush` SHALL be the explicit durability barrier for preceding operations.

#### Scenario: Missing snapshot
- **WHEN** the repository loads an ID absent from storage
- **THEN** the storage port returns `None` rather than an empty or fabricated document

#### Scenario: Stored snapshot round trip
- **WHEN** a complete Automerge snapshot is stored and loaded through an adapter
- **THEN** the exact installed bytes are returned

#### Scenario: Durability barrier
- **WHEN** snapshot operations succeed and a subsequent storage flush succeeds
- **THEN** those operations satisfy the adapter's documented crash-durability guarantee

#### Scenario: Adapter failure
- **WHEN** a storage operation fails
- **THEN** the repository returns or emits a structured storage error retaining operation, document, revision, and path context where applicable

### Requirement: Separate bootstrap control port
The library SHALL define a control-store port for loading and atomically storing bootstrap records independently of Automerge snapshots, with `flush` serving as the durability barrier for changed control state.

#### Scenario: No control record
- **WHEN** control storage has never received a bootstrap record
- **THEN** loading bootstrap returns `None`

#### Scenario: Bootstrap record round trip
- **WHEN** Creating, Joining, or Ready is stored through a control adapter
- **THEN** a subsequent load returns the same variant and root ID

#### Scenario: Durable control transition
- **WHEN** a control store and its following flush both succeed
- **THEN** the transition satisfies the adapter's documented crash-durability guarantee

#### Scenario: Changed control barrier failure
- **WHEN** control state changed and its barrier fails
- **THEN** the repository retains the control state as needing a later barrier and returns or emits structured subsystem and bootstrap-operation context

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
The repository SHALL strictly load and validate every storage-listed snapshot and bootstrap consistency before starting network processing, and SHALL maintain a deterministic list of known document IDs.

#### Scenario: Open stored documents
- **WHEN** storage lists valid saved documents for a consistent ready repository
- **THEN** opening validates and caches actors for all IDs and `document_ids()` returns them in deterministic order

#### Scenario: Listed snapshot disappears
- **WHEN** an ID returned by list is absent when loaded
- **THEN** repository opening fails with a structured storage consistency error

#### Scenario: Corrupt listed snapshot
- **WHEN** any listed snapshot is not a valid complete Automerge snapshot
- **THEN** repository opening fails before network processing rather than deferring corruption until explicit document open

#### Scenario: Get missing document
- **WHEN** `get(id)` is called for an ID absent from the cache and storage
- **THEN** it returns `None` and does not create a remote placeholder

#### Scenario: Explicit open missing document
- **WHEN** `open_document(id)` is called for an ID absent from the cache and storage
- **THEN** it returns a structured not-found error

### Requirement: Stage 1 repository barriers
Stage 2 SHALL provide repository-wide `flush()` and consuming `shutdown(self)` durability barriers while preserving the existing storage and control ports and aggregating independent failures.

#### Scenario: Explicit flush
- **WHEN** `flush()` is called on an open repository
- **THEN** it captures actor revisions, awaits every dirty target attempt, invokes applicable storage and control barriers, and returns all failures

#### Scenario: Successful shutdown
- **WHEN** `shutdown(self)` succeeds
- **THEN** accepted work and dirty snapshots are durable, document handles and transport are closed, storage and control are synchronized and closed, and later operations fail with lifecycle errors

#### Scenario: Failed shutdown
- **WHEN** one or more shutdown phases fail
- **THEN** all later phases are still attempted, the repository reaches Closed, and the returned aggregate identifies every subsystem and phase failure
