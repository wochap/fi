# peer-endpoint-memory Specification

## Purpose
Lets paired devices find each other again without mDNS: the core remembers where each trusted peer was last reached, dials those addresses when discovery finds nothing, lets the user dial a trusted peer at an address they type, and reports this device's own sync addresses so the user knows what to type.

## Requirements

### Requirement: Last-known endpoints are remembered per trusted peer
Whenever an authenticated sync session with a trusted peer is established, in either direction, the application SHALL durably record in the installation's control store the socket address (IP and port) the session was established on, together with the time of that success. An address SHALL be recorded only when the device's address policy admits it as a dialable peer address. Recording the same address again SHALL update its success time. At most 3 addresses SHALL be kept per peer; when a fourth is recorded, the address with the oldest success time SHALL be dropped. A write for the same peer and address SHALL be skipped when the stored success time is less than 5 minutes old, so repeated sessions produce a bounded number of writes. Addresses SHALL NOT be recorded for a device that is not currently trusted.

#### Scenario: Session establishes a remembered address
- **WHEN** a trusted peer at `192.168.0.165:47380` completes an authenticated sync session with this device
- **THEN** the control store holds `192.168.0.165:47380` for that peer with the session's establishment time as its last success

#### Scenario: Inbound session is remembered too
- **WHEN** a trusted peer dials this device and the session authenticates from `192.168.0.40:47381`
- **THEN** `192.168.0.40:47381` is remembered for that peer

#### Scenario: Oldest address is dropped
- **WHEN** a peer already has three remembered addresses and a session is established on a fourth address
- **THEN** the peer has three remembered addresses: the new one and the two most recent of the previous ones

#### Scenario: Non-LAN address is not remembered
- **WHEN** a session reports a loopback address for a peer while the transport is bound to `0.0.0.0`
- **THEN** nothing is recorded for that address

### Requirement: Remembered endpoints are dial candidates
At open, the application SHALL load every remembered address of every trusted peer whose last success is less than 14 days old into its endpoint registry as a remembered endpoint, and SHALL discard older rows from the control store. A remembered endpoint SHALL expire 14 days after its last success. Remembered endpoints SHALL rank below every endpoint learned from discovery or from a live session, SHALL be eligible only when the address policy admits their address, and SHALL follow the same bounded failure backoff as other endpoints. When one address is known both from discovery and from memory, one connection attempt SHALL dial it at most once. When networking becomes active after open, and whenever networking returns to the foreground, the application SHALL start a connection attempt for every trusted peer with no live session that has an eligible endpoint, remembered endpoints included, without waiting for discovery. Discoverable off SHALL NOT stop dialing remembered endpoints; Sync with paired devices off SHALL stop it as it stops all automatic dialing. A successful session on a remembered address SHALL refresh its success time.

#### Scenario: Peer found without mDNS
- **WHEN** the application opens, mDNS resolves nothing, and a trusted peer was last reached at `192.168.0.165:47380` three days ago
- **THEN** a connection attempt to `192.168.0.165:47380` starts without user action and, if the peer is there, the peers sync

#### Scenario: Fresh discovery wins
- **WHEN** a peer has a remembered address `192.168.0.165:47380` and discovery resolves it at `192.168.0.170:47380`
- **THEN** the next attempt dials `192.168.0.170:47380` first and tries the remembered address only if that dial fails

#### Scenario: Old address expires
- **WHEN** the only remembered address of a peer was last successful 15 days ago
- **THEN** it is not loaded at open, is removed from the control store, and no attempt is made to it

#### Scenario: Unreachable remembered address backs off
- **WHEN** every dial to a peer's remembered address fails
- **THEN** the interval between attempts grows from the minimum to the maximum backoff and the aggregate sync status is `Searching`, not `Error`

#### Scenario: Paused sync does not dial memory
- **WHEN** Sync with paired devices is off at open and a peer has a remembered address
- **THEN** no connection attempt is made to it until sync is turned on

### Requirement: Remembered endpoints follow the device's trust
Revoking a device SHALL remove its remembered addresses from the control store and the endpoint registry in the same operation that revokes it. Deleting a revoked device record SHALL remove any remembered addresses left for it. A dataset reset SHALL remove every remembered address. Re-pairing a device SHALL start with the addresses remembered from its new sessions only.

#### Scenario: Revoke clears memory
- **WHEN** the user revokes a device that had two remembered addresses and the application is restarted
- **THEN** no remembered address exists for that device and no attempt is made to either address

#### Scenario: Reset clears memory
- **WHEN** the dataset is reset
- **THEN** the control store holds no remembered address for any device

### Requirement: Connect a trusted peer by address
The application SHALL provide a command that dials one trusted, non-revoked peer at an address the user supplies. The address SHALL be an IPv4 address with an optional `:port`; without a port the default sync port `47380` SHALL be used. The command SHALL report a typed outcome: connected; invalid address (not an IPv4 address, a host name, or a port outside 1-65535); not a local-network address (the address policy does not admit it, for example a public, loopback, or IPv6 address on an IPv4 LAN bind); or a typed connection failure. The dial SHALL use the same mutual-TLS authentication pinned to that peer's trusted key as every sync dial, so a different device at that address is rejected with a trust or TLS failure and never registered as the peer. The command SHALL be refused for a revoked or unknown device, SHALL fail with the typed paused error while Sync with paired devices is off, SHALL be bounded by the dial timeout, SHALL keep automatic attempts for that peer from starting while it runs, and MUST NOT replace a live session: when the peer is already connected, syncing, or synced the outcome is connected and no dial takes place. A successful connection SHALL remember the address as any authenticated session does.

#### Scenario: Address with default port
- **WHEN** the user connects "Fi f755167e" at `192.168.0.165` and that device listens on `192.168.0.165:47380`
- **THEN** the dial goes to `192.168.0.165:47380`, the session authenticates, the outcome is connected, and `192.168.0.165:47380` is remembered for that peer

#### Scenario: Different device at the address
- **WHEN** the user connects "Fi f755167e" at an address where another paired or unpaired device answers
- **THEN** the outcome is a trust or TLS failure, no session is registered for "Fi f755167e", and nothing is remembered

#### Scenario: Malformed address
- **WHEN** the user supplies `192.168.0` or `phone.local` or `192.168.0.165:70000`
- **THEN** the outcome is invalid address and no dial takes place

#### Scenario: Public address
- **WHEN** the user supplies `8.8.8.8:47380`
- **THEN** the outcome is not a local-network address and no dial takes place

#### Scenario: Nobody answers
- **WHEN** the user supplies a LAN address where nothing listens
- **THEN** the outcome is a route failure within the dial timeout

#### Scenario: Revoked device
- **WHEN** the command is requested for a revoked device
- **THEN** it is refused with a typed error and no dial starts

### Requirement: This device's sync addresses are exposed
The application SHALL expose the addresses at which a trusted peer on the same local network can dial this device: every address the device would advertise for discovery under its address policy, each combined with the bound sync port, as `ip:port`, private IPv4 addresses first and then in ascending order. The list SHALL be computed from the current interfaces each time it is queried, and SHALL be empty while networking has no bound sync port or the device has no LAN-routable address.

#### Scenario: One Wi-Fi address
- **WHEN** the device has the Wi-Fi address `192.168.0.165`, a loopback interface and a container bridge, and sync is bound to UDP `47380`
- **THEN** the query returns exactly `192.168.0.165:47380`

#### Scenario: Networking not running
- **WHEN** the core runs without a bound sync port
- **THEN** the query returns an empty list
