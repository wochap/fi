## Purpose

Define an explicit, authenticated, short-authentication-string pairing protocol with bilateral confirmation, replay resistance, and recoverable commit behavior.

## Requirements

### Requirement: Explicit pairing state machine
Pairing SHALL use a single typed state machine covering idle, discoverable, connecting, awaiting confirmation, committing, trusted, and failed states rather than independent boolean flags. An inbound
connection that cannot be accepted SHALL be refused on its own connection and MUST NOT be treated as a
failure of the local pairing attempt; the discoverable window, the candidate list, and any in-flight
outbound attempt SHALL survive it. An outbound attempt refused by a busy peer SHALL return the local
device to discoverable rather than to failed, so the user can retry without restarting pairing.

#### Scenario: Candidate selected
- **WHEN** the user selects a live pairing candidate
- **THEN** state leaves discoverable, enters connecting, and identifies the ephemeral candidate without granting trust

#### Scenario: Terminal cleanup
- **WHEN** pairing succeeds, is rejected, times out, or fails
- **THEN** its connection, secrets, timers, and candidate-specific transient state are closed or zeroized before returning to a stable terminal/idle state

#### Scenario: Inbound arrives while connecting
- **WHEN** an inbound pairing connection arrives while the local device is already connecting outbound
- **THEN** the inbound connection is refused with a busy reason on its own connection, the local
  outbound attempt continues, and the local discoverable window remains open

#### Scenario: Outbound refused by a busy peer
- **WHEN** the peer closes an outbound pairing connection with the busy reason
- **THEN** the local device returns to discoverable with its window and candidate list intact, and
  the attempt is reported as retryable rather than as a pairing failure

#### Scenario: Both devices dial simultaneously
- **WHEN** two devices in pairing mode each select the other as a candidate at the same time
- **THEN** each refuses the other's inbound, neither is left in a failed state, both windows remain
  open, and a single retry from either device establishes one session

#### Scenario: Inbound arrives during commitment
- **WHEN** an inbound pairing connection arrives while the local device is awaiting confirmation or
  committing
- **THEN** it is refused without disturbing the in-progress commitment and without failing the session

### Requirement: Pairing-specific authenticated channel
Pairing SHALL use QUIC TLS 1.3 with ALPN `fi-pair/1`, require both peers to present structurally valid identity-key certificates, verify handshake signatures and hello/certificate key equality, and MUST NOT register the connection with the Repo transport.

#### Scenario: Pairing mode is inactive
- **WHEN** an unknown peer attempts the pairing ALPN outside an active pairing window
- **THEN** the connection is rejected before pairing messages are processed

#### Scenario: Hello key mismatches certificate
- **WHEN** a pairing hello carries a public key different from the TLS certificate key
- **THEN** the pairing fails without displaying a SAS or creating trust

### Requirement: Transcript-bound six-digit SAS
Both peers SHALL derive an identical six-digit SAS and separate confirmation keys from a canonical transcript containing protocol identifiers, roles, permanent public keys, pairing instance IDs, fresh nonces, root-state declarations, and pairing-specific TLS exporter material; the SAS MUST NOT be transmitted.

#### Scenario: Honest pairing transcript
- **WHEN** both devices complete the same live handshake
- **THEN** they display the same zero-padded six-digit SAS

#### Scenario: Identity or channel is substituted
- **WHEN** a permanent key, instance ID, nonce, role, protocol field, or TLS channel differs
- **THEN** the derived transcript hash and SAS differ except for the bounded probability of a six-digit collision

### Requirement: Bilateral explicit confirmation
Neither device SHALL establish trust or release provisioning material until it has both a local explicit confirmation and a valid MACed confirmation from the peer for the current transcript.

#### Scenario: Both users confirm
- **WHEN** both users approve matching SAS values and both confirmations verify
- **THEN** the pairing can enter committing and exchange provisioning data

#### Scenario: One user rejects
- **WHEN** either user rejects before commit
- **THEN** both sides terminate the attempt and no trusted-device record or discovery secret is created from it

### Requirement: Pairing timeout and replay resistance
Pairing sessions, instance IDs, nonces, confirmations, and provisioning messages SHALL be bound to one expiring transcript and MUST NOT be accepted in a different or expired attempt.

#### Scenario: Confirmation arrives after timeout
- **WHEN** a valid old confirmation is delivered after its pairing window expires
- **THEN** it is rejected and creates no trust

#### Scenario: Confirmation is replayed in a new attempt
- **WHEN** an earlier confirmation MAC is replayed with fresh nonces or instance IDs
- **THEN** verification fails for the new transcript

### Requirement: Idempotent pairing commit journal
The application SHALL durably journal non-secret pairing commit progress so interruption can be recovered or safely re-paired without treating partial state as bilateral success. A device that stored trust for a session whose commit later failed SHALL record the session as incomplete, and a subsequent authenticated connection with that peer SHALL resume the unfinished commit instead of leaving the two devices with opposite outcomes.

#### Scenario: Connection drops during commit
- **WHEN** one device persists trust or provisioning progress but final acknowledgement is lost
- **THEN** restart exposes a recoverable incomplete state and repeating the authenticated commit does not create conflicting trust/root records

#### Scenario: One side commits while the other fails
- **WHEN** the peer completes its commit and reports success while the local commit fails before acknowledgement
- **THEN** the local journal records the session as incomplete with its failure reason, and the next authenticated connection with that peer resumes the commit rather than requiring a fresh pairing window

### Requirement: The pairing window accepts more than one inbound connection
The accept path SHALL remain active for the lifetime of the discoverable window rather than consuming
it on the first inbound connection, so that a refused inbound does not end the window and a later
inbound within the same window can still be accepted.

#### Scenario: Refused inbound is followed by a valid one
- **WHEN** an inbound connection is refused and a second inbound connection arrives within the same
  discoverable window while the device is discoverable
- **THEN** the second connection is processed normally

#### Scenario: Window expires
- **WHEN** the discoverable window deadline passes
- **THEN** the accept path stops and no further inbound connection is processed

### Requirement: The advertised root state is current at handshake time
The root state carried in a pairing handshake SHALL be read at the moment the handshake occurs and
SHALL NOT be captured when the pairing window is opened. Every path that commits a bootstrap transition
SHALL update the value a subsequent handshake reads.

#### Scenario: Root is created after the window opens
- **WHEN** a device opens a pairing window in the needs-decision state and then creates a local root
  before a handshake occurs
- **THEN** the handshake advertises the ready state holding the created root, and a peer does not elect
  itself provisioner against a superseded needs-decision advertisement

#### Scenario: Root is received after the window opens
- **WHEN** a device opens a pairing window and completes a join through another path before a further
  handshake occurs
- **THEN** the subsequent handshake advertises the joined root rather than the needs-decision state

#### Scenario: Joining is treated as rooted
- **WHEN** a handshake occurs while the device is joining a received root
- **THEN** the advertised root state is ready with that root, so a third device cannot provision it
  mid-join

### Requirement: A commit-stage failure fails the session immediately
Any error raised while committing a pairing session SHALL drive the pairing state machine to the failed state, carrying the originating reason, before the error is returned to the caller. The committing state MUST NOT be left to lapse into the deadline timeout, and a failure whose cause is not the deadline MUST NOT be reported as an expiry.

#### Scenario: Secure store is locked during commit
- **WHEN** storing or reading the discovery-group secret fails because the secure store is locked
- **THEN** the session transitions to failed with the locked-store reason, its transient session state is released, and the caller receives that reason

#### Scenario: Expiry is not used as a catch-all
- **WHEN** a commit-stage failure other than the deadline occurs
- **THEN** the reported failure reason is the originating one and is never the expiry reason

#### Scenario: Deadline still expires a stalled session
- **WHEN** no commit-stage error occurs and the deadline passes
- **THEN** the session fails with the expiry reason as before

### Requirement: Already-trusted peers are distinguishable during pairing
The pairing manager SHALL expose whether a connected peer is already a trusted, non-revoked device, and SHALL expose the endpoints of trusted devices so a candidate list can suppress candidates that resolve to them. A handshake with an already-trusted peer SHALL reach a success outcome that identifies the peer as already paired and MUST NOT create a duplicate trust record.

#### Scenario: Candidate belongs to a trusted device
- **WHEN** a pairing candidate's address matches a known endpoint of a trusted, non-revoked device
- **THEN** the candidate is reported as already paired so it can be suppressed from the selectable list

#### Scenario: Handshake with an already-trusted peer
- **WHEN** pairing is confirmed with a peer that is already trusted and shares the same root
- **THEN** the session completes as already paired, the existing trust record is updated rather than duplicated, and no second provisioning is performed
