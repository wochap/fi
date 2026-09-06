## Purpose

TBD: Define atomic repository shutdown, accepted-command draining, aggregate cleanup, and safe local document removal.

## Requirements

### Requirement: Atomic repository shutdown admission
The repository SHALL share an `Open`, `Closing`, or `Closed` lifecycle across every `Repo` and `DocHandle`, and consuming `Repo::shutdown(self)` SHALL atomically perform the sole `Open` to `Closing` transition.

#### Scenario: Shutdown begins
- **WHEN** one repository clone successfully transitions the lifecycle to `Closing`
- **THEN** new repo and document-handle operations are rejected with structured lifecycle errors

#### Scenario: Concurrent shutdown
- **WHEN** another clone attempts shutdown after the transition began
- **THEN** it receives a deterministic already-closing or closed lifecycle error and does not start a second shutdown

#### Scenario: Inbound network work
- **WHEN** the lifecycle is no longer `Open`
- **THEN** the coordinator accepts no new inbound peer work

### Requirement: Accepted commands are drained
A command SHALL be considered accepted exactly when its send is successfully admitted to the bounded actor mailbox before the receiver is closed. Shutdown SHALL close mailbox receivers to further sends and drain commands already accepted.

#### Scenario: Command admitted before receiver close
- **WHEN** a handle change is successfully admitted before its actor receiver closes
- **THEN** the actor processes that change before its shutdown flush and closure

#### Scenario: Command loses shutdown race
- **WHEN** a handle operation has not entered the mailbox when its receiver closes
- **THEN** it fails with a structured closed lifecycle error and does not run

#### Scenario: External clones remain
- **WHEN** shutdown runs while idle `Repo` and `DocHandle` clones still exist
- **THEN** shutdown completes without waiting for those sender values to be dropped

### Requirement: Best-effort aggregate shutdown
Shutdown SHALL best-effort flush and close every document, close the transport, synchronize and close document and control storage, transition every surviving handle and the shared lifecycle to `Closed`, and return every encountered failure in one phase-tagged aggregate.

#### Scenario: Dirty document at shutdown
- **WHEN** shutdown begins with dirty documents
- **THEN** each document receives a flush attempt before its actor closes

#### Scenario: Multiple subsystem failures
- **WHEN** document flush, transport close, storage close, and control close independently fail
- **THEN** shutdown attempts all remaining phases, reaches `Closed`, and returns an aggregate containing each failure and phase

#### Scenario: Successful shutdown
- **WHEN** every drain, flush, barrier, and close succeeds
- **THEN** transport and stores are closed, all handles report `Closed`, and later operations are rejected

### Requirement: Safe local document removal
`Repo::remove_local(id)` SHALL be a local maintenance operation that rejects the root and connected-peer races, prevents in-flight persistence from recreating the snapshot, durably removes the snapshot, closes handles, and evicts the actor without producing distributed deletion state.

#### Scenario: Root removal
- **WHEN** removal targets the repository root
- **THEN** it fails with a structured maintenance error and leaves the root unchanged

#### Scenario: Peer connected
- **WHEN** any potentially compatible authenticated peer session is connected
- **THEN** removal fails before closing the target actor or deleting storage

#### Scenario: In-flight save
- **WHEN** removal begins while the target has a store in flight
- **THEN** the actor stops new admission, waits for that store and worker ordering, then removes and synchronizes storage so the save cannot recreate the snapshot afterward

#### Scenario: Successful removal
- **WHEN** a non-root document is disconnected from peers and storage removal plus barrier succeed
- **THEN** every existing handle reports `Closed`, the coordinator evicts the actor, later opening returns not found, and no network deletion frame is sent

#### Scenario: Removal operation race
- **WHEN** document commands are queued as removal closes admission
- **THEN** commands that began execution complete and remaining admitted commands are rejected according to the documented removal policy

#### Scenario: Removal failure
- **WHEN** snapshot removal or its barrier fails
- **THEN** the error is returned directly with document and subsystem context and the closed actor is evicted so explicit reopen or retry can inspect remaining storage

### Requirement: Repository state survives a complete restart
The repository SHALL preserve every durably accepted document's identity, Automerge history, and hydrated value across a successful flush, shutdown, and reopen using fresh adapter and repository instances over the same storage.

#### Scenario: Persist and reopen a mutated document
- **WHEN** a ready repository creates and mutates a document, successfully flushes and shuts down, and a new repository instance opens the same storage
- **THEN** the reopened repository enumerates and opens the same document ID with identical Automerge heads and hydrated values

#### Scenario: Reopened root metadata
- **WHEN** a repository is reopened after a successful ready-root shutdown
- **THEN** its bootstrap status identifies the same root and the root document is immediately available as ready
