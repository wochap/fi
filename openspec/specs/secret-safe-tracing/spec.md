## Purpose

TBD: Define structured operational tracing, sensitive-value redaction, secret-safe Rust types, and automated leakage coverage.

## Requirements

### Requirement: Structured operational tracing
Rust subsystems SHALL emit structured tracing for application lifecycle, commands, projection, connection, discovery, pairing state, synchronization, and errors using stable event names and safe public fields.

#### Scenario: Synchronization completes
- **WHEN** a peer reaches synchronized state
- **THEN** tracing records public DeviceId, state transition, timing, and document-count context without synchronized finance contents

### Requirement: Sensitive values are never logged
Tracing and formatted errors MUST NOT include permanent private keys, raw discovery secrets, SAS values, TLS exporter or handshake secret material, transcript-derived confirmation/provisioning keys, or plaintext protected provisioning payloads. The same prohibition applies to every form in which a tracing event is retained or re-exposed: the in-memory recent-event buffer, the per-device log query results returned to the UI, and the plain-text diagnostic block the user can copy. Retention MUST NOT capture fields at a level or in a form that the redacting `Debug`/display wrappers would not have produced for the stdout or logcat sink.

#### Scenario: Pairing fails after SAS derivation
- **WHEN** a later pairing step reports an error
- **THEN** logs contain the public attempt/state/error category but not the SAS or any derivation input classified as secret

#### Scenario: Secure storage fails
- **WHEN** key wrapping, unwrapping, or secret persistence fails
- **THEN** logs identify the adapter and operation without secret bytes, ciphertext dumps, or key aliases containing secret data

#### Scenario: Retained events stay redacted
- **WHEN** a secret-bearing value is formatted into an event that is both written to the sink and retained
- **THEN** the retained event's fields hold the same redacted text as the sink output, and the value cannot be recovered from the buffer or the diagnostic block

### Requirement: Secret-safe types
Secret-bearing Rust values SHALL use wrappers that redact or omit `Debug`/display output, minimize cloning, and zeroize owned plaintext buffers where practical.

#### Scenario: Secret wrapper is debug-formatted
- **WHEN** a containing state or error is formatted for tracing
- **THEN** the secret field is redacted and its length/value cannot be recovered from the output

### Requirement: Logging leakage tests
Automated tests SHALL run representative identity, pairing, discovery, provisioning, and failure paths with sentinel secret values and assert captured formatted events do not contain those sentinels or SAS representations. The same test SHALL also assert that the retained recent-event buffer and a diagnostic block produced from it contain none of the sentinels or SAS representations.

#### Scenario: Sentinel scan
- **WHEN** the secret-safety test captures all configured trace levels for representative operations
- **THEN** no forbidden sentinel material appears in any event or error string

#### Scenario: Sentinel scan of retained events
- **WHEN** the same operations run with the retention layer installed and a diagnostic block is produced
- **THEN** neither the retained events nor the block contain the sentinel material or the SAS

### Requirement: Discovery secret fingerprint is the only logged secret-derived identifier
The only value derived from a discovery secret that tracing MAY include besides the public service
selector and routing tokens SHALL be a fingerprint made of the first 4 bytes, hex encoded, of
HMAC-SHA256 keyed by the secret over the ASCII message `fp`. The fingerprint SHALL NOT reveal any
byte of the secret, and logging-leakage tests SHALL assert that events carrying the fingerprint
contain no sentinel secret bytes in any encoding the formatter could produce.

#### Scenario: Fingerprint is logged with a sentinel secret
- **WHEN** a group advertisement is logged with a sentinel discovery secret and the output is captured
  at every level, including the retained event buffer and a diagnostic block
- **THEN** the output contains the 8-hex-digit fingerprint and no hex, base32, decimal, or debug
  rendering of the sentinel secret bytes

#### Scenario: Secret persistence is logged
- **WHEN** a discovery secret is written to or removed from a platform secure store
- **THEN** the event names the slot and operation and outcome only, without secret bytes or
  ciphertext
