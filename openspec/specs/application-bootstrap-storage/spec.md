## Purpose

TBD: Define explicit application bootstrap decisions, durable root creation, canonical local storage, and restart preservation.

## Requirements

### Requirement: Explicit application-root decision
A fresh installation SHALL expose a `NeedsDecision` state and MUST reject authoritative collection and record commands until the user explicitly creates a new root or an authenticated workflow joins an existing root.

#### Scenario: Fresh startup
- **WHEN** application storage contains neither a bootstrap record nor Automerge documents
- **THEN** initialization succeeds in `NeedsDecision` and creates no generic application history automatically

#### Scenario: Premature domain command
- **WHEN** a collection or record command is invoked before the Repo is ready
- **THEN** it returns a typed bootstrap error and creates no authoritative or projected data

### Requirement: First-device root creation
The create-new-dataset operation SHALL call the custom Repo's explicit initialization, initialize the generic application schema through the returned root handle, durably project it, and retain that root across restart.

#### Scenario: Successful first-device creation
- **WHEN** the user chooses to create a new dataset
- **THEN** the application becomes ready only after the Repo root, generic application schema, and matching read-model checkpoint are durable

### Requirement: Canonical application storage layout
The application SHALL resolve one platform application-data directory containing `automerge/documents`, `control.sqlite`, and disposable `read-model.sqlite`, and SHALL restrict filesystem maintenance to those resolved application paths.

#### Scenario: New application directory
- **WHEN** initialization runs against an empty application-data directory
- **THEN** it creates the required private directories and databases without creating authoritative SQLite domain rows

### Requirement: SQLite Repo control store
`control.sqlite` SHALL implement the Repo bootstrap `ControlStore` contract atomically and durably, with one bootstrap record serving as the local root-document record alongside versioned non-secret application control metadata.

#### Scenario: Bootstrap round trip
- **WHEN** the Repo stores and flushes a creating, joining, or ready bootstrap record
- **THEN** reopening through the SQLite control adapter returns exactly that transition and root ID

#### Scenario: Invalid bootstrap row
- **WHEN** control metadata contains an unsupported state, version, or malformed root ID
- **THEN** initialization fails visibly without rewriting Automerge snapshots or inferring a replacement root

### Requirement: Complete restart preservation
Application shutdown SHALL drain accepted commands, complete best-effort projection and Repo barriers, and close owned resources; reopening SHALL recover the same authoritative root, collection schemas, and records even if the read model requires rebuilding.

#### Scenario: Restart after successful commands
- **WHEN** an initialized application is shut down and reopened with its application-data directory
- **THEN** collection schemas, record values, root identity, HLC resolution, and generic queries are preserved
