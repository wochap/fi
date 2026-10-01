## Purpose

TBD: Define foreground-only Android LAN networking, required platform permissions and multicast lifecycle, secure secret storage, and the Rust-owned platform boundary.

## Requirements

### Requirement: Foreground Android LAN guarantee
While the Android application is foregrounded with required permissions and LAN connectivity, Rust orchestration SHALL run immediate mDNS discovery/advertising and Quinn synchronization; the MVP makes no background execution guarantee. Stopping discovery and closing peer sessions on background lifecycle SHALL apply only under the Android lifecycle policy; it MUST NOT be applied to desktop targets merely because the same lifecycle report is delivered there.

#### Scenario: Activity resumes
- **WHEN** Flutter reports foreground lifecycle and networking is enabled
- **THEN** Rust activates the required discovery and connection tasks without waiting for background scheduling, and attempts to reconnect trusted peers that still have eligible endpoints

#### Scenario: Activity pauses
- **WHEN** Flutter reports background lifecycle on Android
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

### Requirement: Platform lifecycle networking policy
The Rust core SHALL own a lifecycle networking policy selected per platform: `SuspendInBackground` on Android, and `KeepNetworkingInBackground` on desktop targets. Flutter SHALL report lifecycle state on every platform; the policy, not the reporter, SHALL decide whether background stops discovery and closes sessions. Under `KeepNetworkingInBackground`, focus loss, window inactivity, and window hiding SHALL NOT stop discovery or disconnect any peer; only explicit shutdown SHALL tear networking down. The policy SHALL be overridable through core configuration so both behaviours are testable on one host.

#### Scenario: Desktop window loses focus
- **WHEN** the desktop application reports an inactive or hidden lifecycle state while peers are connected
- **THEN** discovery keeps running, every peer session stays open, and no offline transition is emitted

#### Scenario: Desktop application shuts down
- **WHEN** the desktop application performs its shutdown
- **THEN** discovery stops and peer sessions close as before

#### Scenario: Android policy is unchanged
- **WHEN** the Android application reports background lifecycle
- **THEN** discovery stops and peers disconnect exactly as required by the foreground guarantee

#### Scenario: Policy is selected by configuration in tests
- **WHEN** the core is opened with an explicit `SuspendInBackground` policy on a desktop host
- **THEN** a background report stops discovery and disconnects peers, and with `KeepNetworkingInBackground` the same report leaves them untouched

### Requirement: Foreground resumption respects the networking preferences
When a lifecycle policy resumes networking on return to the foreground, it SHALL start normal discovery only if the Discoverable preference is on, and SHALL resume automatic dialing and accepting only if the Sync with paired devices preference is on. A background transition SHALL still stop discovery and close sessions under `SuspendInBackground` whatever the preferences are. Under `KeepNetworkingInBackground`, a user preference turned off SHALL stop the corresponding networking even though the policy alone would keep it running.

#### Scenario: Android foreground with sync paused
- **WHEN** Sync with paired devices is off and the Android application returns to the foreground
- **THEN** discovery restarts only if Discoverable is on, no trusted peer is dialed, and inbound connections stay refused

#### Scenario: Desktop pause overrides the keep-alive policy
- **WHEN** the desktop policy is `KeepNetworkingInBackground` and the user turns Sync with paired devices off
- **THEN** live sessions close and stay closed while the window is focused, unfocused, or hidden

### Requirement: Android key store writes through to the platform store
Every store or removal of the current discovery-group secret and of the previous-epoch discovery
secret performed by the Rust core on Android SHALL be persisted to the Keystore-wrapped platform
store before the operation reports success, whatever triggered it: pairing, an inbound rotation
received from a peer, a local rotation, revocation, orphan replacement, retention expiry, or dataset
reset. When the platform store cannot persist the write, the key-store operation SHALL fail with a
typed secure-store error and the Rust core's view of the secret SHALL remain unchanged. The
previous-epoch secret SHALL be persisted together with its epoch, and the stored epoch SHALL be bound
into the authenticated encryption so that altering it fails decryption. Writes SHALL be applied in
the order the core issued them.

#### Scenario: Secret received from a peer survives restart
- **WHEN** an Android device accepts an inbound discovery-secret rotation from a trusted peer and the
  application process is then killed and relaunched
- **THEN** the relaunched core loads the received secret and epoch, and advertises and browses the
  same group selector as the peer that sent it

#### Scenario: Previous-epoch secret survives restart
- **WHEN** an Android device retains a previous-epoch secret during a rotation and is relaunched
  inside the retention window
- **THEN** the relaunched core loads that previous secret with its epoch and still recognises peers
  advertising on the previous selector

#### Scenario: Platform write fails
- **WHEN** the platform store rejects a discovery-secret write
- **THEN** the key-store operation returns a secure-store error, the in-memory secret is unchanged,
  and an inbound rotation that required the write is neither adopted nor acknowledged

#### Scenario: Dataset reset clears the platform copies
- **WHEN** the user resets the dataset on Android
- **THEN** both the current and the previous-epoch secret are removed from the platform store, and
  the next launch starts with no discovery secret

#### Scenario: Stored epoch is altered
- **WHEN** the persisted previous-epoch value is changed without re-encrypting the secret
- **THEN** loading the previous-epoch secret fails authentication and no secret is seeded from it

### Requirement: Android startup seeds every persisted discovery secret
Android networked startup SHALL seed the Rust key store with the persisted current discovery-group
secret and, when present, the persisted previous-epoch secret with its epoch. Seeding SHALL NOT
write back to the platform store.

#### Scenario: Launch with current and previous secrets persisted
- **WHEN** the platform store holds a current secret and a previous-epoch secret for epoch 3
- **THEN** after startup the core reports the same current secret and a previous secret for epoch 3,
  and no platform write occurs during startup
