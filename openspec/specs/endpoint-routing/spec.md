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

#### Scenario: Address changes after a previous success
- **WHEN** a peer that was previously reached at one address is rediscovered at a different address or port while the old endpoint is still unexpired
- **THEN** the new endpoint is eligible immediately with no backoff, and one connection attempt that fails on the stale endpoint proceeds to the new endpoint within the same attempt rather than waiting for the stale endpoint to expire

### Requirement: Extensible endpoint sources
`EndpointSource` SHALL support LAN and reserve a distinct Tailscale variant without introducing either source into the custom Repo API or wire protocol.

#### Scenario: Repo receives a routed connection
- **WHEN** a connection through any endpoint source authenticates successfully
- **THEN** the Repo receives only the peer's authenticated `PeerId` and complete frames

### Requirement: Pure endpoint selection policy
Endpoint ranking SHALL be deterministic and side-effect-free, prefer eligible LAN endpoints over future Tailscale endpoints, and account for expiry, recent success, and bounded failure backoff within a source. Eligibility SHALL additionally require that the endpoint address be one the peer can be reached on; loopback addresses and addresses belonging to host-local container, virtualization, or tunnel bridge interfaces learned from a remote peer's advertisement SHALL NOT be eligible, and ranking SHALL NOT promote an ineligible address above an eligible one.

#### Scenario: LAN and Tailscale endpoints exist
- **WHEN** both sources contain eligible routes for one device
- **THEN** the current strategy selects LAN first

#### Scenario: Preferred endpoint fails
- **WHEN** connection to the selected endpoint fails
- **THEN** the connection manager records bounded backoff and can attempt the next eligible endpoint without changing Repo state

#### Scenario: Ineligible address outranks eligible address
- **WHEN** a remote peer's advertisement yields both a host-local address and a routable address, and the host-local address would otherwise rank first
- **THEN** selection returns the routable address and never returns the host-local one

#### Scenario: Only ineligible addresses exist
- **WHEN** every address learned for a peer is loopback or host-local virtual
- **THEN** selection returns no endpoint rather than dialing an address that cannot reach the peer

### Requirement: Deterministic normal dialing
Connection orchestration SHALL dial a trusted peer whenever a normal-discovery endpoint is learned for it and it has no live session, and SHALL use a deterministic DeviceId-based preferred initiator to decide who dials first. The preferred initiator SHALL dial at once; the non-preferred side SHALL dial after a bounded delay if no session has been established by then, so that an absent or backgrounded preferred initiator cannot leave both devices offline. At most one connection attempt per peer SHALL be in flight at a time, and simultaneous sessions SHALL still resolve safely to one authenticated session.

#### Scenario: Both devices learn endpoints
- **WHEN** two trusted peers learn each other's endpoints at the same time
- **THEN** the preferred initiator rule avoids stable duplicate connections and both ultimately select one authenticated session

#### Scenario: Discovered peer with no session is dialed
- **WHEN** normal discovery resolves an endpoint for a trusted, non-revoked peer whose connection state is absent, disconnected, or failed
- **THEN** a connection attempt to that peer starts without any user action and without a pending discovery-secret rotation

#### Scenario: Preferred initiator is absent
- **WHEN** the non-preferred side learns the preferred initiator's endpoint and no session has been established after the bounded delay
- **THEN** the non-preferred side dials and, if the preferred side later dials too, exactly one session survives

#### Scenario: Peer already has a live session
- **WHEN** discovery re-resolves an endpoint for a peer that is connecting, authenticating, connected, syncing, or synced
- **THEN** no new connection attempt is started for that peer

### Requirement: Automatic reconnect with bounded backoff
Connection orchestration SHALL retry a trusted peer that has eligible endpoints but no live session, waking no earlier than the earliest endpoint backoff deadline and never busy-looping. A lost session SHALL schedule a retry after the minimum backoff. Retries SHALL stop when every endpoint for the peer has expired and SHALL resume when a new endpoint is learned. Each dial attempt SHALL be bounded by a dial timeout so an unreachable address fails within that bound and the next eligible endpoint is tried. While a retry is scheduled or a new endpoint may still arrive, a route-level failure (`NoRoute`, `Route`, `Transport`, `Stream`) SHALL contribute `Searching` to the aggregate sync status rather than `Error`; trust and TLS failures SHALL still contribute `Error`.

#### Scenario: Session drops on both sides
- **WHEN** an established session between two trusted peers ends because one side lost connectivity and later regains it
- **THEN** both sides re-establish one authenticated session without restarting either application, and the elapsed time is bounded by endpoint refresh plus the maximum backoff

#### Scenario: Peer is unreachable for a while
- **WHEN** every dial to a peer's endpoints fails repeatedly
- **THEN** the interval between attempts grows from the minimum to the maximum backoff and no attempt starts before an endpoint's backoff deadline

#### Scenario: Endpoints expire
- **WHEN** a peer's endpoints all pass their expiry while it remains unreachable
- **THEN** no further attempt is scheduled until discovery learns a new endpoint for that peer

#### Scenario: Stale address is dialed
- **WHEN** a dial attempt targets an address the peer no longer listens on
- **THEN** the attempt fails within the dial timeout, records backoff for that endpoint, and continues to the next eligible endpoint in the same attempt

#### Scenario: Unreachable peer does not read as an error
- **WHEN** the only failures for a peer are route-level and a retry is scheduled
- **THEN** the aggregate sync status is `Searching`, while the per-peer typed state still reports the failure category

#### Scenario: Rejected key still reads as an error
- **WHEN** a dial fails with a trust or TLS failure
- **THEN** the aggregate sync status is `Error`

#### Scenario: Foreground resume retries known peers
- **WHEN** networking becomes foreground-active and trusted peers still hold eligible endpoints
- **THEN** a connection attempt starts for each such peer without waiting for discovery to re-resolve it
