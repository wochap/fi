## Purpose

TBD: Define durable projection of authoritative Automerge finance state into a disposable SQLite read model.

## Requirements

### Requirement: SQLite is a disposable read model
`read-model.sqlite` SHALL contain only query-oriented categories, transactions, indexes, and projection metadata, and no application command SHALL write authoritative domain state directly to it.

#### Scenario: Command write path
- **WHEN** a category or transaction command is executed
- **THEN** its authoritative state changes in Automerge before any corresponding SQLite row changes

#### Scenario: Query read path
- **WHEN** a finance query is executed
- **THEN** it reads SQLite without opening an Automerge transaction

### Requirement: Durable-before-projected ordering
For each projection cycle the engine SHALL capture a self-consistent root snapshot and heads, complete a Repo durability barrier covering that snapshot, and only then commit the SQLite projection.

#### Scenario: Automerge persistence fails
- **WHEN** the durability barrier for a captured change fails
- **THEN** the engine reports a projection error and does not advance the SQLite checkpoint to those heads

#### Scenario: Process crashes after Automerge persistence
- **WHEN** the process stops after Automerge is durable but before SQLite commits
- **THEN** the next startup observes mismatched heads and rebuilds the read model

### Requirement: Transactional complete projection
The engine SHALL validate and map the complete root state, replace category and transaction rows, and update projection metadata in one SQLite transaction with the checkpoint written last.

#### Scenario: Projection mapping fails
- **WHEN** authoritative data cannot be mapped under the supported schema
- **THEN** the SQLite transaction rolls back and the prior checkpoint is not advanced

#### Scenario: Projection succeeds
- **WHEN** all authoritative records map successfully
- **THEN** rows and the exact captured checkpoint become visible atomically

### Requirement: Authoritative-state checkpoint
Projection metadata SHALL include the root document ID, projection schema version, and a canonical versioned encoding of sorted Automerge head hashes.

#### Scenario: Same heads after restart
- **WHEN** SQLite integrity, schema, root ID, and encoded heads match Automerge at startup
- **THEN** startup retains the existing read model without rebuilding it

#### Scenario: Stale checkpoint
- **WHEN** the stored heads differ from the authoritative root heads
- **THEN** startup performs a complete projection rebuild before reporting the application ready for queries

### Requirement: Missing or inconsistent projection recovery
Startup SHALL rebuild `read-model.sqlite` from Automerge when the database, schema, checkpoint, expected root, or integrity state is missing or inconsistent, and MUST NOT infer authoritative changes from surviving SQLite rows.

#### Scenario: SQLite deletion
- **WHEN** `read-model.sqlite` is deleted while Automerge snapshots remain
- **THEN** startup recreates all query rows and checkpoint data from the root document

#### Scenario: Corrupt read model
- **WHEN** SQLite cannot be opened or fails integrity validation
- **THEN** the application replaces only the disposable read-model database and rebuilds it from Automerge

### Requirement: Projection event recovery
The projector SHALL consume root change notifications with bounded memory and SHALL recover from notification lag by projecting a fresh complete root snapshot.

#### Scenario: Subscriber lags
- **WHEN** the projector misses one or more retained document events
- **THEN** it ignores patch deltas and performs a full-state projection that reaches current authoritative heads
