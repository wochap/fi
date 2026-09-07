## Purpose

Define device-oriented endpoint discovery, expiry, selection, and deterministic connection initiation across route sources.

## Requirements

### Requirement: Device-oriented endpoint registry
The application SHALL maintain zero or more expiring `NetworkEndpoint` values per `DeviceId`, including route source, socket address, observation time, expiry, and interface scope where required.

#### Scenario: Endpoint address changes
- **WHEN** a provider supplies a new LAN endpoint for an existing DeviceId
- **THEN** the registry updates that device's routes without changing trust or Repo identity

#### Scenario: Endpoint expires
- **WHEN** an endpoint passes its expiry without refresh
- **THEN** it is excluded from connection selection without revoking the device

### Requirement: Extensible endpoint sources
`EndpointSource` SHALL support LAN and reserve a distinct Tailscale variant without introducing either source into the custom Repo API or wire protocol.

#### Scenario: Repo receives a routed connection
- **WHEN** a connection through any endpoint source authenticates successfully
- **THEN** the Repo receives only the peer's authenticated `PeerId` and complete frames

### Requirement: Pure endpoint selection policy
Endpoint ranking SHALL be deterministic and side-effect-free, prefer eligible LAN endpoints over future Tailscale endpoints, and account for expiry, recent success, and bounded failure backoff within a source.

#### Scenario: LAN and Tailscale endpoints exist
- **WHEN** both sources contain eligible routes for one device
- **THEN** the current strategy selects LAN first

#### Scenario: Preferred endpoint fails
- **WHEN** connection to the selected endpoint fails
- **THEN** the connection manager records bounded backoff and can attempt the next eligible endpoint without changing Repo state

### Requirement: Deterministic normal dialing
When both trusted devices can initiate a normal connection, connection orchestration SHALL use a deterministic DeviceId-based preferred initiator and SHALL still resolve simultaneous sessions safely.

#### Scenario: Both devices learn endpoints
- **WHEN** two trusted peers learn each other's endpoints at the same time
- **THEN** the preferred initiator rule avoids stable duplicate connections and both ultimately select one authenticated session
