## Purpose

TBD: Define Flutter pairing controls, SAS confirmation, trusted-device management, and typed synchronization-status presentation.

## Requirements

### Requirement: Pairing-mode UI
Flutter SHALL provide controls to start and stop pairing mode, show its remaining bounded lifetime, list live ephemeral candidates, and select one candidate for connection.

#### Scenario: User starts pairing
- **WHEN** the user explicitly enters pairing mode
- **THEN** the UI reflects the retained discoverable state and displays candidates received from Rust

#### Scenario: Pairing expires
- **WHEN** Rust reports pairing timeout
- **THEN** the UI removes stale candidates and returns to an idle/error explanation without showing success

### Requirement: SAS confirmation UI
Flutter SHALL display the zero-padded six-digit SAS supplied by Rust for the current attempt and provide explicit confirm and reject actions, without calculating or transmitting the SAS itself.

#### Scenario: Codes match
- **WHEN** the user confirms the displayed SAS
- **THEN** Flutter invokes the Rust confirmation command and waits for the retained committing/trusted state

#### Scenario: User rejects
- **WHEN** the user rejects a mismatched SAS
- **THEN** Flutter invokes Rust rejection and displays the resulting non-trusted terminal state

### Requirement: Trusted-device list
The devices screen SHALL list locally trusted and revoked device records with friendly name, DeviceId presentation, connectivity, last seen, last sync, and status obtained through Rust queries/events.

#### Scenario: Device connects and syncs
- **WHEN** Rust advances a trusted peer from connected through syncing to synced
- **THEN** the corresponding row and global status update without UI timing heuristics

### Requirement: Device rename and revoke actions
Flutter SHALL expose friendly-name editing and confirmed revoke/unpair actions that delegate to Rust and refresh persisted device state.

#### Scenario: Rename succeeds
- **WHEN** the user saves a valid device name
- **THEN** the devices query returns the new name while DeviceId and trust key remain unchanged

#### Scenario: Revoke succeeds
- **WHEN** the user confirms revocation
- **THEN** Rust revokes and disconnects the device and the UI presents it as revoked rather than merely hiding it

### Requirement: Complete sync-status vocabulary
The application shell SHALL present `Offline`, `Searching`, `Connected`, `Syncing`, `Synced`, or `Error` exactly from typed Rust aggregate status.

#### Scenario: Heads change while connected
- **WHEN** a previously synced peer relationship receives or creates new authoritative heads
- **THEN** presentation returns to `Syncing` until Rust reports convergence

### Requirement: Pairing is reachable from a rootless onboarding state
The onboarding surface presented when a local dataset does not yet exist SHALL provide a pairing entry
point that reaches the same pairing controls offered by the devices screen: start and stop pairing
mode, show its remaining bounded lifetime, list live ephemeral candidates, select a candidate, display
the Rust-supplied SAS, and confirm or reject. A rootless device MUST NOT be required to create a local
dataset in order to reach pairing.

#### Scenario: Fresh installation joins instead of creating
- **WHEN** a device with no local dataset enters pairing mode from onboarding, selects a ready peer,
  and both users confirm matching SAS values
- **THEN** the device receives the peer's root, reaches the ready state, and presents the peer's
  synchronized collections without any out-of-band step

#### Scenario: Pairing surface is shared, not duplicated
- **WHEN** the same pairing session is presented from onboarding and later from the devices screen
- **THEN** both render the SAS exactly as supplied by Rust without local computation or reformatting

### Requirement: The pairing controller outlives bootstrap transitions
Pairing state SHALL be owned above the bootstrap-state switch so that an in-flight confirmation is not
interrupted when the application transitions between onboarding, joining, and the collection shell.
Ownership SHALL be established only after the local service is initialized and the foreground state
has been applied, and every bridge call made while establishing that ownership SHALL be valid in the
rootless state.

#### Scenario: Confirmation spans a bootstrap transition
- **WHEN** a joining device confirms the SAS and the bootstrap state advances from needs-decision
  through joining to ready
- **THEN** the confirmation completes without the owning controller being disposed mid-call and
  without a notification being delivered to a disposed controller

#### Scenario: Pairing state is established before any dataset exists
- **WHEN** the controller is started on a rootless device
- **THEN** it obtains the trusted-device list, pairing state, pairing candidates, and aggregate
  synchronization status without error, and the aggregate status reflects searching rather than
  offline while the application is foregrounded

### Requirement: The joining state identifies the provisioning device
While a received root is being joined, the application SHALL present live feedback that names the
provisioning device rather than an unnamed static message, and SHALL do so for the full bounded join
window. When no provisioning device name is available, the surface SHALL fall back to unnamed joining
copy rather than presenting an empty name.

#### Scenario: Join follows a live pairing confirmation
- **WHEN** a rootless device confirms the SAS and begins joining the received root
- **THEN** the joining surface names the provisioning device until the local dataset becomes available

#### Scenario: Join is resumed without a live session
- **WHEN** the application restarts into a persisted joining state with no active pairing session
- **THEN** the joining surface presents unnamed joining copy and does not fail or render a blank name

### Requirement: Onboarding prevents creating a root while a pairing window is open
The onboarding surface SHALL NOT permit creating a local dataset while pairing mode is active, and
SHALL stop any active pairing window before issuing a create. The prevented action SHALL be explained
to the user rather than presented as an unexplained disabled control.

#### Scenario: Create is attempted during pairing
- **WHEN** pairing mode is active on a rootless device
- **THEN** creating a dataset is unavailable, the reason is stated, and stopping pairing restores the
  ability to create

#### Scenario: Stale root state is never advertised
- **WHEN** a rootless device enters pairing mode and the user then creates a dataset
- **THEN** pairing is stopped before the create is issued, so no handshake advertises a root state that
  no longer holds and no second root is created against an in-flight provisioning attempt

### Requirement: Onboarding states the preconditions for pairing
The onboarding surface SHALL state that the peer must already have a dataset, and SHALL state that
connection is initiated from one device only. Both preconditions SHALL be presented before the user
can reach the failure they prevent.

#### Scenario: Two rootless devices attempt to pair
- **WHEN** a device without a dataset enters pairing mode from onboarding
- **THEN** the surface states that the peer must already have a dataset, and a resulting
  both-rootless failure is presented as that guidance rather than as an unexplained error

#### Scenario: Both devices attempt to connect
- **WHEN** the onboarding surface presents a selectable candidate
- **THEN** it states that connection is initiated from one device only

### Requirement: Root mismatch is presented as an actionable condition
A pairing attempt between two devices holding different established roots SHALL be presented as an
actionable condition that states the cause and offers the dataset reset for this device as the
resolution. The application MUST NOT present it as a transient failure, offer a retry that cannot
succeed, or imply that the two roots can be merged.

#### Scenario: Devices hold different roots
- **WHEN** a device with an established root attempts to pair with a device holding a different
  established root
- **THEN** the failure names the differing-root cause and presents a reset action for this device that
  opens the reset confirmation, alongside the option to pair a different device

### Requirement: Reset is reachable from the devices surface
The devices surface SHALL offer a reset action that opens the reset confirmation and, on confirmation, performs the reset and returns the user to onboarding.

#### Scenario: Reset from devices
- **WHEN** the user confirms the reset from the devices surface
- **THEN** pairing is stopped if active, the reset runs, and the onboarding surface is shown in `NeedsDecision`

### Requirement: Fatal bootstrap errors offer reset when reset can resolve them
The fatal bootstrap-error surface SHALL show a reset action instead of a retry action when the error is classified as reset-resolvable, and SHALL keep the retry action otherwise.

#### Scenario: Unsupported schema version
- **WHEN** initialization fails because the root's application schema version is unsupported
- **THEN** the error surface offers "Reset this device's data" and no retry

#### Scenario: Locked secure store
- **WHEN** initialization fails because the secure key store is locked
- **THEN** the error surface offers retry and no reset
