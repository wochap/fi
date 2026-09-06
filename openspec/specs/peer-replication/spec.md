## Purpose

TBD: Define Stage 1 inventory exchange, synchronization state, announcements, convergence, and delivery behavior between peers.

## Requirements

### Requirement: Whole-collection inventory exchange
Compatible ready peers SHALL exchange complete document inventories and initiate Automerge synchronization for the union of their IDs.

#### Scenario: One-way inventory difference
- **WHEN** two compatible ready peers connect and only one has a particular document
- **THEN** both create the required synchronization relationship and the missing peer learns the document

#### Scenario: Repeated inventory
- **WHEN** a peer receives the same inventory repeatedly
- **THEN** actor creation and synchronization remain idempotent

#### Scenario: Multiple documents in both directions
- **WHEN** compatible peers begin with different documents
- **THEN** every document in the inventory union synchronizes to both repositories

### Requirement: Per-peer per-document sync state
Each document actor SHALL keep an independent fresh `automerge::sync::State` for every currently connected compatible peer.

#### Scenario: New connection
- **WHEN** a compatible peer connects
- **THEN** every eligible local document receives a fresh sync state for that peer and begins event-driven synchronization

#### Scenario: Peer disconnects
- **WHEN** a disconnect event or send failure occurs
- **THEN** every document removes the disconnected peer and its sync state

#### Scenario: Peer reconnects
- **WHEN** the same authenticated peer reconnects, including without a preceding usable sync acknowledgement
- **THEN** all relationships use new sync states and can converge without retaining stale in-flight state

### Requirement: Event-driven sync pumping
The system SHALL generate sync messages only in response to connection, inventory/announcement, local head change, or inbound sync events.

#### Scenario: Inbound acknowledgement required
- **WHEN** a valid inbound sync message does not change document heads
- **THEN** the recipient still immediately calls `generate_sync_message()` for the sender and sends the result when present

#### Scenario: Local head change
- **WHEN** a local transaction changes heads
- **THEN** the document actor pumps every connected compatible peer

#### Scenario: Relayed remote head change
- **WHEN** a remote update received from peer A changes heads while peer C is connected
- **THEN** the document actor responds to A and also pumps C

#### Scenario: Generator returns none
- **WHEN** Automerge reports no sync message because the relationship is converged or awaiting acknowledgement
- **THEN** the repository schedules no polling timer or busy loop

### Requirement: Announcements propagate new documents
A document that becomes locally shareable after a connection is established SHALL be announced idempotently to every compatible ready peer.

#### Scenario: Create after connection
- **WHEN** a ready repository durably completes Stage 1 creation of a document while compatible ready peers are connected
- **THEN** it announces the ID and initiates synchronization with those peers

#### Scenario: Unknown announcement
- **WHEN** a compatible ready peer announces an unknown document
- **THEN** the receiver creates one loading placeholder and starts synchronization for it

#### Scenario: Duplicate announcement
- **WHEN** the same document is announced repeatedly
- **THEN** the receiver retains one actor and one sync relationship per connected peer

### Requirement: Multi-peer convergence
Repositories SHALL converge Automerge heads and hydrated values after concurrent offline mutations and later reliable reconnection.

#### Scenario: Concurrent offline changes
- **WHEN** two repositories mutate the same synchronized document while disconnected and subsequently reconnect
- **THEN** both eventually have identical head sets and equivalent hydrated values

#### Scenario: Three-peer fan-out
- **WHEN** A sends a change to B and B is connected to C
- **THEN** B relays synchronization progress so all three eventually converge without A requiring a direct connection to C

#### Scenario: Repeated interrupted reconnections
- **WHEN** connections are repeatedly interrupted with sync messages in flight and later restored
- **THEN** fresh state exchanges eventually converge without sync-state deadlock

### Requirement: Ordered bounded delivery
The repository and transport SHALL preserve frame order per authenticated connection and SHALL apply bounded backpressure.

#### Scenario: Concurrent documents send to one peer
- **WHEN** multiple document actors produce frames for the same peer concurrently
- **THEN** the outbound peer path serializes complete frames in a deterministic connection order

#### Scenario: Outbound send fails
- **WHEN** transport send returns an error
- **THEN** the repository reports the error, treats the peer as disconnected, and clears its document sync states
