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
