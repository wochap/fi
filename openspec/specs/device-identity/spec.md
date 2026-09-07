## Purpose

Define permanent device identity derivation, secure private-key storage, and secret-safe identity failure behavior.

## Requirements

### Requirement: Permanent cryptographic installation identity
On first identity initialization the application SHALL generate one Ed25519 private key through `SecureKeyStore`, derive its public key, and derive a stable `DeviceId` as a versioned SHA-256 fingerprint of that public key.

#### Scenario: First identity initialization
- **WHEN** secure storage contains no device key
- **THEN** the application generates and stores one key and returns its derived public key and DeviceId

#### Scenario: Identity restart
- **WHEN** the application reopens with the stored private key
- **THEN** it derives exactly the same public key and DeviceId

### Requirement: Network addresses are not identity
The application SHALL identify peers and trust records by `DeviceId` and permanent public key; IP addresses and ports SHALL be treated only as expiring connection endpoints.

#### Scenario: Trusted peer address changes
- **WHEN** a trusted peer reconnects from a different IP address or port with the pinned permanent key
- **THEN** it retains the same DeviceId and can replace its previous session

### Requirement: Secret-safe key handling
Private device keys SHALL remain outside `control.sqlite` and `read-model.sqlite`, SHALL be exposed only through secret-bearing Rust types, and MUST NOT appear in formatted errors or tracing fields.

#### Scenario: Identity error is formatted
- **WHEN** secure key loading or signing fails
- **THEN** the reported error identifies the operation without including private key bytes

### Requirement: Secure-store availability is explicit
Production secure-store adapters SHALL return typed locked or unavailable failures and MUST NOT silently fall back to plaintext key files.

#### Scenario: Linux secret service unavailable
- **WHEN** no usable Secret Service exists in the desktop session
- **THEN** identity-dependent networking remains disabled with an actionable error and no plaintext private key is created
