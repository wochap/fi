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

### Requirement: Previous-epoch retention works on every shipping keystore
Every `SecureKeyStore` implementation shipped on a supported platform SHALL retain, load, and remove
the previous-epoch discovery secret. An implementation that cannot retain SHALL report that failure
rather than inheriting a default that silently degrades rotation. Rotation behaviour SHALL NOT depend
on which platform keystore is in use, and conformance SHALL be demonstrated against the shipping
desktop keystore and not only against an in-memory test double.

#### Scenario: Revocation rotates on the shipping desktop keystore
- **WHEN** a device is revoked on a platform whose keystore is the shipping desktop implementation
- **THEN** the previous secret is retained for the bounded migration window, the epoch advances, and
  the new secret is distributed to remaining trusted devices

#### Scenario: Retention is genuinely unavailable
- **WHEN** the platform keystore cannot store retained secret material, including when the secret
  service is absent, unreachable, or locked
- **THEN** rotation reports that failure explicitly and no caller mistakes it for a completed rotation

#### Scenario: Retention does not outlive its bound
- **WHEN** the configured previous-epoch retention window expires
- **THEN** the retained secret material is removed through the same keystore that stored it

### Requirement: Rotation failure does not undo or obscure revocation
Revocation SHALL complete and be reported as completed independently of whether the subsequent
discovery-secret rotation succeeds. The mandated ordering — local authorization removed and later
normal synchronization rejected before rotation is attempted — SHALL be preserved. When rotation
fails, the durable revocation SHALL remain in effect, the failure SHALL be surfaced separately as a
retriable condition, and distribution of the new secret to remaining devices SHALL be attempted again
on retry rather than being silently skipped.

#### Scenario: Rotation fails after revocation committed
- **WHEN** revocation has durably committed and the subsequent rotation fails
- **THEN** the caller is told the device is revoked, the revoked device remains unauthorized and
  disconnected, and the rotation failure is reported as a distinct retriable condition

#### Scenario: Rotation is retried
- **WHEN** a previously failed rotation is retried after the underlying keystore failure is resolved
- **THEN** the epoch advances, the previous secret is retained, and remaining trusted devices receive
  the new secret over authenticated control channels
