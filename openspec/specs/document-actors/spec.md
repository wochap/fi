## Purpose

TBD: Define Stage 1 document actor ownership, lifecycle, transaction, notification, and creation behavior.

## Requirements

### Requirement: Exclusive document ownership
The system SHALL assign each loaded `DocumentId` to at most one live document actor, and that actor SHALL exclusively own and mutate the corresponding `Automerge` instance, document status, revision and dirty state, subscribers, connected peers, per-peer sync states, flush waiters, and snapshot serialization decisions.

#### Scenario: Concurrent operations on one document
- **WHEN** multiple cloned handles submit reads, changes, and remote sync work concurrently for the same document
- **THEN** the document actor processes the accepted operations serially without concurrent access to its `Automerge` instance

#### Scenario: Independent documents
- **WHEN** one document actor is occupied by a long-running synchronous operation
- **THEN** an actor for a different document can continue processing its own mailbox

#### Scenario: Persistence worker boundary
- **WHEN** an actor submits persistence work
- **THEN** its private worker receives only owned serialized bytes, revision metadata, and control commands and never receives the `Automerge` instance or a reference to it

### Requirement: Safe document handles
`DocHandle` SHALL expose owned asynchronous reads and transaction closures without allowing an `Automerge` reference or transaction to escape the actor.

#### Scenario: Owned read result
- **WHEN** a caller performs a read through a document handle
- **THEN** the callback runs against the actor-owned document and returns only an owned `Send + 'static` result

#### Scenario: Handle reuse
- **WHEN** the repository opens the same document more than once
- **THEN** it returns handles connected to the same cached document actor

### Requirement: Transaction commit and rollback
The document actor SHALL use Automerge transaction patch logging and SHALL commit only callbacks that return success.

#### Scenario: Successful mutation
- **WHEN** a transaction callback adds operations and returns success
- **THEN** the actor commits one local change and returns the callback result together with the change outcome

#### Scenario: Failed mutation
- **WHEN** a transaction callback returns an error after adding operations
- **THEN** all operations from that transaction are rolled back and no persistence, notification, or synchronization work is triggered

#### Scenario: Successful no-op
- **WHEN** a transaction callback returns success without adding operations
- **THEN** no new heads, document event, or synchronization pump is produced

### Requirement: Document status
Every document handle SHALL expose `Loading`, `Ready`, or `Closed` status and an asynchronous readiness wait. A loading document SHALL become ready only after any required persistence and bootstrap durability transitions succeed.

#### Scenario: Loaded local document
- **WHEN** a valid local snapshot is opened under a consistent ready bootstrap record
- **THEN** its handle reaches `Ready`

#### Scenario: Unknown remote document
- **WHEN** a compatible peer announces an unknown document
- **THEN** the repository creates a `Loading` placeholder with a fresh local Automerge actor ID and no local change history

#### Scenario: Placeholder receives history
- **WHEN** a loading non-root placeholder receives real nonempty remote history and its complete snapshot becomes durable
- **THEN** its status becomes `Ready`

#### Scenario: Joining root receives history
- **WHEN** a loading joining root receives real nonempty remote history
- **THEN** its status remains `Loading` until the root snapshot and Ready control transition are both durable

#### Scenario: Closed handle operation
- **WHEN** an operation is submitted through a handle whose actor or repository lifecycle is closed
- **THEN** the operation fails with a structured lifecycle error

### Requirement: Change notifications
The document actor SHALL publish cloneable events for committed local head changes and successfully applied remote head changes.

#### Scenario: Local notification
- **WHEN** a local transaction changes the document heads
- **THEN** subscribers receive one event containing the document ID, `Local` origin, resulting heads, and materialized patches

#### Scenario: Remote notification
- **WHEN** an inbound sync message from a peer changes the document heads
- **THEN** subscribers receive one event whose origin identifies that immediate peer and whose patches were produced by the remote patch log

#### Scenario: Remote acknowledgement only
- **WHEN** an inbound sync message updates sync state without changing document heads
- **THEN** no document change event is emitted

#### Scenario: Lagged subscriber
- **WHEN** a broadcast subscriber falls behind the retained event capacity
- **THEN** it observes Tokio's lag condition and can call `read()` to rebuild its materialized state

### Requirement: Synchronizable document creation
Every locally created document SHALL have explicit nonempty Automerge history and SHALL not be returned, inventoried, announced, or synchronized until its complete initial snapshot and storage durability barrier succeed.

#### Scenario: Empty document creation
- **WHEN** `Repo::create()` succeeds
- **THEN** the new document has an explicit empty Automerge commit, a durably stored complete snapshot, and a ready handle

#### Scenario: Initialized document creation
- **WHEN** `Repo::create_with()` successfully applies its initializer
- **THEN** the durable snapshot contains both its existence change and initialization result before its ready handle is returned

#### Scenario: Initialization failure
- **WHEN** a `create_with()` initializer fails
- **THEN** the incomplete hidden actor is closed and discarded and the document is not returned, stored as ready, inventoried, announced, or synchronized

#### Scenario: Initial persistence failure
- **WHEN** the initial store or durability barrier fails
- **THEN** creation returns a structured failure, closes and evicts the hidden actor, announces nothing, and performs best-effort snapshot removal and synchronization while retaining cleanup failures

#### Scenario: Creation announcement ordering
- **WHEN** compatible peers are connected during document creation
- **THEN** no inventory, announcement, or sync frame for the new ID is queued before initial durability succeeds

### Requirement: End-to-end document change observation
Document subscribers SHALL observe typed change events when local or protocol-delivered remote mutations change document heads in the two-repository acceptance path.

#### Scenario: Local acceptance event
- **WHEN** a subscriber is registered before a successful local transaction that changes document heads
- **THEN** it receives one event for that document with `Local` origin, resulting heads, and nonempty materialized patches

#### Scenario: Remote acceptance event
- **WHEN** a subscriber on Repo B is registered before Repo B receives and applies Repo A's synchronization change
- **THEN** it receives one event for that document whose `Remote` origin identifies Repo A and whose resulting heads and materialized patches describe the accepted change
