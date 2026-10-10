## Purpose

Define durable local trusted-device control records, whole-repository authorization, friendly-name metadata, and secure discovery-secret storage.

## Requirements

### Requirement: Persistent trusted-device records
`control.sqlite` SHALL store each known peer's DeviceId, exact permanent public key, announced name, optional local nickname, paired timestamp, last-seen timestamp, last-sync timestamp, and status of `trusted` or `revoked`. The last-seen timestamp SHALL be refreshed when an authenticated session with the peer is established, and the last-sync timestamp SHALL be recorded when the peer reaches the synced state, through an update that touches only those timestamps so it cannot overwrite a concurrent rename, name announcement or revocation. Timestamp writes caused by repeated convergence SHALL be throttled per peer so a burst of synchronization produces a bounded number of writes.

#### Scenario: Pairing commits
- **WHEN** bilateral pairing commit succeeds
- **THEN** each side has a durable trusted record for the peer with matching DeviceId and public key, the peer's hello name as its announced name, and no nickname

#### Scenario: Application restarts
- **WHEN** the application reopens after successful pairing
- **THEN** the peer remains trusted with its announced name, nickname and recorded timestamps

#### Scenario: Peer converges
- **WHEN** a trusted peer transitions into the synced state
- **THEN** its record's last-sync timestamp is set to the current time before the synced state is published, and the last-seen timestamp is no older than the session's establishment

#### Scenario: Convergence repeats quickly
- **WHEN** a peer leaves and re-enters the synced state several times within the throttle window
- **THEN** at most one last-sync write occurs for that peer in that window

#### Scenario: Timestamp write races a rename
- **WHEN** a last-sync write and a nickname change for the same device are applied concurrently
- **THEN** both the new nickname and the new timestamp persist

#### Scenario: Name announcement races a rename
- **WHEN** an announced-name update and a nickname change for the same device are applied concurrently
- **THEN** both the new announced name and the new nickname persist

### Requirement: Local trust authorizes complete Repo access
A locally trusted peer with a compatible root SHALL synchronize every Repo document, while unknown or locally revoked peers SHALL synchronize none; document-level ACLs MUST NOT be introduced.

#### Scenario: Trusted compatible peer connects
- **WHEN** its pinned normal session becomes authenticated and roots match
- **THEN** the existing Repo whole-collection protocol synchronizes all documents

#### Scenario: Unknown group member connects
- **WHEN** a device knows the discovery group secret but has no local trusted record
- **THEN** normal authentication rejects it before Repo synchronization

### Requirement: Friendly-name management is local metadata
A device's nickname SHALL be editable in local control state and MUST NOT participate in cryptographic identity or authorization. A nickname SHALL be stored trimmed and accepted only when the trimmed text is non-empty and at most 64 UTF-8 bytes; setting an empty nickname SHALL clear it. Renaming SHALL change only the nickname, never the announced name. The name the devices list presents SHALL be the nickname when one is set and the announced name otherwise.

#### Scenario: Peer is renamed
- **WHEN** the user changes a trusted device's nickname
- **THEN** its DeviceId, public key, announced name, paired time, trust status, and synchronized data are unchanged

#### Scenario: Nickname is trimmed
- **WHEN** the user saves the nickname " Work laptop "
- **THEN** the stored nickname is "Work laptop"

#### Scenario: Nickname cleared
- **WHEN** the user saves an empty nickname for a device announcing "Gean's ThinkPad"
- **THEN** the record has no nickname and the device is presented as "Gean's ThinkPad"

#### Scenario: Overlong nickname refused
- **WHEN** the user saves a nickname whose trimmed text is longer than 64 UTF-8 bytes
- **THEN** the rename fails with a validation error and the previous nickname is kept

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

### Requirement: Sessions refresh the announced name
When an authenticated session with a trusted peer receives the peer's repository Hello, the application SHALL store the device name it carries as that peer's announced name, through an update that touches only the announced name, and SHALL emit the updated record to the devices list. The nickname SHALL NOT change. A Hello name that is empty after trimming or longer than 64 UTF-8 bytes SHALL be a protocol error for that peer. An announcement equal to the stored announced name SHALL NOT write.

#### Scenario: Peer renamed itself
- **WHEN** a peer recorded with announced name "Fi 9a01c3e2" connects and its Hello carries "Gean's ThinkPad"
- **THEN** its record's announced name becomes "Gean's ThinkPad" and the devices list shows "Gean's ThinkPad"

#### Scenario: Nickname wins over announcement
- **WHEN** a peer with nickname "Work laptop" connects announcing "Gean's ThinkPad"
- **THEN** the record keeps nickname "Work laptop", its announced name becomes "Gean's ThinkPad", and the list still presents "Work laptop"

#### Scenario: Unchanged announcement
- **WHEN** a peer reconnects announcing the name already stored
- **THEN** no announced-name write occurs

### Requirement: Control store migrates device names in place
Opening a `control.sqlite` created before announced names existed SHALL add the announced-name column and make the nickname optional without losing any record, and SHALL be idempotent across repeated opens and interrupted upgrades. For each existing record, a stored name of the generated form "Fi " followed by eight lowercase hex characters SHALL become its announced name with no nickname; any other stored name SHALL become its nickname, with the announced name set to the generated form for that DeviceId until the peer next announces.

#### Scenario: Generated name migrates to announced
- **WHEN** a store holding a record named "Fi 9a01c3e2" is opened by the new version
- **THEN** that record has announced name "Fi 9a01c3e2" and no nickname

#### Scenario: Typed name migrates to nickname
- **WHEN** a store holding a record for DeviceId `f755167e…` named "Kitchen tablet" is opened by the new version
- **THEN** that record has nickname "Kitchen tablet" and announced name "Fi f755167e"

#### Scenario: Migration is idempotent
- **WHEN** the migrated store is opened again
- **THEN** no schema change or data change occurs and every record is unchanged
