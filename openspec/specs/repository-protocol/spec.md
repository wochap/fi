## Purpose

TBD: Define Stage 1 repository protocol identifiers, framing, validation, message kinds, peer-scoped errors, and compatibility.

## Requirements

### Requirement: Strong identifier encoding
Document IDs SHALL parse and display canonically and SHALL occupy exactly 16 bytes in protocol payloads; peer identity SHALL never be parsed from repository frames.

#### Scenario: UUID round trip
- **WHEN** a canonical or accepted UUID string is parsed and displayed
- **THEN** it produces the same lowercase hyphenated document ID and the same 16 wire bytes

#### Scenario: Authenticated peer attribution
- **WHEN** a message frame is delivered by the transport
- **THEN** the repository attributes it only to the `PeerId` on the authenticated transport event

### Requirement: Versioned length-delimited frames
Each transport payload SHALL contain one frame with a big-endian `u32` body length followed by `FIRP`, protocol version 1, a known message kind, zero reserved flags, and the kind payload.

#### Scenario: Frame round trip
- **WHEN** any supported protocol message is encoded and decoded
- **THEN** its semantic value is preserved exactly

#### Scenario: Incremental input
- **WHEN** the decoder receives only part of a frame
- **THEN** it requests more input without consuming the incomplete frame

#### Scenario: Multiple buffered frames
- **WHEN** multiple complete frames are present in one input buffer
- **THEN** the decoder returns them in order and leaves no bytes unaccounted for

### Requirement: Frame limits and exact payload validation
The codec SHALL reject bodies larger than 8 MiB, inconsistent lengths, invalid counts, trailing kind-specific bytes, and arithmetic overflow before allocating from untrusted length fields.

#### Scenario: Oversized advertised body
- **WHEN** a frame advertises a body length above 8 MiB
- **THEN** decoding fails with `FrameTooLarge` without allocating that body

#### Scenario: Truncated frame
- **WHEN** a complete transport payload declares more bytes than it contains
- **THEN** the payload is rejected as an invalid length

#### Scenario: Invalid inventory count
- **WHEN** an inventory count does not exactly match the remaining sequence of 16-byte IDs
- **THEN** the frame is rejected without partially applying the inventory

### Requirement: Protocol message kinds
Protocol version 1 SHALL encode Hello, BootstrapState, Inventory, Announce, and Sync messages with their specified bootstrap modes and document ID fields.

#### Scenario: Hello first
- **WHEN** the first decoded frame on a connection is not Hello
- **THEN** the repository reports a protocol error and closes that peer

#### Scenario: Duplicate Hello
- **WHEN** a peer sends another Hello after its initial valid Hello
- **THEN** the repository reports a protocol error and closes that peer

#### Scenario: Bootstrap payload
- **WHEN** Hello or BootstrapState carries uninitialized, joining, or ready mode
- **THEN** it contains respectively no root, the selected root, or the ready root using the exact mode encoding

#### Scenario: Opaque sync payload
- **WHEN** a Sync frame is decoded
- **THEN** its first 16 payload bytes select the document and its remaining bytes are passed to Automerge sync-message decoding without repository-level reinterpretation

### Requirement: Protocol violations are peer-scoped
Unknown versions, unknown kinds, nonzero reserved flags, malformed bootstrap payloads, invalid Automerge sync messages, and invalid message ordering SHALL close the offending peer and emit a structured protocol error without terminating unrelated document actors or peers.

#### Scenario: Unknown version
- **WHEN** a peer sends a frame with an unsupported repository protocol version
- **THEN** only that peer is closed with an unsupported-version error

#### Scenario: Nonzero reserved flags
- **WHEN** a frame contains nonzero reserved flags
- **THEN** only that peer is closed with a reserved-flags protocol error

#### Scenario: Invalid Automerge message
- **WHEN** Automerge rejects the opaque payload of a Sync frame
- **THEN** the document is not reported as changed and the offending peer is closed

### Requirement: Protocol compatibility is explicit
Protocol version 1 SHALL be tested with golden frames and SHALL be treated as coupled to the pinned Automerge sync implementation.

#### Scenario: Stable fixture
- **WHEN** protocol version 1 fixtures are decoded and re-encoded
- **THEN** their exact bytes and semantic messages remain stable

#### Scenario: Future Automerge upgrade
- **WHEN** an implementation changes the pinned Automerge version
- **THEN** it must verify opaque sync compatibility or introduce a new repository protocol version
