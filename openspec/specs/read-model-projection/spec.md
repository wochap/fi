## Purpose

TBD: Define durable projection of authoritative Automerge finance state into a disposable SQLite read model.

## Requirements

### Requirement: SQLite is a disposable read model
`read-model.sqlite` SHALL contain only query-oriented collection schemas, field metadata, enum options, records, typed record values, diagnostics, and projection metadata, and no application command SHALL write authoritative domain state directly to it.

#### Scenario: Command write path
- **WHEN** a collection, field, enum-option, or record command is executed
- **THEN** its authoritative state changes in Automerge before any corresponding SQLite projection change

#### Scenario: Query read path
- **WHEN** a schema or record query is executed
- **THEN** it reads SQLite without opening an Automerge transaction

### Requirement: Durable-before-projected ordering
For each projection cycle the engine SHALL capture a self-consistent generic application snapshot and heads, complete a Repo durability barrier covering that snapshot, and only then commit the SQLite projection.

#### Scenario: Automerge persistence fails
- **WHEN** the durability barrier for a captured schema or record change fails
- **THEN** the engine reports a projection error and does not advance the SQLite checkpoint to those heads

#### Scenario: Process crashes after Automerge persistence
- **WHEN** the process stops after Automerge is durable but before SQLite commits
- **THEN** the next startup observes mismatched heads and rebuilds the generic read model

### Requirement: Transactional complete projection
The engine SHALL structurally validate and map the complete root state, replace collection, field, enum-option, record, typed-value, and diagnostic rows, and update projection metadata in one SQLite transaction with the checkpoint written last.

#### Scenario: Structural projection mapping fails
- **WHEN** authoritative data cannot be structurally decoded under the supported application schema
- **THEN** the SQLite transaction rolls back and the prior checkpoint is not advanced

#### Scenario: Semantic inconsistency is found
- **WHEN** structurally valid synchronized data violates an effective schema constraint after concurrency
- **THEN** the data and a typed diagnostic are projected without making unrelated collections unavailable

#### Scenario: Projection succeeds
- **WHEN** the complete authoritative snapshot is mapped
- **THEN** all generic rows and the exact captured checkpoint become visible atomically

### Requirement: Authoritative-state checkpoint
Projection metadata SHALL include the root document ID, generic projection schema version, and a canonical versioned encoding of sorted Automerge head hashes.

#### Scenario: Same heads after restart
- **WHEN** SQLite integrity, schema, root ID, and encoded heads match Automerge at startup
- **THEN** startup retains the existing generic read model without rebuilding it

#### Scenario: Stale checkpoint
- **WHEN** the stored heads differ from the authoritative root heads
- **THEN** startup performs a complete generic projection rebuild before reporting queries ready

### Requirement: Missing or inconsistent projection recovery
Startup SHALL rebuild `read-model.sqlite` from Automerge when the database, generic schema, checkpoint, expected root, or integrity state is missing or inconsistent, and MUST NOT infer authoritative changes from surviving SQLite rows.

#### Scenario: SQLite deletion
- **WHEN** `read-model.sqlite` is deleted while Automerge snapshots remain
- **THEN** startup recreates schemas, field metadata, enum options, records, typed values, diagnostics, and checkpoint from the root document

#### Scenario: Corrupt read model
- **WHEN** SQLite cannot be opened or fails integrity validation
- **THEN** the application replaces only the disposable read-model database and rebuilds it from Automerge

### Requirement: Projection event recovery
The projector SHALL consume root change notifications with bounded memory and SHALL recover from notification lag by projecting a fresh complete root snapshot.

#### Scenario: Subscriber lags
- **WHEN** the projector misses one or more retained document events
- **THEN** it ignores patch deltas and performs a full-state projection that reaches current authoritative heads
