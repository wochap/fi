## Purpose

TBD: Define classification of inconsistent local bootstrap state, root-preserving snapshot recovery from trusted peers, quarantine of corrupt or orphaned snapshots, and observable, bounded recovery outcomes.

## Requirements

### Requirement: Recoverable versus fatal classification
Bootstrap validation SHALL classify every inconsistent local state as either recoverable or fatal before opening fails or proceeds. A state SHALL be classified recoverable only when the recorded root ID is still known and an external authority can re-supply that root's content. Every other inconsistency SHALL remain fatal and SHALL be reported with structured context.

#### Scenario: Recoverable root snapshot loss
- **WHEN** opening finds a `Ready` record whose root snapshot is absent while the control store and secure key store are intact
- **THEN** the state is classified recoverable and opening proceeds into recovery rather than failing

#### Scenario: Fatal conflicting documents
- **WHEN** opening finds a `Creating` or `Joining` record alongside documents other than the recorded root
- **THEN** the state is classified fatal, opening fails without mutation, and no document is selected or discarded on the user's behalf

#### Scenario: Fatal unreadable control store
- **WHEN** the bootstrap record cannot be read because its version, state value, or root identifier is malformed
- **THEN** the state is classified fatal because no root ID is known, and opening fails without inferring or minting a replacement root

#### Scenario: Fatal non-root corruption
- **WHEN** a listed document that is not the recorded root cannot be strictly loaded
- **THEN** the state is classified fatal and the failure is reported before any transport event receiver is consumed

### Requirement: Root-preserving snapshot recovery
Recovery from a lost or unloadable recorded root SHALL preserve the exact recorded root ID, transition the bootstrap record to `Joining` for that root, and obtain the root content from trusted peers through root-only synchronization. Recovery SHALL NOT create a local root change, SHALL NOT mint a new root ID, and SHALL NOT require a new pairing ceremony when the device remains trusted by its peers.

#### Scenario: Recover from a trusted peer
- **WHEN** a device that lost its root snapshot but retained its control store, identity key, and discovery secret opens and reaches a trusted peer
- **THEN** it resumes as `Joining` for the same recorded root, re-synchronizes that root without any SAS confirmation, and becomes `Ready` for the identical root ID

#### Scenario: Recovery never re-mints a root
- **WHEN** recovery is available for a known root ID
- **THEN** the repository does not transition to `NeedsDecision` and does not initialize a new root, so no `RootMismatch` is introduced against the user's other devices

#### Scenario: Authoritative writes remain gated during recovery
- **WHEN** a collection or record command is issued while the repository is recovering
- **THEN** the command is rejected by the existing joining write gate and commits no authoritative or projected data

### Requirement: Corrupt root classified during load
Snapshot loading SHALL classify a load failure for the recorded root under a `Ready` or `Joining` record as recoverable absence rather than a fatal error, while preserving the existing guarantee that all other load failures are reported before network events are consumed.

#### Scenario: Corrupt root under Ready record
- **WHEN** the recorded root snapshot exists but cannot be strictly loaded and the record is `Ready`
- **THEN** the unloadable bytes are quarantined, the document is treated as absent, and recovery proceeds for the same root ID

#### Scenario: Corruption ordering preserved
- **WHEN** any snapshot load failure is classified fatal
- **THEN** opening fails with its document and storage-path context before consuming transport events

### Requirement: Quarantine preserves bytes
Recovery SHALL move corrupt and orphaned snapshots into a quarantine location inside the resolved application-data directory instead of deleting them. Quarantine entries SHALL retain enough information to identify the original document ID and the quarantine reason, and quarantine SHALL complete before any control-store transition that depends on it.

#### Scenario: Corrupt root quarantined
- **WHEN** a corrupt root snapshot is classified recoverable
- **THEN** its bytes are moved to quarantine, the original document ID and reason remain determinable, and no authoritative snapshot is destroyed

#### Scenario: Crash during quarantine
- **WHEN** the process is interrupted while quarantining
- **THEN** a later open finds the quarantined bytes and converges without duplicating or losing them

### Requirement: Orphaned documents quarantine and decide
Opening SHALL treat documents present without a bootstrap record as a recoverable state by quarantining them and entering `NeedsDecision`, rather than failing fatally. Quarantining SHALL NOT infer a root, SHALL NOT replace control state, and SHALL NOT delete the documents.

#### Scenario: Orphaned documents on open
- **WHEN** document files exist without a bootstrap record
- **THEN** they are moved to quarantine, opening succeeds in `NeedsDecision`, and no root is inferred

#### Scenario: Orphaned documents with unreadable control store
- **WHEN** the control store cannot be opened but Automerge documents are present
- **THEN** opening fails visibly while the documents are quarantined rather than lost

### Requirement: Orphan adoption on re-pairing
After orphaned documents are quarantined, a subsequent explicit join SHALL adopt a quarantined document whose ID exactly matches the joined root and which loads strictly, in preference to waiting for peer synchronization. Adoption SHALL fall through to normal root-only synchronization when either condition is unmet.

#### Scenario: Quarantined orphan matches rejoined root
- **WHEN** the user re-pairs and joins a root whose ID matches a quarantined document that loads strictly
- **THEN** that document is adopted as the root placeholder and its history is preserved and merged with the group

#### Scenario: Quarantined orphan does not match
- **WHEN** the joined root ID matches no quarantined document
- **THEN** the quarantine is left untouched and the root is obtained through peer synchronization

### Requirement: Recovery is observable
Recovery SHALL emit a typed, queryable record of its reason, affected document, quarantine location, and outcome, surfaced through the bootstrap signal path so clients can distinguish recovering, recovered, no-peer-available, and fatal states. Recovery SHALL NOT be silent.

#### Scenario: Client renders recovery
- **WHEN** recovery begins during open
- **THEN** the bootstrap signal reports that the dataset is being recovered from other devices rather than reporting a fatal error or an indeterminate progress state

#### Scenario: Outcome reported
- **WHEN** recovery completes or exhausts its peer options
- **THEN** the reported outcome distinguishes success, no-peer-available, and fatal, and names the affected root

### Requirement: No-peer outcome is honest and bounded
When no trusted peer can supply the recorded root, recovery SHALL report a distinct no-peer-available outcome, SHALL keep the repository in `Joining` for the same root so a later launch or a later peer can complete it, SHALL retain quarantined bytes, and SHALL NOT transition to `NeedsDecision`.

#### Scenario: Single device loses its snapshot
- **WHEN** the only device in a group loses its root snapshot and no trusted peer is reachable
- **THEN** the user is told that recovery needs another device, the root ID is retained, and creating a new dataset is not offered as an automatic fallback

#### Scenario: Peer appears later
- **WHEN** a trusted peer becomes reachable after a no-peer-available outcome
- **THEN** the still-`Joining` repository completes recovery for the same root without a new pairing ceremony

### Requirement: Bounded recovery attempts
Recovery SHALL bound the number of attempts made for a given root and SHALL escalate to a fatal, user-visible outcome once the bound is exceeded, so that a repeatedly failing recovery cannot loop indefinitely.

#### Scenario: Repeated recovery failure
- **WHEN** recovery for the same root fails and is retried beyond the configured bound across launches
- **THEN** opening reports a fatal outcome that names the root and the repeated failure, and quarantined bytes remain available

### Requirement: Reset intent takes precedence
An outstanding deliberate-reset intent SHALL take precedence over recovery classification, so an interrupted reset resumes as a reset rather than recovering the root the user asked to abandon.

#### Scenario: Crash mid-reset
- **WHEN** opening finds an outstanding reset intent alongside inconsistent bootstrap state
- **THEN** recovery is not attempted and the reset is resumed to completion
