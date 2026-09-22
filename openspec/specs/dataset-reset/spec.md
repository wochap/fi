## Purpose

TBD: Define the deliberate, crash-safe, local-only dataset reset that returns an installation to `NeedsDecision` while preserving device identity.

## Requirements

### Requirement: Deliberate local dataset reset
The application SHALL provide a deliberate, user-invoked reset that abandons this device's local copy of its root and returns the installation to `NeedsDecision`, from which the user can create a new root or join a peer's root.

#### Scenario: Reset from a ready installation
- **WHEN** the user confirms a dataset reset on an installation in `Ready`
- **THEN** the installation reopens in `NeedsDecision` with no bootstrap record, no Automerge documents, no read-model checkpoint, and no trusted-device records

#### Scenario: Reset from an installation that cannot open
- **WHEN** the user confirms a dataset reset on an installation whose open failed with a reset-resolvable error
- **THEN** the reset runs without requiring a live application core and the installation reopens in `NeedsDecision`

### Requirement: Reset is scoped to root-bound state
Reset SHALL remove every piece of local state that is meaningful only relative to the abandoned root and SHALL preserve every piece of state that identifies the installation independent of a root.

#### Scenario: Root-scoped state is removed
- **WHEN** a reset completes
- **THEN** the bootstrap record, Automerge snapshots, read-model database, trusted-peer records, trusted-device records, peer-connection records, pairing journal, discovery epoch, discovery rotation, and the current and previous discovery-group secrets are all absent

#### Scenario: Device identity is preserved
- **WHEN** a reset completes and the installation reopens
- **THEN** the device signing key and `DeviceId` are the same as before the reset

### Requirement: Reset is crash-safe by write-ahead intent
Reset SHALL durably record its intent in `control.sqlite` before any destructive step, SHALL perform the removal of root-scoped control rows and the clearing of the intent in one transaction as the final step, and SHALL be resumable from any interruption.

#### Scenario: Crash after secrets are removed
- **WHEN** the process terminates after the discovery secrets are removed but before the control rows are deleted
- **THEN** the next open finds the intent, completes the remaining deletions, and reaches `NeedsDecision` without reporting an inconsistent store

#### Scenario: Crash after snapshots are removed
- **WHEN** the process terminates after Automerge snapshots are removed while the bootstrap record still says `Ready`
- **THEN** the next open finds the intent, completes the reset, and does not raise a missing-root or orphaned-document error

#### Scenario: Crash after the final transaction
- **WHEN** the process terminates after the final transaction committed
- **THEN** the next open finds no intent and opens normally in `NeedsDecision`

#### Scenario: Interrupted reset resumes on every opener
- **WHEN** an outstanding reset intent exists and the application is opened through any opener, networked or local
- **THEN** the reset is completed before bootstrap validation runs

### Requirement: Reset intent takes precedence over bootstrap validation and recovery
When a reset intent is outstanding, the application SHALL complete the reset before performing bootstrap consistency validation or any recovery classification, so that a partially deleted dataset is never treated as a lost or corrupt one.

#### Scenario: Partially deleted store is not quarantined
- **WHEN** an outstanding reset intent exists and snapshots remain without a bootstrap record
- **THEN** the snapshots are deleted as part of the reset rather than quarantined or reported as orphaned

### Requirement: Reset aborts safely when a step cannot complete
If a destructive step fails for a reason other than the target already being absent, reset SHALL stop, leave the intent set, report the failure, and SHALL NOT proceed to later steps.

#### Scenario: Secure store is locked
- **WHEN** the secure key store reports it is locked or unavailable during secret removal
- **THEN** reset reports that error, the intent remains set, no snapshot or control row is deleted, and the next open re-attempts the reset

#### Scenario: Target already absent
- **WHEN** a secret, snapshot directory, or read-model file to be removed does not exist
- **THEN** the step succeeds and reset continues

### Requirement: Reset is local and does not notify peers
Reset SHALL NOT send any message to peers, SHALL NOT attempt remote revocation, and SHALL NOT rotate the discovery-group secret on other devices. The confirmation presented to the user SHALL state this.

#### Scenario: Peers retain their records
- **WHEN** device A resets while device B holds a trusted-device record for A
- **THEN** B's record for A is unchanged and B receives no notification

### Requirement: Reset requires explicit confirmation stating consequences
Every reset entry point SHALL require an explicit confirmation that states: the reset deletes this device's only local copy; other devices keep their copies; if this is the only device the data is permanently lost; other devices are not notified.

#### Scenario: User declines
- **WHEN** the user dismisses the confirmation
- **THEN** no intent is written and no state changes

#### Scenario: Trusted-device count is shown
- **WHEN** the confirmation is opened from the devices surface
- **THEN** it shows how many trusted devices this installation currently records
