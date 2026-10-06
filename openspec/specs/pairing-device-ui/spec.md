## Purpose

TBD: Define Flutter pairing controls, SAS confirmation, trusted-device management, and typed synchronization-status presentation.

## Requirements

### Requirement: Pairing-mode UI
Flutter SHALL provide controls to start and stop pairing mode, show its remaining bounded lifetime, list live ephemeral candidates, and select one candidate for connection. Candidates that Rust reports as already paired SHALL be hidden from the selectable list, and when every discovered candidate is already paired the UI SHALL say so rather than showing an empty search.

#### Scenario: User starts pairing
- **WHEN** the user explicitly enters pairing mode
- **THEN** the UI reflects the retained discoverable state and displays candidates received from Rust

#### Scenario: Pairing expires
- **WHEN** Rust reports pairing timeout
- **THEN** the UI removes stale candidates and returns to an idle/error explanation without showing success

#### Scenario: Already-paired device is discovered
- **WHEN** a discovered candidate is reported as belonging to an already-trusted device
- **THEN** it is not offered for selection, and the list explains that the remaining devices are already paired rather than appearing empty

### Requirement: SAS confirmation UI
Flutter SHALL display the zero-padded six-digit SAS supplied by Rust for the current attempt and provide explicit confirm and reject actions, without calculating or transmitting the SAS itself. Beside the SAS, Flutter SHALL display the peer DeviceId supplied by Rust for the current attempt, so both users can compare the identity of the device they are about to trust as well as the code. The peer id SHALL be shown in full in a selectable monospace presentation, and MUST NOT be shown before Rust reports it for the awaiting-confirmation state.

#### Scenario: Codes match
- **WHEN** the user confirms the displayed SAS
- **THEN** Flutter invokes the Rust confirmation command and waits for the retained committing/trusted state

#### Scenario: User rejects
- **WHEN** the user rejects a mismatched SAS
- **THEN** Flutter invokes Rust rejection and displays the resulting non-trusted terminal state

#### Scenario: Peer identity is shown at confirmation
- **WHEN** Rust reports the awaiting-confirmation state with a peer DeviceId
- **THEN** the confirmation view shows that DeviceId beside the SAS, labelled as the other device's id, and the candidate list before connection still showed only the endpoint

### Requirement: Trusted-device list
The devices screen SHALL list locally trusted and revoked device records with friendly name, DeviceId presentation, connectivity, last seen, last sync, and status obtained through Rust queries/events. Last sync SHALL reflect the most recent time the peer reached the synced state, not only the pairing time, and SHALL be carried by the same connection-state emission that reports the synced state so the row never shows synced connectivity alongside a never-synced timestamp.

The list SHALL be headed "Trusted devices" with the device count beside it. Each row SHALL show a device icon tile, the friendly name, a state tag (accent with a dot for Connected, Syncing and Synced; the error tag of the unreachable-peer state for a non-revoked row whose last attempt failed; neutral otherwise), and one line "Seen <time> · Synced <time>", with an absent value reading "Never seen" or "Never synced". A non-revoked row whose last attempt failed SHALL instead show the plain-language line, guidance and actions of the unreachable-peer state. Last seen and last sync SHALL be presented as status times, not exact values: a value under one minute old reads "just now"; under one hour reads a whole number of minutes ago; under twenty-four hours reads a whole number of hours ago; anything older reads as a short local date and time with weekday, day, month, and hour:minute, adding the year only when it differs from the current year. A value in the future because of clock skew SHALL read as "just now". Relative wording SHALL be refreshed at least once per minute while the devices screen is mounted, without waiting for a device event. Record field values, chart axes, and query output SHALL keep their exact formatting; this presentation applies to status metadata only.

Each trusted row SHALL offer "Details", collapsed by default, and a ⋮ menu with the row's rename, revoke and delete actions. At 720px and wider Details SHALL expand inline under the row. Below 720px Details SHALL open as a pushed screen titled with the friendly name, with a back action and the same ⋮ menu.

Details SHALL show:
- The state, the endpoint being tried or last tried, the last attempt time as a status time, and the local device's bound sync port. These are a four-column grid at 720px and wider and label/value rows below 720px.
- The failure code and the failure reason text when the last attempt failed, both as Rust reports them and in every language unchanged.
- The full DeviceId with a copy action. Below 720px the id may be shortened to its first and last eight hex characters, but copy SHALL always place the full id on the clipboard.
- A connection log headed "Connection log · N events".

The connection log SHALL list the retained events for that peer and the retained local-device events, oldest first, each as time (HH:mm:ss), category, and message. The category SHALL be "pairing" for pairing events, "address" for address and discovery events, "peer" for peer connection and sync events, and "device" for other local events. The message SHALL be the event's technical text without reformatting its fields. At 720px and wider the log SHALL offer an All / Pairing / Peer filter: Pairing shows only pairing events, and Peer shows peer and address events.

Details SHALL contain a "Reconnect" action that invokes the manual reconnect command, a "Connect by address…" action that opens the Connect by address dialog for that device, and a "Copy log" action that places the peer's diagnostic block on the clipboard and confirms the copy. "Reconnect" SHALL be unavailable on a revoked row and while a reconnect for that row is in flight. "Connect by address…" SHALL NOT be offered on a revoked row.

#### Scenario: Device connects and syncs
- **WHEN** Rust advances a trusted peer from connected through syncing to synced
- **THEN** the corresponding row and global status update without UI timing heuristics

#### Scenario: Synced row shows a sync time
- **WHEN** the row for a peer reports synced connectivity
- **THEN** its last-sync value is a timestamp rather than "Never synced", and it is no earlier than the transition that produced the synced state

#### Scenario: Recent timestamps read relatively
- **WHEN** a device was last seen 30 minutes ago and last synced 3 hours ago
- **THEN** the row reads "Seen 30 min ago · Synced 3 h ago"

#### Scenario: Older timestamps read as a short date
- **WHEN** a device was last synced two days ago on Tuesday 22 September at 13:00 local time in the current year
- **THEN** the row reads "Synced Tue 22 Sep 13:00", and a value from a previous year includes that year

#### Scenario: Relative wording stays current
- **WHEN** the devices screen stays open for two minutes with no device event
- **THEN** a row that read "Seen just now" reads "Seen 2 min ago" without any refresh action

#### Scenario: Record values unaffected
- **WHEN** a record has a Date & time field
- **THEN** its list row and editor still show the exact `yyyy-MM-dd HH:mm` value

#### Scenario: Details are hidden until asked for
- **WHEN** the devices screen renders a trusted row
- **THEN** the endpoint, failure text, port, and log lines are not visible until the user opens that row's Details

#### Scenario: Failed peer shows why
- **WHEN** a peer's last attempt failed with a TLS failure at `192.168.1.20:47380` and the user opens Details
- **THEN** the panel shows the failure code `TLS_FAILED` with the failure category and message, the endpoint, when the attempt happened, and the log lines for that peer

#### Scenario: Categorized log with filter
- **WHEN** Details are open on a 1240px-wide screen and the retained events include pairing, address and peer events
- **THEN** each log line shows its time, its category and its message, and choosing Pairing hides every line that is not a pairing event

#### Scenario: Details on a phone
- **WHEN** the user opens Details for "Fi f755167e" on a 390px-wide screen
- **THEN** a pushed screen titled "Fi f755167e" shows the state tag, Endpoint, Last attempt, Sync port and ID rows, the connection log, and a full-width Reconnect button

#### Scenario: Reconnect from details
- **WHEN** the user presses Reconnect on a failed peer
- **THEN** the manual reconnect command is invoked for that DeviceId, the action is disabled until it returns, and the row's connection tag follows the state emissions

#### Scenario: Copy all confirms
- **WHEN** the user presses Copy log
- **THEN** the clipboard receives the diagnostic block for that peer and the screen shows a brief confirmation

#### Scenario: Revoked row offers no reconnect
- **WHEN** a row's record is revoked and its Details are opened
- **THEN** the panel shows the retained lines and Copy log, but no Reconnect and no Connect by address action

### Requirement: Device rename and revoke actions
Flutter SHALL expose friendly-name editing and confirmed revoke/unpair actions that delegate to Rust and refresh persisted device state.

#### Scenario: Rename succeeds
- **WHEN** the user saves a valid device name
- **THEN** the devices query returns the new name while DeviceId and trust key remain unchanged

#### Scenario: Revoke succeeds
- **WHEN** the user confirms revocation
- **THEN** Rust revokes and disconnects the device and the UI presents it as revoked rather than merely hiding it

### Requirement: Revoked device delete action
The devices screen SHALL offer a "Delete" action only on rows whose record is revoked. The action SHALL require explicit confirmation that states the record will be removed and that the device can be paired again later. On confirmation Flutter SHALL delegate to Rust and refresh the device list so the row disappears. A trusted row SHALL NOT offer the delete action.

#### Scenario: Delete a revoked device
- **WHEN** the user chooses Delete on a revoked row and confirms
- **THEN** the row is removed from the devices list and the trusted-device count is unchanged

#### Scenario: Delete is cancelled
- **WHEN** the user chooses Delete and dismisses the confirmation
- **THEN** the row remains listed as revoked and no Rust call is made

#### Scenario: Trusted row offers no delete
- **WHEN** a row's record is trusted
- **THEN** its menu offers rename and revoke but not delete

### Requirement: Complete sync-status vocabulary
The application shell SHALL present the typed Rust aggregate status exactly, mapping `Offline`, `Searching`, `Connected`, `Syncing`, `Synced`, `Error`, and `Paused` to the labels "Offline", "Looking for paired devices", "Connected", "Syncing", "Synced", "Error", and "Paused", each with a distinct icon. The label for `Searching` MUST NOT reuse the word "Searching" so it is not mistaken for pairing discovery, which keeps its own copy on the pairing card. Trusted device rows SHALL present paused connectivity as "Paused".

#### Scenario: Heads change while connected
- **WHEN** a previously synced peer relationship receives or creates new authoritative heads
- **THEN** presentation returns to `Syncing` until Rust reports convergence

#### Scenario: Searching at startup
- **WHEN** the application is foregrounded with trusted devices recorded and none yet reachable
- **THEN** the shell shows "Looking for paired devices" with its icon, and the pairing card still shows its idle copy because pairing mode was not started

#### Scenario: Every status has an icon
- **WHEN** the aggregate status takes each of its seven values in turn
- **THEN** the status chip shows a different icon for each value alongside the label

#### Scenario: Paused while devices are recorded
- **WHEN** Sync with paired devices is off and trusted devices are recorded
- **THEN** the status chip reads "Paused" with its icon and each trusted row reads "Paused" instead of "Offline"

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

### Requirement: Locked secure store is explained with a retry
When Rust reports that the secure key store is locked, Flutter SHALL show that specific condition — naming the desktop keyring and the action of unlocking it — instead of the generic networking-initialization message, and SHALL offer a retry action that re-runs the failed operation without restarting the application.

#### Scenario: Startup meets a locked keyring
- **WHEN** networking cannot start because the secure store is locked
- **THEN** the UI shows a locked-keyring explanation with a retry action, and local data remains usable

#### Scenario: Commit fails on a locked keyring
- **WHEN** a pairing commit fails because the secure store is locked
- **THEN** the pairing card leaves the "saving trust" progress state at once and shows the locked-keyring explanation with retry, never an expiry message

#### Scenario: Retry succeeds after unlocking
- **WHEN** the user unlocks the keyring and presses retry
- **THEN** the locked-keyring message clears and the affected operation proceeds

### Requirement: Exhausted port range is explained with a retry
When Rust reports that peer networking is deferred because every port in the fixed range is in use, Flutter SHALL show that specific condition in the networking-deferred banner, naming the UDP range and stating that another program or another instance of this application holds the ports, and SHALL offer the retry action. The banner MUST NOT show the generic networking-initialization message for this condition. Local data SHALL remain usable behind the banner.

#### Scenario: Startup meets an exhausted range
- **WHEN** the application starts while all ports `47380` through `47389` are held by other sockets
- **THEN** the banner names the range `47380-47389`, explains that the ports are in use, offers retry, and the collection surfaces below it stay usable

#### Scenario: Retry succeeds after a port frees up
- **WHEN** a port in the range is released and the user presses retry
- **THEN** the banner disappears and sync status leaves the deferred state

### Requirement: Build identity on the devices screen
The app SHALL show a muted, selectable monospace build label reading `fi <version> · <hash>`, where version and hash come from the bridge build-identity query. When the build was dirty the hash SHALL be followed by `-dirty`. The label SHALL be shown in the "Version" row of Settings › About on every platform and at every width; the navigation sidebar SHALL NOT show it, and the Devices screen SHALL NOT end with it. The label SHALL be shown whether or not a dataset exists or any device is paired, and SHALL read `fi <version> · unknown` when the hash is unavailable. It SHALL never block the rest of the screen: while the query is pending or if it fails, the label is simply absent.

#### Scenario: Clean release build
- **WHEN** the bridge reports version `0.1.21`, hash `a1b2c3d`, and dirty false
- **THEN** the build label reads `fi 0.1.21 · a1b2c3d`

#### Scenario: Dirty development build
- **WHEN** the bridge reports version `0.1.21`, hash `a1b2c3d`, and dirty true
- **THEN** the label reads `fi 0.1.21 · a1b2c3d-dirty`

#### Scenario: Placement by screen width
- **WHEN** the app is shown on a 1240px-wide screen and then on a 390px-wide screen
- **THEN** on both the label is in Settings › About, the wide sidebar foot shows only the sync status, and the narrow Devices screen does not end with it

#### Scenario: No devices paired
- **WHEN** the trusted-device list is empty
- **THEN** the label is still shown

#### Scenario: Query fails
- **WHEN** the build-identity query returns an error
- **THEN** every other section renders normally and no label is shown

### Requirement: Connection switches on the devices screen
The devices screen SHALL show a Connections section with two switches, "Discoverable" and "Sync with paired devices", each with a help entry. Each switch SHALL reflect the persisted preference obtained from Rust, SHALL delegate a toggle to Rust, and SHALL show the value Rust reports back rather than an optimistic value. A failed toggle SHALL leave the switch at its previous value and surface the error inline. The section SHALL be visible whether or not any device is paired.

#### Scenario: Switches reflect stored preferences
- **WHEN** the devices screen opens on an installation where Discoverable is off and Sync with paired devices is on
- **THEN** the Discoverable switch reads off and the Sync switch reads on

#### Scenario: Toggling sync off
- **WHEN** the user turns Sync with paired devices off
- **THEN** Rust is asked to pause, the switch reads off once Rust confirms, and the status chip reads "Paused"

#### Scenario: Toggle fails
- **WHEN** Rust rejects a toggle with an error
- **THEN** the switch returns to its previous value and the error is shown inline on the devices screen

### Requirement: Pairing card explains that pairing works while discovery is off
While Discoverable is off and pairing is idle, the devices screen SHALL state that discovery is off and that pairing still works: inside the "Trusted devices" empty state when no device is trusted, or as a muted line beside the "Pair device" action otherwise. The pairing controls SHALL remain enabled whatever the two preferences are set to.

#### Scenario: Idle card with discovery off
- **WHEN** Discoverable is off, pairing is idle and no device is trusted
- **THEN** the empty state shows its copy followed by a note that discovery is off and pairing still works, and "Start pairing" is enabled

#### Scenario: Idle with discovery off and devices trusted
- **WHEN** Discoverable is off, pairing is idle and one device is trusted
- **THEN** a muted line beside "Pair device" says discovery is off and pairing still works, and "Pair device" is enabled

#### Scenario: Idle card with discovery on
- **WHEN** Discoverable is on and pairing is idle
- **THEN** no discovery-off note is shown

### Requirement: This device shows its identity
The "This device" section of the devices screen SHALL show the name this device presents to peers during pairing and the local DeviceId, obtained from Rust, in a monospace presentation. At 720px and wider the id SHALL be shown in groups of eight hex characters, eliding the middle groups with "…"; below 720px it SHALL be shortened to its first and last eight characters. A "Copy ID" action SHALL place the full DeviceId on the clipboard and confirm the copy. The section SHALL also hold the "Reset this device's data" entry, which opens the reset confirmation. When Rust reports that no identity is available, the section SHALL say that networking is not set up instead of showing an empty identifier.

#### Scenario: Identity shown
- **WHEN** the devices screen is opened on a networked device
- **THEN** the "This device" section shows the pairing name and the local DeviceId, and the id's first and last characters match the id a paired peer lists for this device

#### Scenario: Identity copyable
- **WHEN** the user presses Copy ID
- **THEN** the clipboard receives the full identifier, not the shortened form, and a brief confirmation is shown

### Requirement: Devices screen pairing entry points
When no device is trusted, the "Trusted devices" section SHALL show a dashed empty state reading "No devices paired yet" with the line "Start pairing on both devices while they're nearby. Pairing turns itself off after 2 minutes." (the last sentence may be omitted below 720px) and a primary "Start pairing" action. When at least one device is trusted, the section header SHALL offer a "Pair device" action instead. Either action SHALL enter pairing mode, and while pairing is active the pairing card SHALL take the empty state's place and run the pairing, candidate and SAS flow unchanged. While Discoverable is off, the empty state SHALL add the note that discovery is off and pairing still works. After a pairing completes, the screen SHALL show a dismissible banner reading "Paired with <name>. The first sync starts automatically." with a "Pair another" action that enters pairing mode again.

#### Scenario: Empty state starts pairing
- **WHEN** no device is trusted and the user presses "Start pairing"
- **THEN** pairing mode starts and the pairing card replaces the empty state

#### Scenario: Pair another after success
- **WHEN** a pairing with "Fi f755167e" completes
- **THEN** a banner reads "Paired with Fi f755167e. The first sync starts automatically." with "Pair another", and dismissing it removes it

#### Scenario: Discovery off note
- **WHEN** Discoverable is off and no device is trusted
- **THEN** the empty state includes the note that discovery is off and pairing still works, and "Start pairing" is enabled

### Requirement: Unreachable peer is explained in plain language
A trusted, non-revoked row whose last connection attempt failed SHALL present the failure as a person-facing state chosen from the typed failure kind, while Sync with paired devices is on (mock devices-unreachable):
- No route: the tag "Not reachable" and the line "Not found on your network".
- Route, transport or stream failure, or a failure without a kind: the tag "Not reachable" and the line "Didn't answer at its last address".
- Trust or TLS failure: the tag "Can't verify" and the line "It no longer recognizes this device".

The tag SHALL use the error style with an icon beside its text, never colour alone. The line SHALL replace the "Seen · Synced" line and SHALL end with " · Last synced <time>" as a status time, or " · Never synced". Under the row, without opening Details, a guidance box SHALL show:
- For "Not reachable": "Make sure both devices are on the same Wi-Fi and Fi is open on the other device. Fi keeps trying on its own." and the actions "Try again", "Pair again" and "Connect by address…".
- For "Can't verify": "The other device may have been reset or may have unpaired this one. Pair again on both devices." and the actions "Try again" and "Pair again".

"Try again" SHALL invoke the manual reconnect command and be unavailable while a reconnect for that row is in flight. "Pair again" SHALL enter pairing mode exactly as "Pair device" does. "Connect by address…" SHALL open the Connect by address dialog for that device. At 720px and wider the box SHALL hold all its actions; below 720px it SHALL hold "Try again" and "Pair again", and "Connect by address…" SHALL be reached from the device's Details screen. The actions SHALL wrap onto another line rather than truncate. The raw failure text, failure code, endpoints, ports and log lines SHALL appear only under Details. When the peer later connects, the row SHALL return to its normal tag, line and no guidance box. While Sync with paired devices is off the row SHALL read "Paused" with no guidance box.

#### Scenario: Peer not found on the network
- **WHEN** the last attempt for "Fi f755167e" failed with no route and it last synced 2 hours ago, on a 1240px-wide screen
- **THEN** the row shows the "Not reachable" error tag and "Not found on your network · Last synced 2 h ago", the guidance box shows the same-Wi-Fi guidance with "Try again", "Pair again" and "Connect by address…", and neither "no eligible endpoint" nor `NO_ELIGIBLE_ENDPOINT` is visible until Details is opened

#### Scenario: Peer did not answer
- **WHEN** the last attempt failed because the dial to the last known address timed out
- **THEN** the row shows "Not reachable" and "Didn't answer at its last address" with the same guidance and actions

#### Scenario: Peer no longer recognizes this device
- **WHEN** the last attempt failed with a trust failure
- **THEN** the row shows the "Can't verify" error tag, "It no longer recognizes this device", the pair-again guidance, and "Try again" and "Pair again" without "Connect by address…"

#### Scenario: Try again
- **WHEN** the user presses "Try again"
- **THEN** the manual reconnect command is invoked for that device and the action is unavailable until it returns

#### Scenario: Pair again
- **WHEN** the user presses "Pair again"
- **THEN** pairing mode starts and the pairing card is shown

#### Scenario: Error state on a phone
- **WHEN** the same no-route failure is shown on a 390px-wide screen
- **THEN** the guidance box shows "Try again" and "Pair again", and the device's Details screen offers "Connect by address…"

#### Scenario: Peer comes back
- **WHEN** a row shows "Not reachable" and the peer then reaches the synced state
- **THEN** the row shows "Synced" with the "Seen · Synced" line and no guidance box

#### Scenario: Spanish copy fits
- **WHEN** the interface is in Spanish on a 360px-wide screen and a row shows the "Not reachable" state
- **THEN** the tag, the line, the guidance and both buttons show their full Spanish text without overflow

### Requirement: Connect by address dialog
"Connect by address…" SHALL open, for one trusted device, a dialog at 720px and wider and a bottom sheet below 720px (mock devices-connect-address), holding:
- The title "Connect by address".
- The line "Reach <name> directly when it isn't found on the network. It must already be paired."
- An "Address" field prefilled with the device's last known address, else the endpoint last tried for it, else empty, with the example `192.168.0.165:47380` as its hint, and the help line "Find it on the other device under Settings › About › This device."
- "Cancel" and "Connect".

"Connect" SHALL be unavailable while the field is empty and while an attempt runs. While an attempt runs the dialog SHALL show "Connecting…" and the field SHALL not be editable. "Connect" SHALL invoke the connect-by-address command for that device with the field text. The outcome SHALL be shown as follows:
- Connected: the dialog closes and a brief confirmation reads "Connected to <name>".
- Invalid address: the field shows "Enter an IPv4 address like 192.168.0.165, optionally followed by :port."
- Not a local-network address: the field shows "Use an address on your local network or tailnet, like 192.168.x.x or 100.x.x.x."
- No route, route, transport or stream failure: "No answer at <address>. Check the address and that Fi is open on the other device."
- Trust or TLS failure: "The device at <address> isn't <name>."
- Paused: "Sync with paired devices is off. Turn it on to connect."
- Any other error: the error's localized text.

After a failure the dialog SHALL stay open with the typed text kept, so the user can correct it. "Cancel" SHALL close the dialog at any time. Every text SHALL be shown in the active language; the address, the example address and the device name SHALL stay as they are.

#### Scenario: Prefilled with the last known address
- **WHEN** the user opens Connect by address for "Fi f755167e" whose last known address is `192.168.0.165:47380`
- **THEN** the dialog reads "Reach Fi f755167e directly when it isn't found on the network. It must already be paired." and the Address field holds `192.168.0.165:47380`

#### Scenario: Successful connection
- **WHEN** the user presses Connect and the command reports connected
- **THEN** "Connect" was unavailable and "Connecting…" was shown while the command ran, the dialog closes, and "Connected to Fi f755167e" is shown

#### Scenario: Invalid address
- **WHEN** the user enters `192.168.0` and presses Connect
- **THEN** the dialog stays open, the text `192.168.0` is kept, and the field shows the invalid-address line

#### Scenario: Address not admitted
- **WHEN** the user enters `8.8.8.8` and the command reports not a local-network address
- **THEN** the dialog stays open and the field shows "Use an address on your local network or tailnet, like 192.168.x.x or 100.x.x.x."

#### Scenario: Wrong device at the address
- **WHEN** the command reports a trust failure for `192.168.0.20:47380`
- **THEN** the dialog shows "The device at 192.168.0.20:47380 isn't Fi f755167e." and stays open

#### Scenario: Dialog in Spanish
- **WHEN** the interface is in Spanish and the user opens Connect by address
- **THEN** the title, lead line, field label, help line and buttons are Spanish, and the prefilled address is unchanged

#### Scenario: Phone
- **WHEN** the user opens Connect by address from Details on a 390px-wide screen
- **THEN** it opens as a bottom sheet with the same content and actions
