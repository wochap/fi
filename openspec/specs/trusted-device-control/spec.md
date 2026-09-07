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
