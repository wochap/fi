## Purpose

Define durable local trusted-device control records, whole-repository authorization, friendly-name metadata, and secure discovery-secret storage.

## Requirements

### Requirement: Persistent trusted-device records
`control.sqlite` SHALL store each known peer's DeviceId, exact permanent public key, friendly display name, paired timestamp, last-seen timestamp, last-sync timestamp, and status of `trusted` or `revoked`.

#### Scenario: Pairing commits
- **WHEN** bilateral pairing commit succeeds
- **THEN** each side has a durable trusted record for the peer with matching DeviceId and public key

#### Scenario: Application restarts
- **WHEN** the application reopens after successful pairing
- **THEN** the peer remains trusted with its friendly name and recorded timestamps

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
