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
A document that becomes locally shareable after a connection is established SHALL be announced idempotently to every compatible ready peer only after its required durable snapshot and bootstrap transitions succeed.

#### Scenario: Create after connection
- **WHEN** a ready repository durably completes creation of a document while compatible ready peers are connected
- **THEN** it announces the ID and initiates synchronization with those peers

#### Scenario: Creation not yet durable
- **WHEN** a new document's store or durability barrier remains pending or fails
- **THEN** no inventory, announcement, or sync frame exposes that document ID

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
The repository and transport SHALL preserve frame order per authenticated connection and SHALL apply bounded backpressure through one internal writer queue and task per active peer session.

#### Scenario: Concurrent documents send to one peer
- **WHEN** multiple document actors produce frames for the same peer concurrently
- **THEN** the peer writer serializes complete frames in deterministic connection order

#### Scenario: Blocked transport send
- **WHEN** one peer's transport send remains pending
- **THEN** the coordinator and unrelated peer writers can continue until that peer's bounded outbound policy is reached

#### Scenario: Outbound queue unavailable
- **WHEN** a peer writer queue is closed or reaches its configured failure policy
- **THEN** the repository reports a peer-scoped error and detaches that session rather than creating an unbounded queue

#### Scenario: Outbound send fails
- **WHEN** transport send returns an error
- **THEN** the repository reports the error, treats the peer as disconnected, and clears its document sync states

#### Scenario: Reconnection writer state
- **WHEN** the same peer reconnects
- **THEN** the repository creates a fresh writer task and fresh per-document Automerge sync states for the new session

### Requirement: End-to-end two-repository acceptance
Two independent repository instances connected only through the repository protocol and an ordered reliable in-memory transport SHALL synchronize their eligible Automerge documents in both directions and after session replacement.

#### Scenario: Forward online synchronization
- **WHEN** Repo A creates a document containing a value while connected to compatible Repo B
- **THEN** Repo B learns the document ID and reaches identical heads and hydrated values

#### Scenario: Reverse online synchronization
- **WHEN** Repo B changes a synchronized document while connected to Repo A
- **THEN** Repo A reaches identical heads and observes Repo B's value

#### Scenario: Three-document initial inventory
- **WHEN** ready Repo A owns three non-root documents before connecting to compatible ready Repo B
- **THEN** Repo B learns and converges all three documents through inventory exchange without application-level document registration

#### Scenario: Fourth document announced live
- **WHEN** Repo A durably creates a fourth non-root document while Repo B remains connected
- **THEN** Repo B learns and converges that document without reconnecting

#### Scenario: Peer repository restart
- **WHEN** Repo B shuts down after synchronizing, a new Repo B instance opens its retained snapshots, and the peers reconnect using fresh transport-session and Automerge sync state
- **THEN** both repositories converge any changes made before or during the restart without persisted per-peer sync state

#### Scenario: Duplicate delivery and repeated connection
- **WHEN** repository inventory or announcement processing is repeated and the same peer identity reconnects in a new session
- **THEN** each repository retains one document actor per ID and synchronization converges without corruption or deadlock

#### Scenario: Concurrent offline acceptance
- **WHEN** synchronized repositories disconnect, each adds a distinct value to the same document, and then reconnect
- **THEN** both repositories reach identical heads and hydrated values containing both additions

### Requirement: Observable per-peer synchronization progress
The repository SHALL expose retained typed synchronization progress for each authenticated eligible peer, aggregated across its active per-document Automerge sync relationships without persisting connection sync state.

#### Scenario: Eligible peer begins synchronization
- **WHEN** a compatible authenticated peer is attached to one or more documents
- **THEN** observers see that peer as syncing until every active relationship has exchanged current heads and has no unacknowledged outbound work

#### Scenario: All document relationships converge
- **WHEN** every eligible document relationship with a connected peer reaches matching known heads and no in-flight work
- **THEN** observers see that peer as synced

#### Scenario: Heads change after convergence
- **WHEN** a local or remote commit changes an attached document after the peer was synced
- **THEN** that peer returns to syncing until the new heads converge

#### Scenario: Peer disconnects
- **WHEN** the active peer session disconnects or is replaced
- **THEN** its old per-session synchronization progress is removed and a reconnect starts with fresh sync state
