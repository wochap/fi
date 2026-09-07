## Purpose

Define cryptographically authenticated peer admission, trust enforcement, and typed connection lifecycle boundaries for repository sessions.

## Requirements

### Requirement: TLS key identity binding
Each normal QUIC endpoint SHALL present a self-issued certificate whose subject public key is the permanent device identity key, and verification SHALL derive DeviceId from and prove possession of that presented key.

#### Scenario: Pinned key connects
- **WHEN** a certificate contains the public key pinned for a trusted DeviceId and TLS handshake signature verification succeeds
- **THEN** the connection can advance to authenticated state

#### Scenario: Certificate bytes rotate
- **WHEN** a peer presents a newly generated valid certificate containing the same pinned public key
- **THEN** its DeviceId and trust remain valid

#### Scenario: Claimed identity mismatches key
- **WHEN** a connection claims a DeviceId not derived from its certificate public key
- **THEN** authentication fails and no Repo network event is emitted

### Requirement: Trust gate before Repo admission
Only a peer whose DeviceId and exact public key have a locally `trusted` control record SHALL be converted to an authenticated Repo session; unknown and revoked peers MUST be closed before Repo admission.

#### Scenario: Unknown peer connects
- **WHEN** a cryptographically valid but unknown device opens the sync ALPN
- **THEN** the application closes it and the Repo observes no connection or message event

#### Scenario: Revoked peer connects
- **WHEN** a device matching a locally revoked record opens the sync ALPN
- **THEN** the application closes it and the Repo observes no connection or message event

### Requirement: Authenticated connection typestate boundary
The networking implementation SHALL make session registration unavailable to an unauthenticated connection value and SHALL attach a validated `DeviceId` to the authenticated value supplied to transport registration.

#### Scenario: New accepted connection
- **WHEN** Quinn accepts a TLS connection but application trust checks have not completed
- **THEN** only unauthenticated operations are available and Repo registration cannot be invoked through the normal typed API

### Requirement: Explicit peer connection states
The application SHALL retain typed peer connection states covering disconnected, connecting, authenticating, connected, syncing, synced, and failed transitions.

#### Scenario: Authentication succeeds
- **WHEN** a trusted peer completes stream setup
- **THEN** state advances through authenticating to connected before Repo synchronization status is applied

#### Scenario: Connection fails
- **WHEN** route, TLS, trust, stream, or transport setup fails
- **THEN** state becomes failed with a safe category and can later transition through a fresh connection attempt
