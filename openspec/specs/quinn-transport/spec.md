## Purpose

Define the bounded Quinn-based QUIC transport, stream framing, session replacement, and end-to-end repository synchronization behavior.

## Requirements

### Requirement: QUIC TLS transport
The application SHALL implement the custom Repo `NetworkTransport` using Quinn over QUIC with TLS 1.3 and ALPN `myapp-sync/1`.

#### Scenario: Protocol negotiation succeeds
- **WHEN** compatible authenticated peers connect
- **THEN** they negotiate the sync ALPN before any Repo session event is emitted

#### Scenario: ALPN is incompatible
- **WHEN** a peer offers no supported sync ALPN
- **THEN** the connection closes without entering Repo synchronization

### Requirement: Reliable bidirectional stream framing
Each authenticated peer session SHALL use one long-lived QUIC bidirectional stream for ordered complete Repo frames, preserve the Repo frame length prefix, enforce the Repo maximum before allocation, and MUST NOT use QUIC datagrams for Automerge synchronization.

#### Scenario: Multiple frames share a stream
- **WHEN** the remote peer writes consecutive or fragmented Repo frames
- **THEN** the adapter emits each exact complete frame once and in stream order

#### Scenario: Oversized frame prefix
- **WHEN** the stream advertises a frame above the Repo maximum
- **THEN** the adapter closes the peer as a protocol failure without allocating the advertised body

### Requirement: Bounded transport ownership
The Quinn adapter SHALL own endpoint, accept, connection, reader, and writer tasks with bounded queues and cancellation tied to application lifecycle.

#### Scenario: Outbound backpressure
- **WHEN** a peer stops reading while outbound capacity fills
- **THEN** `send` applies bounded backpressure or returns a peer-scoped error rather than growing memory without bound

#### Scenario: Application shutdown
- **WHEN** the Repo closes its transport
- **THEN** the adapter stops admission, closes peer connections, joins owned tasks, and emits no later stale network events

### Requirement: One active generation per peer
The transport SHALL expose at most one active session per DeviceId and SHALL suppress messages and disconnect events from any replaced session generation.

#### Scenario: Session replacement
- **WHEN** an authenticated peer reconnects while an older connection still exists
- **THEN** the deterministic winner becomes active, the old generation closes, and the Repo receives no stale old-generation message after replacement

### Requirement: Loopback repository synchronization
Two application-core instances connected only through Quinn SHALL synchronize their matching application roots and subsequent offline changes using the existing Repo protocol.

#### Scenario: Concurrent offline transactions
- **WHEN** two previously synchronized cores disconnect, each creates a transaction, and Quinn reconnects them
- **THEN** both Automerge roots converge and both SQLite projections eventually contain both transactions

### Requirement: Sync endpoint binds inside a fixed port range
When the application is opened with a fixed port policy, the sync QUIC endpoint SHALL bind the lowest free UDP port in the configured range, trying each port in ascending order, and SHALL NOT bind an ephemeral port. The default fixed range SHALL be UDP `47380` through `47389` inclusive. A bind failure caused by the port being in use SHALL be reported distinctly from every other bind failure, so the caller can continue to the next port for the former and fail for the latter. When the application is opened with the ephemeral policy (port 0), the endpoint SHALL bind an operating-system-chosen port as before.

#### Scenario: First port is free
- **WHEN** the application opens with the fixed range `47380..=47389` and no process holds UDP `47380`
- **THEN** the sync endpoint is bound to UDP `47380` and the reported local address carries that port

#### Scenario: Lower ports are busy
- **WHEN** UDP `47380` and `47381` are held by other sockets and `47382` is free
- **THEN** the sync endpoint is bound to UDP `47382` without reporting an error

#### Scenario: Bind fails for a reason other than a busy port
- **WHEN** binding a port in the range fails because the requested address is not assignable to this host
- **THEN** the open fails with that bind error and does not try the remaining ports

#### Scenario: Ephemeral policy is unchanged
- **WHEN** the application opens with port 0
- **THEN** the sync endpoint binds an operating-system-chosen port exactly as before this change

### Requirement: Bound ports are observable
The application SHALL expose the sync endpoint's bound UDP port, the pairing endpoint's bound UDP port, and the configured fixed range (or the fact that the ephemeral policy is in effect) to its embedder after a networked open, so a client can display which ports a firewall must allow.

#### Scenario: Embedder reads the ports
- **WHEN** a networked open has completed under the fixed range and the embedder queries the network ports
- **THEN** it receives the bound sync port, the bound pairing port, and the range bounds, and both bound ports lie inside the range

### Requirement: Inbound sync connections are refused while sync is paused
The sync transport SHALL expose an accepting flag. While accepting is off, every inbound connection SHALL be refused before TLS authentication and MUST NOT register a session or emit a peer event. Outbound dials requested explicitly by the core are not governed by this flag. Turning accepting back on SHALL accept later inbound connections without rebinding the endpoint.

#### Scenario: Refused before authentication
- **WHEN** accepting is off and a trusted peer opens a connection to the sync port
- **THEN** the connection is refused, no certificate is checked, and the peer observes a connection failure rather than a handshake

#### Scenario: Accepting resumes
- **WHEN** accepting is turned back on and the same peer connects again
- **THEN** the connection is authenticated and registered as usual on the same bound port
