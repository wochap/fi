## Purpose

Define which host addresses discovery advertises and which peer addresses are accepted as dialable endpoints, so that multi-homed hosts remain reachable and one device resolves to one usable endpoint.

## Requirements

### Requirement: Advertised addresses are peer-routable
Discovery advertisements SHALL carry only addresses that a remote peer on the same local network can reach, and SHALL NOT carry loopback addresses or addresses belonging to host-local container, virtualization, or tunnel bridge interfaces.

#### Scenario: Multi-homed host advertises
- **WHEN** a host with a routable LAN interface, a loopback interface, and a container bridge interface registers a discovery advertisement
- **THEN** the published record carries the routable LAN address and does not carry the loopback or container-bridge addresses

#### Scenario: Routable address is always preserved
- **WHEN** an advertisement filter is applied on a host with at least one reachable LAN interface
- **THEN** that reachable interface's address remains advertised and the device stays discoverable

#### Scenario: No routable address exists
- **WHEN** a host has no address reachable by a remote peer
- **THEN** the device does not advertise a host-local address as a substitute, and its undiscoverable state is observable rather than silently advertised

### Requirement: One usable endpoint per device per scope
For a single discovery scope, one physical device SHALL resolve to at most one usable endpoint. Where several addresses are observed for one device, resolution SHALL de-duplicate deterministically on the stable per-window instance identity, and any residual multiplicity SHALL be explicit rather than presenting to the user as several distinct devices.

#### Scenario: Peer resolves several addresses
- **WHEN** one browsing device resolves a single remote instance that published multiple addresses
- **THEN** it records one candidate for that instance rather than one candidate per address

#### Scenario: De-duplication is deterministic
- **WHEN** the same set of addresses for one instance is resolved repeatedly
- **THEN** the selected endpoint is the same on every resolution

#### Scenario: Distinct devices are not collapsed
- **WHEN** two different physical devices advertise within the same scope
- **THEN** both remain separately resolvable and separately selectable

### Requirement: Non-routable peer addresses are not dialable
The system SHALL NOT treat a loopback or host-local virtual address received from a remote peer as a dialable endpoint. Where both an advertised address and an address observed from an established connection exist for the same peer, the address used for subsequent connections SHALL be one that the peer has demonstrated it can be reached on.

#### Scenario: Remote peer advertises loopback
- **WHEN** a discovery record from a remote host resolves to a loopback address
- **THEN** the address is not accepted as an endpoint for that peer

#### Scenario: Observed source differs from advertisement
- **WHEN** a peer connection is established from an address other than the one its advertisement published
- **THEN** subsequent connection attempts use the demonstrated-reachable address rather than the unreachable advertised one

### Requirement: Selection adapts to host topology changes
Address selection SHALL be re-evaluated when the host's network topology changes, so that a device which roams between networks becomes discoverable again without an application restart, and addresses belonging to interfaces that no longer exist cease to be advertised.

#### Scenario: Device roams to a different network
- **WHEN** an advertising device moves from one network to another while the application continues running
- **THEN** it advertises an address reachable on the new network without requiring a restart

#### Scenario: Interface disappears
- **WHEN** an interface that was previously advertised is removed from the host
- **THEN** its address is no longer advertised and no longer resolves as an endpoint

#### Scenario: Stale advertisement expires
- **WHEN** an address ceases to be advertised while a previously published record still exists
- **THEN** the record stops resolving as an endpoint no later than its published expiry
