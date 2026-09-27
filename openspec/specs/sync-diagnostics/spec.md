## Purpose

Gives the user and support tooling a way to see why a paired device is not syncing, to force a connection attempt, and to copy a self-contained, secret-free diagnostic block for a peer without access to stdout or logcat.

## Requirements

### Requirement: Recent structured log events are retained in memory
The application SHALL retain the most recent structured tracing events emitted by the Rust core in a bounded in-memory buffer of at least 1000 events, oldest evicted first, from the moment tracing is initialized. Each retained event SHALL carry its timestamp, level, event name, message, and structured fields, including the `device_id` field when the emitting subsystem set it. Retention MUST NOT change what is written to the existing stdout or logcat destination, and the buffer SHALL survive a dataset reset and a networking retry, since those are the moments a user most needs the preceding lines.

#### Scenario: Buffer is bounded
- **WHEN** more events than the capacity have been emitted since startup
- **THEN** a query returns only the most recent events up to the capacity, in emission order, and memory use stays bounded

#### Scenario: Retention is invisible to existing sinks
- **WHEN** a peer dial fails and the event is written to stdout or logcat as before
- **THEN** the same event is also available from the retained buffer with identical field values

### Requirement: Retained events are queryable per device
The application SHALL expose the retained events filtered by DeviceId: a query for a peer returns the events whose `device_id` field equals that peer, and a query for the local device returns the events that carry no `device_id` field. Both queries SHALL return events in emission order with a bounded maximum count, and a query for a DeviceId with no retained events SHALL return an empty list rather than fail.

#### Scenario: Peer log lines
- **WHEN** dials to peer A failed twice and peer B transitioned to synced
- **THEN** the query for A returns the two dial failures and the state transitions for A, and none of B's events

#### Scenario: Local device log lines
- **WHEN** discovery reported no routable address and the bootstrap recovered
- **THEN** the query for the local device returns those events and no per-peer event

### Requirement: Local device identity is exposed
The application SHALL expose the local device's DeviceId and the friendly name it presents to peers during pairing. When networking is not initialized and no identity exists yet, the query SHALL report that no identity is available rather than fail.

#### Scenario: Identity is available
- **WHEN** the application runs in networked mode
- **THEN** the query returns the same DeviceId a paired peer records for this device, and the same pairing name a peer sees in the pairing hello

#### Scenario: Identity is not yet available
- **WHEN** the application runs in local-only mode with no device key
- **THEN** the query reports no identity and the UI shows that networking is not set up instead of a blank identifier

### Requirement: Per-peer connection detail is not flattened
For every trusted device, the application SHALL expose, alongside the connection state, the endpoint currently being tried or last tried, the time of the last connection attempt, and, when the last attempt failed, a failure reason text derived from the typed failure category and its message. The exposed state SHALL distinguish an attempt in progress from a failed attempt and from a never-attempted peer.

#### Scenario: Attempt in progress
- **WHEN** the connection manager is dialing or authenticating with a peer at `192.168.1.20:47380`
- **THEN** the device's exposed detail names that endpoint and marks the attempt as in progress

#### Scenario: Attempt failed
- **WHEN** every endpoint for a peer failed and the last failure was a TLS failure
- **THEN** the device's exposed detail carries the TLS failure category and message, the last tried endpoint, and the attempt time

#### Scenario: No route
- **WHEN** a peer has no known endpoint
- **THEN** the exposed failure states that no eligible endpoint is known, rather than a generic error

### Requirement: Manual reconnect
The application SHALL provide a command that dials a trusted, non-revoked peer immediately, ignoring the automatic scheduler's backoff and initiator preference, and reports success or the typed failure. The command SHALL be refused for a revoked or unknown device, SHALL NOT start a second attempt while one is already in flight for that peer, and MUST NOT replace a live session that is already connected, syncing, or synced.

#### Scenario: Reconnect a backed-off peer
- **WHEN** a peer is in the failed state with a pending backoff and the user requests a reconnect
- **THEN** a dial starts at once, the state advances through connecting and authenticating, and the outcome is reported without waiting for the backoff to expire

#### Scenario: Reconnect a synced peer
- **WHEN** the peer is already synced and a reconnect is requested
- **THEN** the live session is kept and the command returns without marking the peer failed

#### Scenario: Reconnect a revoked device
- **WHEN** a reconnect is requested for a revoked device
- **THEN** the command is refused with a typed error and no dial starts

### Requirement: Diagnostic block for one peer
The application SHALL produce a plain-text diagnostic block for a trusted device containing, in order: the application version and build identifier (or "unknown" when not available), the local DeviceId, the peer DeviceId and friendly name, the peer connection state, the endpoint tried and last attempt time, the failure reason if any, the locally bound sync port, and the retained log events for that peer followed by the retained local-device events. The block MUST NOT contain private keys, discovery secrets, SAS values, handshake or exporter material, or any record contents, and SHALL be identical in content whether copied from the devices screen or produced for a test.

#### Scenario: Copy all
- **WHEN** the user triggers "Copy all" in a device's details
- **THEN** the clipboard holds one text block with every listed section, and the peer's log lines appear before the local device's lines

#### Scenario: Diagnostic block is secret-free
- **WHEN** the block is produced after a pairing that derived a SAS and after key operations with sentinel values
- **THEN** the text contains none of the sentinel values and no SAS representation
