## Purpose

Defines the two installation-level networking preferences a user can set, Discoverable and Sync with paired devices, how they persist, and what each one stops and allows so the user controls every outside connection except explicit pairing.

## Requirements

### Requirement: Two independent networking preferences
The application SHALL keep two boolean preferences for this installation: Discoverable and Sync with paired devices. Both SHALL default to on. Each SHALL be readable and settable through the application core, and a change SHALL take effect immediately without restarting the application. The two preferences SHALL be independent: changing one MUST NOT change the other.

#### Scenario: Fresh installation
- **WHEN** the core is opened on an installation that has never stored a preference
- **THEN** both preferences read as on and networking behaves as before this change

#### Scenario: One preference is changed
- **WHEN** the user turns Sync with paired devices off while Discoverable is on
- **THEN** Discoverable still reads as on and normal discovery keeps running

### Requirement: Preferences survive restart and dataset reset
Both preferences SHALL be stored durably in the installation's authoritative control store and SHALL be applied before networking starts at open, so a preference that is off is never briefly on during startup. A dataset reset SHALL leave both preferences unchanged, because they describe the installation rather than the dataset.

#### Scenario: Restart with discovery off
- **WHEN** the user turned Discoverable off and the application is restarted
- **THEN** the core opens with normal discovery not running and Discoverable reads as off

#### Scenario: Restart with sync paused
- **WHEN** the user turned Sync with paired devices off and the application is restarted
- **THEN** the core opens without dialing any peer, refuses inbound sync connections, and the aggregate status is Paused

#### Scenario: Dataset reset keeps the preferences
- **WHEN** both preferences are off and the user resets the dataset
- **THEN** after the reset both preferences still read as off

### Requirement: Discoverable off stops normal discovery only
While Discoverable is off, the application MUST NOT advertise or browse the group-scoped normal discovery service. It SHALL keep dialing endpoints it already holds until they expire, SHALL keep accepting inbound sync connections from trusted devices, and SHALL keep any live sync session open. Turning Discoverable back on SHALL start normal discovery at once when networking is otherwise active.

#### Scenario: Discovery is turned off with a live session
- **WHEN** a trusted peer is synced and the user turns Discoverable off
- **THEN** the session stays open, the peer stays synced, and the device stops advertising and browsing the normal service

#### Scenario: Peer dials in while discovery is off
- **WHEN** Discoverable is off, Sync with paired devices is on, and a trusted peer connects to this device's sync port
- **THEN** the connection is authenticated and synchronizes as usual

#### Scenario: Discovery is turned back on
- **WHEN** the user turns Discoverable on while the application is in the foreground with networking enabled
- **THEN** advertising and browsing of the normal service start without a restart

### Requirement: Sync paused closes, refuses, and blocks connections
While Sync with paired devices is off, the application SHALL suspend automatic dialing, SHALL close every live sync session, SHALL refuse inbound sync connections before any handshake, and SHALL reject a manual connection request with a typed paused error. Turning the preference back on SHALL resume automatic dialing and accepting, and SHALL attempt to reconnect trusted peers whose endpoints are still known.

#### Scenario: Pausing with live sessions
- **WHEN** two trusted peers are synced and the user turns Sync with paired devices off
- **THEN** both sessions close, no redial is attempted, and no peer reads as connected, syncing, or synced

#### Scenario: Inbound connection while paused
- **WHEN** Sync with paired devices is off and a trusted peer dials this device's sync port
- **THEN** the connection is refused without authenticating and no session is registered

#### Scenario: Manual connect while paused
- **WHEN** Sync with paired devices is off and a manual connection to a trusted peer is requested
- **THEN** the request fails with a typed paused error and no dial takes place

#### Scenario: Resuming
- **WHEN** the user turns Sync with paired devices back on
- **THEN** inbound connections are accepted again and trusted peers with unexpired endpoints are dialed without waiting for a discovery announcement

### Requirement: Paused status is derived from the preference
While Sync with paired devices is off, the aggregate sync status SHALL be `Paused` regardless of per-peer connection state, and every trusted device's connectivity SHALL be reported as paused. `Paused` SHALL take precedence over Offline, Searching, and Error. When the preference is on, the aggregate status SHALL be computed exactly as before this change.

#### Scenario: Aggregate status while paused
- **WHEN** Sync with paired devices is off and the application is in the foreground with trusted devices recorded
- **THEN** the aggregate status is Paused, not Searching or Offline

#### Scenario: Per-device state while paused
- **WHEN** Sync with paired devices is off
- **THEN** each trusted, non-revoked device row reports paused connectivity

### Requirement: Preferences take precedence over lifecycle resumption
A lifecycle transition to the foreground, and any other automatic networking resumption such as a deferred networking retry or a discovery-secret rotation, SHALL restore only the networking that the preferences allow. Discovery MUST NOT restart while Discoverable is off, and dialing or accepting MUST NOT resume while Sync with paired devices is off.

#### Scenario: Android returns to the foreground while paused
- **WHEN** Sync with paired devices is off on Android and the application returns from background to foreground
- **THEN** normal discovery restarts only if Discoverable is on, and no peer is dialed or accepted

#### Scenario: Secret rotation while discovery is off
- **WHEN** Discoverable is off and the discovery-group secret is rotated after a revocation
- **THEN** the new secret and epoch are stored but the normal discovery service is not started

### Requirement: Pairing is unaffected by the preferences
Explicit pairing, including its own ephemeral advertisement, its own browsing, its own transport, and the installation of trust and discovery secrets on success, SHALL work identically whatever the two preferences are set to. Completing a pairing SHALL NOT turn either preference on.

#### Scenario: Pairing with both preferences off
- **WHEN** both preferences are off and the user pairs a new device with a matching SAS on both sides
- **THEN** the pairing completes, the new device is trusted, and both preferences still read as off
