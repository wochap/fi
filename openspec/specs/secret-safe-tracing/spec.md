## Purpose

TBD: Define structured operational tracing, sensitive-value redaction, secret-safe Rust types, and automated leakage coverage.

## Requirements

### Requirement: Structured operational tracing
Rust subsystems SHALL emit structured tracing for application lifecycle, commands, projection, connection, discovery, pairing state, synchronization, and errors using stable event names and safe public fields.

#### Scenario: Synchronization completes
- **WHEN** a peer reaches synchronized state
- **THEN** tracing records public DeviceId, state transition, timing, and document-count context without synchronized finance contents

### Requirement: Sensitive values are never logged
Tracing and formatted errors MUST NOT include permanent private keys, raw discovery secrets, SAS values, TLS exporter or handshake secret material, transcript-derived confirmation/provisioning keys, or plaintext protected provisioning payloads.

#### Scenario: Pairing fails after SAS derivation
- **WHEN** a later pairing step reports an error
- **THEN** logs contain the public attempt/state/error category but not the SAS or any derivation input classified as secret

#### Scenario: Secure storage fails
- **WHEN** key wrapping, unwrapping, or secret persistence fails
- **THEN** logs identify the adapter and operation without secret bytes, ciphertext dumps, or key aliases containing secret data

### Requirement: Secret-safe types
Secret-bearing Rust values SHALL use wrappers that redact or omit `Debug`/display output, minimize cloning, and zeroize owned plaintext buffers where practical.

#### Scenario: Secret wrapper is debug-formatted
- **WHEN** a containing state or error is formatted for tracing
- **THEN** the secret field is redacted and its length/value cannot be recovered from the output

### Requirement: Logging leakage tests
Automated tests SHALL run representative identity, pairing, discovery, provisioning, and failure paths with sentinel secret values and assert captured formatted events do not contain those sentinels or SAS representations.

#### Scenario: Sentinel scan
- **WHEN** the secret-safety test captures all configured trace levels for representative operations
- **THEN** no forbidden sentinel material appears in any event or error string
