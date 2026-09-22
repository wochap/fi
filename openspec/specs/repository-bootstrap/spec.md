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

### Requirement: Strict bootstrap consistency on opening
`Repo::open()` SHALL validate all listed snapshots and the bootstrap record, complete recoverable Creating or Joining transitions, classify every remaining inconsistency as recoverable or fatal, and start networking only after validation and recovery succeed. A state SHALL be classified recoverable only where the recorded root ID is known and an external authority can re-supply that root's content; recoverable states SHALL be resolved without mutating or destroying user data beyond quarantine. Fatal states SHALL be rejected without mutation.

#### Scenario: Orphaned documents
- **WHEN** document files exist without a bootstrap record
- **THEN** opening quarantines those documents and succeeds in `NeedsDecision`, without inferring a root, deleting data, or replacing control state

#### Scenario: Ready root missing
- **WHEN** a Ready record names a root snapshot that is absent
- **THEN** opening preserves the recorded root ID, transitions the record to `Joining` for that same root, and resumes root-only synchronization instead of failing

#### Scenario: Ready root unloadable
- **WHEN** a Ready record names a root snapshot that exists but cannot be strictly loaded
- **THEN** the unloadable bytes are quarantined, the document is treated as absent, and opening proceeds as for a missing Ready root

#### Scenario: Any listed snapshot is corrupt
- **WHEN** a listed snapshot that is not the recorded root cannot be strictly loaded
- **THEN** opening fails with its document and storage-path context before consuming network events

#### Scenario: Genuinely inconsistent state remains fatal
- **WHEN** a Creating or Joining record is accompanied by documents other than the recorded root, or the bootstrap record itself is malformed
- **THEN** opening fails with a fatal structured bootstrap consistency error and performs no mutation, inference, or root selection

### Requirement: Creating recovery is idempotent
Opening `Creating { root }` SHALL preserve the recorded root, durably create its required existence history only when absent, and durably transition the same record to `Ready` without duplicating history.

#### Scenario: Creating root absent
- **WHEN** opening finds Creating and no root snapshot
- **THEN** it creates exactly one existence commit for the recorded root, durably stores the snapshot, and durably writes Ready for that root

#### Scenario: Creating root already durable
- **WHEN** opening finds Creating and a valid nonempty root snapshot
- **THEN** it reuses the snapshot without adding another empty commit and durably writes Ready

#### Scenario: Creating conflict
- **WHEN** Creating storage contains an empty root snapshot or documents conflicting with an interrupted fresh initialization
- **THEN** opening fails visibly without rewriting those snapshots

#### Scenario: Repeated Creating crashes
- **WHEN** recovery is interrupted repeatedly after any ordered step
- **THEN** every later open reuses the same root and converges on one existence change and a durable Ready record

### Requirement: Joining recovery preserves remote authority
Opening `Joining { root }` SHALL preserve the selected root and SHALL never introduce a local root change. It SHALL complete Ready only for valid nonempty history or otherwise resume root-only synchronization with an empty placeholder.

#### Scenario: Joining root absent
- **WHEN** opening finds Joining without a root snapshot
- **THEN** it creates an empty in-memory placeholder with a fresh actor ID and no local commit and resumes root-only synchronization

#### Scenario: Joining root empty
- **WHEN** opening finds Joining with a valid snapshot having empty history
- **THEN** it retains or recreates an empty placeholder without committing a local change

#### Scenario: Joining root has history
- **WHEN** opening finds Joining with a valid root snapshot having nonempty history
- **THEN** it treats that gated history as remotely obtained, durably writes Ready, and only then enables full synchronization

#### Scenario: Joining restart and reconnect
- **WHEN** a join is interrupted by disconnect or process restart before readiness
- **THEN** the repository retains the exact root ID, uses fresh connection sync state, and resumes root-only synchronization

### Requirement: First-device initialization
`initialize_new()` SHALL choose one root ID and order durable transitions as `Creating`, complete root snapshot with one explicit existence commit, then `Ready` before exposing or announcing the root.

#### Scenario: Successful initialization
- **WHEN** a fresh repository successfully initializes a new root
- **THEN** Creating store and control barrier, root store and storage barrier, and Ready store and control barrier occur in that order before the repository becomes Ready or returns the root handle

#### Scenario: Initialization persistence failure
- **WHEN** any ordered store or barrier fails
- **THEN** initialization returns structured operation context, exposes no ready handle, announces no root, and leaves durable state recoverable under the last completed step

#### Scenario: Concurrent decisions
- **WHEN** multiple initialize or join requests race for a repository awaiting a decision
- **THEN** exactly one transition is accepted and the others receive deterministic lifecycle errors

### Requirement: Explicit joining
`join_existing(root)` SHALL durably record `Joining`, create an empty root placeholder without a local commit, communicate Joining to compatible peers, and synchronize only that root until root snapshot and Ready control durability complete.

#### Scenario: Join starts
- **WHEN** the application accepts an offered root while the repository needs a decision
- **THEN** Joining store and control barrier succeed before bootstrap status changes, an empty placeholder is created for that exact root, and root-only synchronization begins

#### Scenario: Joining store fails
- **WHEN** storing or synchronizing Joining fails
- **THEN** no placeholder is exposed for authoritative use and no Joining bootstrap-state update is sent

#### Scenario: Non-root document during joining
- **WHEN** a joining repository receives inventory, announcement, or sync traffic for a document other than its selected root
- **THEN** it does not create, mutate, persist, or synchronize that document

#### Scenario: Join receives root history
- **WHEN** remote synchronization gives the selected root nonempty history
- **THEN** it immediately stores and synchronizes the complete root snapshot, stores and synchronizes Ready, then marks the root and repository Ready

#### Scenario: Join durability fails
- **WHEN** root snapshot or Ready control durability fails
- **THEN** the repository remains Joining and write-gated, reports the failure, and remains eligible to retry without creating a local root change

### Requirement: Bootstrap offers are observable state
An uninitialized repository SHALL retain root offers learned from authenticated ready peers in a typed, queryable form.

#### Scenario: Offer precedes subscription
- **WHEN** a ready peer's Hello arrives before the application observes bootstrap offers
- **THEN** the offered root and peer remain queryable until invalidated by disconnect or a bootstrap decision

#### Scenario: Explicit acceptance only
- **WHEN** an authenticated peer advertises a root
- **THEN** the repository does not join it until the application explicitly calls `join_existing(root)`

### Requirement: Live bootstrap transitions
The protocol SHALL support idempotent post-Hello bootstrap-state updates so a connection can observe only durably completed `Joining` and `Ready` transitions without reconnecting.

#### Scenario: Join on existing connection
- **WHEN** an uninitialized peer durably stores Joining after the initial Hello exchange
- **THEN** it sends a bootstrap-state update and the matching ready peer begins root synchronization on that connection

#### Scenario: Joining peer reaches ready
- **WHEN** a joining peer durably completes the root snapshot and Ready control record
- **THEN** it sends a Ready bootstrap-state update and compatible peers enable full inventory exchange

#### Scenario: Repeated bootstrap state
- **WHEN** an equivalent bootstrap-state update is received repeatedly
- **THEN** eligibility, actor attachment, inventory, and announcements remain idempotent

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
