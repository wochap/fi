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
