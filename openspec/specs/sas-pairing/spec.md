## Purpose

Define an explicit, authenticated, short-authentication-string pairing protocol with bilateral confirmation, replay resistance, and recoverable commit behavior.

## Requirements

### Requirement: Explicit pairing state machine
Pairing SHALL use a single typed state machine covering idle, discoverable, connecting, awaiting confirmation, committing, trusted, and failed states rather than independent boolean flags. An inbound
connection that cannot be accepted SHALL be refused on its own connection and MUST NOT be treated as a
failure of the local pairing attempt; the discoverable window, the candidate list, and any in-flight
outbound attempt SHALL survive it. An outbound attempt refused by a busy peer SHALL return the local
device to discoverable rather than to failed, so the user can retry without restarting pairing.

The awaiting-confirmation state SHALL identify the peer by the DeviceId derived from the permanent
public key the peer presented in its authenticated hello, the same key that entered the SAS
transcript. The state MUST NOT carry the SAS-derivation inputs, and the DeviceId it carries MUST be
the one that the committing and trusted states later record.

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

#### Scenario: Awaiting confirmation identifies the peer
- **WHEN** the SAS becomes ready for a session
- **THEN** the awaiting-confirmation state carries the peer DeviceId derived from the authenticated hello key, and the DeviceId recorded on commit for that session is the same value

### Requirement: Pairing-specific authenticated channel
Pairing SHALL use QUIC TLS 1.3 with ALPN `fi-pair/1`, require both peers to present structurally valid identity-key certificates, verify handshake signatures and hello/certificate key equality, and MUST NOT register the connection with the Repo transport. Outside an active pairing window the device SHALL hold no pairing socket at all, so nothing answers on a pairing port.

#### Scenario: Pairing mode is inactive
- **WHEN** an unknown peer attempts the pairing ALPN while no pairing window is open
- **THEN** no pairing socket is bound on the device, no handshake takes place, and no pairing message is processed

#### Scenario: Hello key mismatches certificate
- **WHEN** an inbound pairing hello carries a public key different from the TLS certificate key
- **THEN** that connection is refused without displaying a SAS or creating trust, and the responder's pairing window stays open

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

### Requirement: Expiry outcome is consistent with the terminal state
When a pairing session reaches its deadline, the outcome reported to the caller of the in-flight pairing operation SHALL be expiry, and the published pairing state SHALL be failed with expiry. The transport close that the local or remote deadline itself causes MUST NOT be reported as a transport failure. A transport failure that occurs before the deadline SHALL still be reported as a transport failure.

#### Scenario: Stalled session reaches its deadline
- **WHEN** the local device has confirmed and the peer never answers before the session deadline
- **THEN** the confirm call fails with expiry, and the pairing state is failed with expiry, regardless of whether the local deadline, the peer's deadline, or the stream timeout ends the wait first

#### Scenario: Peer closes at its own deadline
- **WHEN** the peer's pairing window expires and it closes the connection at or after the local session deadline
- **THEN** the local in-flight operation fails with expiry, not with a transport failure

#### Scenario: Connection drops before the deadline
- **WHEN** the connection is lost while the session deadline is still in the future
- **THEN** the in-flight operation fails with a transport failure, the pairing state is failed with that transport failure, and no trust is created

### Requirement: Pairing endpoint binds inside the sync port range
The pairing-specific QUIC endpoint SHALL keep a socket separate from the sync endpoint and SHALL bind it only when a pairing window opens. Under the fixed port policy it SHALL bind the lowest free UDP port in the configured range other than the device's own sync port, trying ports in ascending order, and SHALL NOT bind an ephemeral port. When no port in the range is free, starting pairing SHALL fail with a typed ports-exhausted error naming the range; the sync endpoint and the rest of networking SHALL keep running. Pairing advertisements and pairing provisioning SHALL carry the actually bound ports (the pairing port in the advertisement, the sync port in provisioning), so peers learn the real ports whatever the range yields. Under the ephemeral policy the pairing endpoint SHALL bind an operating-system-chosen port when the window opens.

#### Scenario: Pairing takes the next port
- **WHEN** the sync endpoint is bound to UDP `47380`, `47381` is free, and the user starts pairing
- **THEN** the pairing endpoint is bound to UDP `47381` and the pairing advertisement carries port `47381`

#### Scenario: Two instances on one host
- **WHEN** a second application instance opens on the same host while the first holds sync on `47380` and has no pairing window open
- **THEN** the second instance binds sync to `47381`, and when both start pairing each binds a different free port in the range and they can pair with each other

#### Scenario: Sync port took the last free port
- **WHEN** the sync endpoint took the only free port in the range and the user starts pairing
- **THEN** starting pairing fails with the ports-exhausted error, no advertisement is published, no ephemeral port is bound, and sync networking keeps running

### Requirement: The pairing socket exists only for the pairing window
The pairing socket SHALL be released when pairing reaches any terminal or idle state: trusted, failed, stopped, rejected, or expired. After release the port SHALL be free for other sockets, and a later pairing window SHALL bind again under the port rules.

#### Scenario: Window expires
- **WHEN** a pairing window reaches its deadline with no session
- **THEN** the pairing socket is closed and the port it held can be bound by another socket

#### Scenario: Pairing completes
- **WHEN** a pairing session commits and the device reaches the trusted state
- **THEN** the pairing socket is closed after the pairing connection closes, and the embedder reports no pairing port

#### Scenario: Pairing is started again
- **WHEN** the user starts a new pairing window after an earlier one ended
- **THEN** a pairing socket is bound again inside the range and advertised with its actual port

### Requirement: Inbound pairing connections from non-LAN addresses are dropped before the handshake
The pairing endpoint SHALL apply the same source-address admission as the sync endpoint: an inbound connection whose source is not a LAN-routable peer address under the device's address policy SHALL be dropped before the TLS handshake, without any reply and without presenting the certificate, and SHALL NOT affect the pairing state, the window, or the candidate list.

#### Scenario: Public source during a window
- **WHEN** a pairing window is open and a connection to the pairing port arrives from a public address
- **THEN** it is dropped without a reply and the device stays discoverable

### Requirement: A failed inbound pairing handshake refuses only that connection
An inbound pairing connection whose handshake fails before a SAS is displayed SHALL be closed on its own and MUST NOT fail the local pairing attempt. This covers a TLS handshake failure, a missing structurally valid certificate, a missing, malformed, or unsupported-version hello, a hello key that does not match the certificate, and incompatible root declarations. The discoverable window, its deadline, the candidate list, and any in-flight outbound attempt SHALL survive, the local device SHALL be discoverable again if the inbound had moved it out of discoverable, and later inbound connections in the same window SHALL still be processed. An inbound peer that has not delivered its hello within 10 seconds of connecting SHALL be treated as a failed handshake, so a stalled connection cannot hold the accept path for the rest of the window. Failures after the SAS is displayed are unchanged and fail the session.

#### Scenario: Garbage inbound then a valid peer
- **WHEN** a pairing window is open, an inbound connection sends a malformed hello, and afterwards a legitimate peer dials in within the same window
- **THEN** the first connection is closed, the device stays discoverable with its deadline unchanged, and the legitimate peer reaches the SAS

#### Scenario: Stalled inbound
- **WHEN** an inbound pairing connection completes TLS but sends no hello for 10 seconds
- **THEN** that connection is closed, the device stays discoverable, and a later inbound connection is processed

#### Scenario: TLS failure on inbound
- **WHEN** an inbound connection to the pairing port fails the TLS handshake
- **THEN** the failure is logged, the accept path keeps listening, and the device stays discoverable
