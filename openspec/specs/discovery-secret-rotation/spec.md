## Purpose

TBD: Define revocation-driven discovery-secret rotation, authenticated distribution, bounded offline migration, and monotonic epoch handling.

## Requirements

### Requirement: Revocation immediately removes local authorization
Revoking a device SHALL durably set its local status to revoked, close its active connections, remove its endpoints from active routing, and reject later normal synchronization before attempting discovery-secret rotation.

#### Scenario: Connected peer is revoked
- **WHEN** the user revokes a currently connected device
- **THEN** its Repo session closes and no later connection from its pinned key is admitted

### Requirement: Epoch-secret rotation
After revocation the application SHALL generate a new high-entropy discovery secret, increment the epoch, durably store both before activating them, and MUST NOT send the new secret to the revoked device.

#### Scenario: Rotation begins
- **WHEN** local revocation commits successfully
- **THEN** normal advertisement switches to a selector derived from the new epoch and secret

#### Scenario: Revoked device retains old secret
- **WHEN** the revoked device continues using the prior discovery secret
- **THEN** it cannot derive the new selector or routing tokens and still fails cryptographic trust checks

### Requirement: Authenticated distribution to remaining devices
The newest discovery secret and epoch SHALL be sent only over authenticated control channels to locally trusted non-revoked devices, and recipients SHALL persist them before acknowledging and advertising the new epoch.

#### Scenario: Online remaining peer
- **WHEN** a non-revoked trusted device is connected during rotation
- **THEN** it receives, stores, acknowledges, and adopts the new epoch

#### Scenario: Revoked peer requests update
- **WHEN** a revoked identity opens or retains a control channel
- **THEN** the channel is closed and no new secret bytes are sent

### Requirement: Bounded offline migration
The rotator SHALL retain bounded non-advertised migration state that can browse the previous selector and use last-known endpoints to update remaining trusted peers later, without restoring trust to revoked devices.

#### Scenario: Trusted peer is offline during rotation
- **WHEN** it later appears on an old selector or last-known endpoint and authenticates as still trusted
- **THEN** the rotator supplies the newest epoch and the peer joins current normal discovery

#### Scenario: Migration retention expires
- **WHEN** configured previous-epoch retention ends
- **THEN** obsolete secret material is removed and affected offline peers require another trusted route or re-pairing

### Requirement: Monotonic epoch acceptance
Devices SHALL accept only authenticated discovery-secret updates whose epoch is newer than their current epoch and SHALL handle duplicate current updates idempotently.

#### Scenario: Older update is replayed
- **WHEN** a valid control message for an older epoch arrives
- **THEN** it is ignored without changing the active secret or advertisement
