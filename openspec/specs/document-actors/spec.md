## Purpose

TBD: Define Stage 1 document actor ownership, lifecycle, transaction, notification, and creation behavior.

## Requirements

### Requirement: Exclusive document ownership
The system SHALL assign each loaded `DocumentId` to at most one live document actor, and that actor SHALL exclusively own and mutate the corresponding `Automerge` instance.

#### Scenario: Concurrent operations on one document
- **WHEN** multiple cloned handles submit reads, changes, and remote sync work concurrently for the same document
- **THEN** the document actor processes the accepted operations serially without concurrent access to its `Automerge` instance

#### Scenario: Independent documents
- **WHEN** one document actor is occupied by a long-running synchronous operation
- **THEN** an actor for a different document can continue processing its own mailbox

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
Every document handle SHALL expose `Loading`, `Ready`, or `Closed` status and an asynchronous readiness wait.

#### Scenario: Loaded local document
- **WHEN** a valid local snapshot is opened
- **THEN** its handle reaches `Ready`

#### Scenario: Unknown remote document
- **WHEN** a compatible peer announces an unknown document
- **THEN** the repository creates a `Loading` placeholder with a fresh local Automerge actor ID and no local change history

#### Scenario: Placeholder receives history
- **WHEN** a loading placeholder receives real nonempty remote history and its Stage 1 snapshot store succeeds
- **THEN** its status becomes `Ready`

#### Scenario: Closed handle operation
- **WHEN** an operation is submitted through a handle whose actor is closed
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
Every locally created document SHALL have explicit nonempty Automerge history and SHALL not be returned or announced until its initial Stage 1 snapshot store succeeds.

#### Scenario: Empty document creation
- **WHEN** `Repo::create()` succeeds
- **THEN** the new document has an explicit empty Automerge commit and a ready handle

#### Scenario: Initialized document creation
- **WHEN** `Repo::create_with()` successfully applies its initializer
- **THEN** the document contains its existence change and initialization result before its ready handle is returned

#### Scenario: Initialization failure
- **WHEN** a `create_with()` initializer fails
- **THEN** the incomplete document is discarded and is not returned, stored as ready, inventoried, or announced
