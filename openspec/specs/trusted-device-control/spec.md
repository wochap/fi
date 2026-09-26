## Purpose

Define durable local trusted-device control records, whole-repository authorization, friendly-name metadata, and secure discovery-secret storage.

## Requirements

### Requirement: Persistent trusted-device records
`control.sqlite` SHALL store each known peer's DeviceId, exact permanent public key, friendly display name, paired timestamp, last-seen timestamp, last-sync timestamp, and status of `trusted` or `revoked`. The last-seen timestamp SHALL be refreshed when an authenticated session with the peer is established, and the last-sync timestamp SHALL be recorded when the peer reaches the synced state, through an update that touches only those timestamps so it cannot overwrite a concurrent rename or revocation. Timestamp writes caused by repeated convergence SHALL be throttled per peer so a burst of synchronization produces a bounded number of writes.

#### Scenario: Pairing commits
- **WHEN** bilateral pairing commit succeeds
- **THEN** each side has a durable trusted record for the peer with matching DeviceId and public key

#### Scenario: Application restarts
- **WHEN** the application reopens after successful pairing
- **THEN** the peer remains trusted with its friendly name and recorded timestamps

#### Scenario: Peer converges
- **WHEN** a trusted peer transitions into the synced state
- **THEN** its record's last-sync timestamp is set to the current time before the synced state is published, and the last-seen timestamp is no older than the session's establishment

#### Scenario: Convergence repeats quickly
- **WHEN** a peer leaves and re-enters the synced state several times within the throttle window
- **THEN** at most one last-sync write occurs for that peer in that window

#### Scenario: Timestamp write races a rename
- **WHEN** a last-sync write and a friendly-name change for the same device are applied concurrently
- **THEN** both the new name and the new timestamp persist

### Requirement: Local trust authorizes complete Repo access
A locally trusted peer with a compatible root SHALL synchronize every Repo document, while unknown or locally revoked peers SHALL synchronize none; document-level ACLs MUST NOT be introduced.

#### Scenario: Trusted compatible peer connects
- **WHEN** its pinned normal session becomes authenticated and roots match
- **THEN** the existing Repo whole-collection protocol synchronizes all documents

#### Scenario: Unknown group member connects
- **WHEN** a device knows the discovery group secret but has no local trusted record
- **THEN** normal authentication rejects it before Repo synchronization

### Requirement: Friendly-name management is local metadata
A device friendly name SHALL be editable in local control state and MUST NOT participate in cryptographic identity or authorization.

#### Scenario: Peer is renamed
- **WHEN** the user changes a trusted device's display name
- **THEN** its DeviceId, public key, paired time, trust status, and synchronized data are unchanged

### Requirement: Discovery secret is securely stored
The high-entropy discovery-group secret SHALL be stored through `SecureKeyStore`, while its non-secret current epoch and recovery metadata SHALL be stored in `control.sqlite`.

#### Scenario: First ready device pairs
- **WHEN** a ready installation has no discovery secret and begins a successful first pairing
- **THEN** it generates one secret, stores it securely, assigns an initial epoch, and provisions it only after bilateral confirmation

### Requirement: Trust is local rather than transitive
Pairing one device SHALL NOT automatically trust other devices merely because they share a discovery secret or are trusted by the paired peer.

#### Scenario: Third device shares group secret
- **WHEN** it is discovered but its public key has never been paired locally
- **THEN** it remains unknown and cannot enter the local Repo transport

### Requirement: Durable record state and reported outcome agree
A mutation of a trusted-device record SHALL report an outcome that agrees with the state durably
persisted for that record. An operation that commits a record change and then fails in a later stage
SHALL NOT report overall failure in a way that implies the committed change did not occur, and SHALL
identify which stage failed.

#### Scenario: Revocation commits but a later stage fails
- **WHEN** a device record is durably set to revoked and a subsequent stage of the same operation fails
- **THEN** the reported outcome states that the device is revoked and identifies the failed stage,
  rather than reporting an unqualified failure

#### Scenario: Revocation is queried after a partial failure
- **WHEN** the trusted-device list is queried after a revocation whose later stage failed
- **THEN** the device is presented as revoked, consistent with its durable record, and is not
  presented as trusted or merely hidden

### Requirement: Trust records are root-scoped
Trusted-peer and trusted-device records, the pairing journal, the discovery epoch, and the discovery-group secret SHALL be treated as state of the root this installation holds, and a dataset reset SHALL remove all of them.

#### Scenario: Trust after reset
- **WHEN** an installation with trusted devices resets its dataset
- **THEN** it reopens with no trusted devices, no discovery secret, and cannot enter any peer's Repo transport until it pairs again

### Requirement: Re-pairing after reset re-establishes trust only through SAS
A device that reset and pairs again with a peer that previously trusted or revoked it SHALL be trusted by that peer only after the peer's user confirms a fresh SAS. The peer's record is upserted under the same `DeviceId`.

#### Scenario: Peer had revoked the device
- **WHEN** a previously revoked device resets and completes SAS-confirmed pairing with the revoking peer
- **THEN** the peer's record for that `DeviceId` becomes trusted, because the peer's user explicitly confirmed it

#### Scenario: Peer still trusted the device
- **WHEN** a device resets and pairs again with a peer that still records it as trusted
- **THEN** the peer's record is updated in place rather than duplicated

### Requirement: Revoked device records can be deleted locally
A device record in the `revoked` state SHALL be permanently removable from local control state by an explicit user action. Deletion SHALL remove the record from both the trusted-device and trusted-peer tables in one transaction, SHALL be refused for a record in the `trusted` state, SHALL report whether a record was removed, and MUST NOT notify any peer or rotate the discovery secret.

#### Scenario: Revoked record is deleted
- **WHEN** the user deletes a device whose record is revoked
- **THEN** the trusted-device list no longer contains that DeviceId, the peer table holds no row for it, and no other device record changes

#### Scenario: Trusted record cannot be deleted
- **WHEN** deletion is requested for a device whose record is trusted
- **THEN** the operation is refused, reports that nothing was removed, and the record remains trusted

#### Scenario: Deletion of an unknown device
- **WHEN** deletion is requested for a DeviceId with no record
- **THEN** the operation reports that nothing was removed and does not fail

#### Scenario: Deletion is local
- **WHEN** a revoked record is deleted
- **THEN** the discovery epoch and secret are unchanged and no message is sent to any peer

### Requirement: Re-pairing after deletion creates a fresh record
A device whose record was deleted SHALL be treated as unknown: it cannot enter the Repo transport, and pairing it again SHALL require a fresh SAS confirmation and SHALL create a new record whose paired timestamp is the time of the new pairing.

#### Scenario: Deleted device connects without pairing
- **WHEN** a device whose record was deleted attempts a normal authenticated session
- **THEN** it is rejected exactly as an unknown device is rejected

#### Scenario: Deleted device pairs again
- **WHEN** a deleted device completes SAS-confirmed pairing
- **THEN** the devices list shows it as trusted with a paired timestamp from the new pairing, not from the deleted record
