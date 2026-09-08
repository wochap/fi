## Purpose

TBD: Define foreground-only Android LAN networking, required platform permissions and multicast lifecycle, secure secret storage, and the Rust-owned platform boundary.

## Requirements

### Requirement: Foreground Android LAN guarantee
While the Android application is foregrounded with required permissions and LAN connectivity, Rust orchestration SHALL run immediate mDNS discovery/advertising and Quinn synchronization; the MVP makes no background execution guarantee.

#### Scenario: Activity resumes
- **WHEN** Flutter reports foreground lifecycle and networking is enabled
- **THEN** Rust activates the required discovery and connection tasks without waiting for background scheduling

#### Scenario: Activity pauses
- **WHEN** Flutter reports background lifecycle
- **THEN** Rust stops foreground-only discovery work and releases platform multicast capability while preserving durable state

### Requirement: Android network permissions
The Android target SHALL declare the permissions required for ordinary sockets, network-state observation, and Wi-Fi multicast reception for its target SDK, and SHALL surface denied/unavailable capabilities as typed application errors.

#### Scenario: Multicast permission or capability is unavailable
- **WHEN** foreground discovery cannot obtain required Android multicast access
- **THEN** sync status becomes an actionable error and no busy retry loop is started

### Requirement: Scoped multicast lock
On Android versions/configurations requiring it, a non-reference-counted Wi-Fi multicast lock SHALL be held only while foreground mDNS is active and SHALL be released on stop, backgrounding, initialization failure, or shutdown.

#### Scenario: Discovery fails after lock acquisition
- **WHEN** mDNS startup returns an error
- **THEN** RAII/lifecycle cleanup releases the multicast lock

### Requirement: Android secure secret storage
The Android `SecureKeyStore` adapter SHALL protect the permanent Ed25519 seed and discovery secrets at rest using a non-exportable Android Keystore key and authenticated encryption, and MUST NOT store the wrapping key or plaintext secrets in SQLite.

#### Scenario: Application restarts
- **WHEN** wrapped secret records and the same Android Keystore entry remain
- **THEN** the adapter authenticates/decrypts them and preserves DeviceId and discovery group

#### Scenario: Wrapped secret is modified
- **WHEN** ciphertext, nonce, associated metadata, or key alias binding is changed
- **THEN** authenticated decryption fails without generating a replacement identity automatically

### Requirement: Rust-owned platform abstraction
Android native/JNI code SHALL expose only secure-store, multicast, network-context, and lifecycle capabilities behind Rust ports; pairing, trust, routing, discovery policy, and Repo synchronization MUST remain owned by Rust.

#### Scenario: Android NSD fallback is required
- **WHEN** instrumentation proves raw Rust mDNS unreliable on a supported Android environment
- **THEN** an Android-backed adapter can replace `MdnsDiscovery` without changing pairing, routing, trust, or Repo APIs

### Requirement: No always-running Android daemon
The MVP SHALL NOT add WorkManager, a foreground service, or another persistent background daemon for synchronization.

#### Scenario: Application remains backgrounded
- **WHEN** Android suspends or stops the application
- **THEN** the system makes no claim that discovery or synchronization continues
