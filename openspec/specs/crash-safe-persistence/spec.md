## Purpose

TBD: Define crash-safe automatic document persistence, retries, and repository-wide durability barriers.

## Requirements

### Requirement: Revision-aware automatic persistence
Each document actor SHALL track its current revision, latest successfully persisted revision, dirty state, in-flight store, pending debounce or retry, and flush waiters. Every local or remote head change SHALL increment the revision and mark the document dirty.

#### Scenario: Local change commits
- **WHEN** a local transaction changes document heads
- **THEN** its revision increments, it becomes dirty, and the successful `change()` returns after the actor commit without waiting for snapshot storage

#### Scenario: Remote change commits
- **WHEN** an inbound sync message changes document heads
- **THEN** its revision increments, it becomes dirty, and the change is scheduled for persistence

#### Scenario: No head change
- **WHEN** a local no-op, rollback, or remote acknowledgement leaves heads unchanged
- **THEN** the document revision and persistence schedule remain unchanged

### Requirement: Nonblocking coalesced snapshot storage
Snapshot serialization SHALL occur under exclusive document-actor ownership, while storage I/O SHALL execute outside the actor command loop. Each document SHALL have at most one store in flight and SHALL retain the newest pending revision.

#### Scenario: Store is blocked
- **WHEN** a document snapshot store is blocked by its adapter
- **THEN** the same actor continues processing later reads and changes after transferring owned snapshot bytes to its worker

#### Scenario: Rapid changes
- **WHEN** multiple head changes occur within the debounce interval
- **THEN** the actor coalesces them and submits the newest required full snapshot rather than one store per change

#### Scenario: Change during store
- **WHEN** the document advances while revision N is in flight
- **THEN** success for N marks only N persisted and the newer revision remains dirty

#### Scenario: Stale replacement prevention
- **WHEN** several revisions become eligible for storage
- **THEN** the actor submits them monotonically with at most one in flight so an older snapshot cannot replace a newer snapshot

#### Scenario: Independent documents
- **WHEN** stores for two document IDs are ready concurrently
- **THEN** their independent persistence workers can progress concurrently

### Requirement: Persistence failure and retry
A failed automatic save SHALL leave the document dirty, emit a typed persistence error with document and revision, and schedule exponential retry capped by configurable minimum and maximum durations.

#### Scenario: Automatic save fails
- **WHEN** storage rejects an automatic save for revision N
- **THEN** the actor retains N or a newer revision as dirty and emits a persistence error identifying N

#### Scenario: Retry succeeds
- **WHEN** a failed save becomes writable before its retry deadline
- **THEN** the actor retries after the configured backoff and marks the submitted revision persisted on success

#### Scenario: Retry cap
- **WHEN** consecutive automatic saves fail
- **THEN** retry delay grows exponentially without exceeding the configured maximum

### Requirement: Repository-wide flush barrier
`Repo::flush()` SHALL capture every loaded document and its latest accepted revision at one documented repository-wide linearization point, bypass debounce and retry delays, await each captured target, invoke required storage and control barriers, and aggregate all failures.

#### Scenario: Flush capture race
- **WHEN** a head-changing commit linearizes before flush acquires the exclusive capture gate
- **THEN** that revision is included in the flush target set

#### Scenario: Change after capture
- **WHEN** a head change linearizes after flush acquires and releases the exclusive capture gate
- **THEN** the flush need not await that revision and it remains dirty unless a submitted newer snapshot happens to include it

#### Scenario: Flush bypasses delay
- **WHEN** a dirty target is waiting for debounce or retry
- **THEN** flush cancels that delay and immediately requests a snapshot-store attempt

#### Scenario: Flush waits for targets
- **WHEN** one captured target store remains blocked
- **THEN** flush remains pending while unrelated document actors continue processing commands

#### Scenario: Flush attempt fails
- **WHEN** a captured target's immediate store attempt fails
- **THEN** flush reports that failure, the document stays dirty, and later automatic retry remains eligible

#### Scenario: Aggregate failures
- **WHEN** multiple document stores and one or more subsystem barriers fail during one flush
- **THEN** flush attempts every captured document and applicable barrier and returns one aggregate containing every failure

#### Scenario: Unchanged control state
- **WHEN** control state has not changed since its last successful durability barrier
- **THEN** flush is not required to invoke the control-store barrier
