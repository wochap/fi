## Purpose

Define an explicit, authenticated, short-authentication-string pairing protocol with bilateral confirmation, replay resistance, and recoverable commit behavior.

## Requirements

### Requirement: Explicit pairing state machine
Pairing SHALL use a single typed state machine covering idle, discoverable, connecting, awaiting confirmation, committing, trusted, and failed states rather than independent boolean flags.

#### Scenario: Candidate selected
- **WHEN** the user selects a live pairing candidate
- **THEN** state leaves discoverable, enters connecting, and identifies the ephemeral candidate without granting trust

#### Scenario: Terminal cleanup
- **WHEN** pairing succeeds, is rejected, times out, or fails
- **THEN** its connection, secrets, timers, and candidate-specific transient state are closed or zeroized before returning to a stable terminal/idle state

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
The application SHALL durably journal non-secret pairing commit progress so interruption can be recovered or safely re-paired without treating partial state as bilateral success.

#### Scenario: Connection drops during commit
- **WHEN** one device persists trust or provisioning progress but final acknowledgement is lost
- **THEN** restart exposes a recoverable incomplete state and repeating the authenticated commit does not create conflicting trust/root records
