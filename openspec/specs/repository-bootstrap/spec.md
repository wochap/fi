## Purpose

TBD: Define Stage 1 repository bootstrap decisions, initialization, joining, offers, transitions, and root compatibility.

## Requirements

### Requirement: Explicit bootstrap decision
A repository with neither a bootstrap record nor documents SHALL enter `NeedsDecision` and SHALL reject authoritative document creation and mutation until explicitly initialized or joined.

#### Scenario: Fresh repository
- **WHEN** `Repo::open()` finds no bootstrap record and no document snapshots
- **THEN** it succeeds with bootstrap status `NeedsDecision`

#### Scenario: Premature write
- **WHEN** a caller attempts to create or mutate an authoritative document while bootstrap status is not `Ready`
- **THEN** the operation fails with a structured bootstrap lifecycle error and commits no Automerge change

### Requirement: First-device initialization
`initialize_new()` SHALL choose one root ID and order the in-memory control and snapshot stores as `Creating`, root snapshot, then `Ready` before returning the root handle.

#### Scenario: Successful initialization
- **WHEN** a fresh repository successfully initializes a new root
- **THEN** it becomes `Ready` with that root, returns its ready handle, and admits normal document writes

#### Scenario: Concurrent decisions
- **WHEN** multiple initialize or join requests race for a repository awaiting a decision
- **THEN** exactly one transition is accepted and the others receive deterministic lifecycle errors

### Requirement: Explicit joining
`join_existing(root)` SHALL durably record the Stage 1 in-memory `Joining` state, create an empty root placeholder without a local commit, and synchronize only that root until readiness.

#### Scenario: Join starts
- **WHEN** the application accepts an offered root while the repository needs a decision
- **THEN** bootstrap status becomes `Joining` for that exact root and root-only synchronization begins

#### Scenario: Non-root document during joining
- **WHEN** a joining repository receives inventory, announcement, or sync traffic for a document other than its selected root
- **THEN** it does not create, mutate, or synchronize that document

#### Scenario: Join becomes ready
- **WHEN** remote synchronization gives the selected root nonempty history and the Stage 1 snapshot and Ready control stores succeed
- **THEN** bootstrap status becomes `Ready` and full inventory synchronization begins

### Requirement: Bootstrap offers are observable state
An uninitialized repository SHALL retain root offers learned from authenticated ready peers in a typed, queryable form.

#### Scenario: Offer precedes subscription
- **WHEN** a ready peer's Hello arrives before the application observes bootstrap offers
- **THEN** the offered root and peer remain queryable until invalidated by disconnect or a bootstrap decision

#### Scenario: Explicit acceptance only
- **WHEN** an authenticated peer advertises a root
- **THEN** the repository does not join it until the application explicitly calls `join_existing(root)`

### Requirement: Live bootstrap transitions
The protocol SHALL support idempotent post-Hello bootstrap-state updates so a connection can observe `Joining` and `Ready` transitions without reconnecting.

#### Scenario: Join on existing connection
- **WHEN** an uninitialized peer stores `Joining` after the initial Hello exchange
- **THEN** it sends a bootstrap-state update and the matching ready peer begins root synchronization on that connection

#### Scenario: Joining peer reaches ready
- **WHEN** a joining peer completes the root snapshot and Ready control stores
- **THEN** it sends a Ready bootstrap-state update and compatible peers enable full inventory exchange

### Requirement: Root compatibility
Peers with different nonempty root IDs SHALL be treated as incompatible and SHALL exchange no inventories, announcements, or document sync messages.

#### Scenario: Mismatched ready roots
- **WHEN** two ready peers advertise different root IDs
- **THEN** each detects `RootMismatch`, emits a structured protocol error, and closes the peer connection

#### Scenario: Matching roots
- **WHEN** ready peers advertise the same root ID
- **THEN** they are compatible and exchange full inventories

#### Scenario: Joining wrong root
- **WHEN** a joining peer names a root different from the ready peer's root
- **THEN** the peers report `RootMismatch` and perform no root synchronization
