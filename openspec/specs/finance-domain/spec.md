## Purpose

TBD: Define the authoritative Automerge finance model, explicit domain commands, convergence semantics, and query results.

## Requirements

### Requirement: Versioned authoritative finance root
The application SHALL store its MVP finance state in the established Automerge root document under a versioned schema containing category and transaction maps, and MUST treat that document rather than SQLite as authoritative.

#### Scenario: First dataset initialization
- **WHEN** a user explicitly creates a new application dataset
- **THEN** the root receives a versioned finance structure and a usable default category through an Automerge change

#### Scenario: Joining dataset hydration
- **WHEN** an installation joins an existing root
- **THEN** it uses the synchronized finance structure without creating unrelated local authoritative data

### Requirement: Globally unique typed entities
Category and transaction IDs SHALL be generated locally as UUIDv7 values and synchronized as canonical strings, and authoritative identity MUST NOT depend on SQLite row IDs.

#### Scenario: Offline entity creation
- **WHEN** two disconnected devices create different entities
- **THEN** their identifiers remain distinct after Automerge convergence

### Requirement: Finance value representation
Transactions SHALL contain an ID, UTC occurrence timestamp in integer milliseconds, category ID, signed 64-bit minor-unit amount, description, and deletion tombstone; categories SHALL contain an ID, name, and deletion tombstone.

#### Scenario: Derived balance
- **WHEN** active transactions contain positive and negative minor-unit amounts
- **THEN** the balance query derives their exact integer sum without reading a synchronized balance field

### Requirement: Explicit domain commands
The application SHALL expose explicit create, update, and logical-delete commands for transactions and create, update, and logical-delete commands for categories, validate command inputs in Rust, and apply accepted writes only through Automerge transactions.

#### Scenario: Valid command
- **WHEN** a valid transaction command is accepted
- **THEN** one authoritative Automerge transaction records its field changes before projection occurs

#### Scenario: Invalid command
- **WHEN** an ID, timestamp, amount, description, name, or category reference fails validation
- **THEN** the command returns a typed error and commits neither an Automerge change nor a SQLite projection change

### Requirement: CRDT-safe update and deletion semantics
Update commands SHALL write only explicitly changed fields, SHALL NOT clear deletion tombstones, and category deletion SHALL NOT cascade into transaction deletion.

#### Scenario: Concurrent edit and deletion
- **WHEN** one offline peer edits a transaction while another deletes it
- **THEN** Automerge retains the edit history and the converged visible transaction remains logically deleted

#### Scenario: Concurrent independent fields
- **WHEN** disconnected peers edit different fields of one entity
- **THEN** the converged entity contains both field changes

### Requirement: Query-oriented finance results
Finance queries SHALL return owned category and transaction views from SQLite, exclude logically deleted records by default, support transaction filtering/search and deterministic ordering, and derive aggregates from projected transaction rows.

#### Scenario: Search transactions
- **WHEN** a query supplies text, category, and date filters
- **THEN** SQLite returns matching active transactions in deterministic date-and-ID order

#### Scenario: Deleted category reference
- **WHEN** an active transaction references a deleted or absent category
- **THEN** the query still returns the transaction with an explicit unavailable-category representation
