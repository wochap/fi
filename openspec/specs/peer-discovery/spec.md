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
