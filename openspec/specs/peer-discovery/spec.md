## Purpose

Define private endpoint discovery for explicit pairing and trusted-device synchronization without granting trust or exposing permanent identity metadata.

## Requirements

### Requirement: Discovery provider boundary
The Rust application SHALL define a `DiscoveryProvider` that advertises and observes endpoint records for an explicit discovery scope and SHALL keep discovery technology, trust, routing policy, and Repo synchronization separate.

#### Scenario: Provider discovers an endpoint
- **WHEN** a provider resolves a valid service record
- **THEN** it emits an expiring endpoint event without emitting a Repo peer event or granting trust

#### Scenario: Future provider is added
- **WHEN** a future Tailscale provider produces endpoints
- **THEN** existing authentication and Repo synchronization can consume them without protocol or Automerge changes

### Requirement: Explicit expiring pairing discovery
Generic `_myapp-pair._udp.local` advertising and browsing SHALL run only after explicit `start_pairing`, SHALL stop after explicit cancellation or a bounded timeout, and SHALL invalidate discovered candidates when the window closes.

#### Scenario: Pairing is idle
- **WHEN** the user has not started pairing or the window has expired
- **THEN** the device neither advertises nor browses the generic pairing service

#### Scenario: Pairing window expires
- **WHEN** the pairing deadline elapses
- **THEN** advertising, browsing, candidates, and uncommitted pairing sessions are cleaned up automatically

### Requirement: Minimal pairing advertisement
Pairing advertisements SHALL contain only a random pairing instance ID, QUIC port, and protocol version under a random service instance name, and MUST NOT contain permanent DeviceId, public key, friendly/user name, root/document ID, or finance data. The addresses a pairing advertisement carries SHALL be limited to those a remote peer on the same local network can reach, and SHALL NOT include loopback addresses or addresses belonging to host-local container, virtualization, or tunnel bridge interfaces.

#### Scenario: Pairing record is inspected
- **WHEN** another LAN host observes the complete DNS-SD pairing record
- **THEN** it learns only the ephemeral instance ID, port, version, and normal network-layer metadata

#### Scenario: Pairing record from a multi-homed host
- **WHEN** a host with a routable LAN interface, a loopback interface, and a container bridge interface publishes a pairing advertisement
- **THEN** the record carries the routable LAN address and omits the loopback and container-bridge addresses while still revealing no permanent identity

### Requirement: Group-scoped opaque normal discovery
Normal discovery SHALL derive its service selector and per-device routing token from a high-entropy discovery secret and epoch, SHALL advertise no raw DeviceId or friendly name, and SHALL dial only tokens mapped to locally trusted devices. Endpoints resolved from group-scoped records SHALL be addresses the resolving device can actually reach, and one trusted device SHALL resolve to at most one usable endpoint for a given epoch.

#### Scenario: Same discovery group
- **WHEN** two trusted devices possess the same current secret and epoch
- **THEN** each can recognize the other's routing token and resolve a temporary endpoint

#### Scenario: Independent discovery groups
- **WHEN** devices possess different high-entropy discovery secrets
- **THEN** their selectors and tokens differ and they do not intentionally connect or synchronize

#### Scenario: Unmatched group token
- **WHEN** a device observes an opaque token that maps to no locally trusted DeviceId
- **THEN** it ignores the endpoint and does not attempt normal Repo synchronization

#### Scenario: Trusted device publishes several addresses
- **WHEN** a trusted device's group-scoped record resolves to a routable address together with a loopback or container-bridge address
- **THEN** the resolving device records one usable endpoint for that device and does not dial the unreachable address

### Requirement: Discovery establishes endpoints only
Every endpoint learned through pairing or normal discovery SHALL remain unauthenticated until the corresponding QUIC identity checks complete.

#### Scenario: Spoofed advertisement
- **WHEN** an attacker advertises a known routing token from another address but cannot present the pinned key
- **THEN** connection authentication rejects it and the Repo receives no peer event

### Requirement: Normal discovery obeys the Discoverable preference
Group-scoped normal discovery advertising and browsing SHALL run only while the Discoverable preference is on and networking is otherwise active. Every path that would start normal discovery, including core open, foreground resumption, deferred networking retry, pairing completion, and discovery-secret rotation, SHALL leave it stopped while the preference is off. Turning the preference on SHALL start normal discovery with the current secret and epoch. Generic pairing discovery is not governed by this preference.

#### Scenario: Preference off at open
- **WHEN** the core opens in networked mode with Discoverable off
- **THEN** no normal discovery record is advertised and no browse for the normal service is started

#### Scenario: Rotation while off
- **WHEN** Discoverable is off and the discovery-group secret is rotated
- **THEN** the new secret and epoch are stored and the normal service remains stopped

#### Scenario: Pairing discovery while off
- **WHEN** Discoverable is off and the user starts pairing
- **THEN** the generic pairing service is advertised and browsed for the pairing window exactly as when Discoverable is on

### Requirement: Discovery diagnostics events
The discovery subsystem SHALL emit info-level structured events that let a user compare two devices'
discovery state from their logs alone: one when browsing starts for a scope, naming the scope and,
for a group scope, the epoch and service selector; one for every resolved service, naming the scope,
the service instance, the resolved addresses, and the port; and one for every group-scoped record
that is not turned into an endpoint, naming the scope, instance, address, and a `reason` that is
exactly one of `address` (the address is not admissible for dialing or the record has expired),
`selector` (the record's selector matches neither the current nor the retained previous secret),
`token` (the routing token is absent or maps to no device this device knows), or `untrusted` (the
token maps to a known device that is not currently trusted). A rejection with reason `untrusted`
SHALL carry that device's public DeviceId. A record carrying this device's own routing token SHALL
NOT be reported as rejected at info level. None of these events SHALL include a discovery secret.

#### Scenario: Browse starts for the group scope
- **WHEN** normal discovery starts for epoch 4
- **THEN** an info event records the group scope, epoch 4, and the service selector being browsed

#### Scenario: Service resolves
- **WHEN** mDNS resolves a service instance with two addresses
- **THEN** an info event records the scope, the instance name, both addresses, and the port

#### Scenario: Record from a revoked device
- **WHEN** a group record's routing token matches a device whose trust state is revoked
- **THEN** an info event records the record as rejected with reason `untrusted` and that device's
  DeviceId, and no endpoint is produced

#### Scenario: Record from another group
- **WHEN** a resolved group record's selector matches neither the current nor the previous secret
- **THEN** an info event records the record as rejected with reason `selector`

#### Scenario: Unknown routing token
- **WHEN** a group record's routing token maps to no known device
- **THEN** an info event records the record as rejected with reason `token`

#### Scenario: Non-routable address
- **WHEN** a group record resolves to a loopback or container-bridge address
- **THEN** an info event records that address as rejected with reason `address`

#### Scenario: Own advertisement is observed
- **WHEN** the device resolves its own group record
- **THEN** no info-level rejection is emitted for it

### Requirement: Group advertisement names a secret fingerprint
The event recording a group-scoped advertisement SHALL include the epoch, the service selector, and a
fingerprint of the current discovery secret so that two devices' logs show whether they hold the same
secret. The fingerprint SHALL be independent of the epoch and SHALL be identical on every device that
holds the same secret.

#### Scenario: Same secret on two devices
- **WHEN** two devices advertise with the same discovery secret
- **THEN** their advertisement events carry the same fingerprint

#### Scenario: Different secrets
- **WHEN** two devices advertise with different discovery secrets
- **THEN** their advertisement events carry different fingerprints
