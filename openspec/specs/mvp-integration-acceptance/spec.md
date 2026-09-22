## Purpose

TBD: Define end-to-end acceptance coverage for projection recovery, peer synchronization and authorization, pairing and discovery, joining and restart behavior, and supported platforms.

## Requirements

### Requirement: Projection recovery acceptance
The end-to-end suite SHALL prove generic schema and record command projection, complete recovery after read-model deletion, and complete recovery from a stale projection checkpoint.

#### Scenario: Local command to query model
- **WHEN** a schema or record command is executed through application core
- **THEN** its durable Automerge change and matching typed SQLite query rows/checkpoint are observed

#### Scenario: Read model is deleted
- **WHEN** a populated application's `read-model.sqlite` is removed and the app restarts
- **THEN** all schemas, records, values, and diagnostics are rebuilt from Automerge

#### Scenario: Checkpoint is stale
- **WHEN** SQLite contains valid rows with heads older than the authoritative root
- **THEN** startup replaces them with a complete current generic projection

### Requirement: Widget projection recovery acceptance
Deleting or invalidating `read-model.sqlite` SHALL rebuild widget and query definitions and reproduce widget evaluation results from Automerge.

#### Scenario: Rebuild configured dashboard
- **WHEN** a populated dashboard's read model is deleted and the application restarts
- **THEN** widget definitions, order, configuration, and query results equal their pre-deletion state

### Requirement: Quinn convergence acceptance
The end-to-end suite SHALL prove two application-core instances synchronize generic schemas and records through real Quinn streams, converge concurrent offline changes, and preserve trusted identity across endpoint changes.

#### Scenario: Real Quinn synchronization
- **WHEN** two compatible trusted cores connect through loopback Quinn
- **THEN** Repo roots, collection schemas, records, and SQLite query results converge

#### Scenario: Concurrent offline records
- **WHEN** both cores add distinct records while disconnected and reconnect
- **THEN** both retain both records and identical Automerge heads

#### Scenario: Concurrent record fields
- **WHEN** disconnected cores edit different fields and then the same field of a synchronized record
- **THEN** different-field edits compose and same-field visible values converge by application HLC

#### Scenario: Peer endpoint changes
- **WHEN** a trusted peer restarts Quinn on a different socket address
- **THEN** its pinned DeviceId remains trusted and generic synchronization resumes through the new endpoint

### Requirement: Peer authorization acceptance
The end-to-end suite SHALL prove unknown and revoked public-key identities cannot enter Repo synchronization.

#### Scenario: Unknown peer is rejected
- **WHEN** an unpaired key connects to the normal sync ALPN
- **THEN** neither core's Repo observes an authenticated peer event

#### Scenario: Revoked peer is rejected
- **WHEN** a formerly trusted key connects after local revocation
- **THEN** the connection is closed before Repo synchronization

### Requirement: Pairing acceptance
The end-to-end suite SHALL prove successful transcript-bound SAS pairing, rejection with no trust, and timeout cleanup.

#### Scenario: Successful SAS pairing
- **WHEN** both devices compare and confirm matching derived SAS values
- **THEN** both persist the expected peer trust and can establish a pinned normal connection

#### Scenario: Pairing is rejected
- **WHEN** either side rejects the SAS
- **THEN** no new trust record or provisioned discovery secret exists on either side

#### Scenario: Pairing times out
- **WHEN** confirmations do not complete before the controlled deadline
- **THEN** candidates, transient keys, sessions, and uncommitted journal data are cleaned up

### Requirement: Discovery isolation acceptance
The end-to-end suite SHALL prove two installations with independent discovery-group secrets do not intentionally discover, connect, or synchronize with one another.

#### Scenario: Independent groups share one LAN harness
- **WHEN** both advertise normal discovery simultaneously
- **THEN** neither maps the other's selector/token to a trusted DeviceId or starts a sync connection

### Requirement: Joining-device acceptance
The end-to-end suite SHALL prove a rootless installation receives the existing root through successful pairing and obtains its complete authoritative and projected data.

#### Scenario: Join populated root
- **WHEN** a fresh device pairs with a ready device containing collection schemas and records
- **THEN** it uses the same root ID, synchronizes complete data, rebuilds SQLite, and only then permits commands

### Requirement: Restart acceptance
The end-to-end suite SHALL prove a complete application restart preserves authoritative generic data, HLC resolution, root bootstrap, permanent identity, trust/revocation records, discovery epoch, and reconstructible queries.

#### Scenario: Both application cores restart
- **WHEN** paired synchronized applications shut down and reopen from retained storage
- **THEN** they retain identities, trust, schemas, records, resolved values, and can synchronize new changes

### Requirement: Generic Headache dashboard acceptance
The end-to-end suite SHALL prove a schema, computed/query definitions, widget definitions, and records created on different trusted devices synchronize and drive generic CRUD and dashboard results.

#### Scenario: Headache schema and widgets cross devices
- **WHEN** Device A creates the Headache schema with started_at, optional ended_at, intensity 1 through 10, optional notes, Average Intensity, and Intensity History and synchronizes
- **THEN** Device B renders generic CRUD plus AggregateNumber and LineChart from the synchronized definitions without Headache-specific code

#### Scenario: Headache record returns to creator
- **WHEN** Device B adds a valid headache record and synchronizes
- **THEN** Device A projects the record and updates both Headache widgets from SQLite-backed query evaluation

### Requirement: Generic Money Movement dashboard acceptance
The end-to-end suite SHALL prove signed FixedDecimal Money Movement records and Balance configuration synchronize while exact aggregation remains integer based.

#### Scenario: Exact synchronized Balance
- **WHEN** records contain scale-two representations `350000`, `-90000`, and `-2350`
- **THEN** Balance returns internal representation `257650`, displays `2576.50`, and uses no binary floating-point authoritative aggregation

### Requirement: Unsupported widget compatibility acceptance
The end-to-end suite SHALL prove a device without a widget implementation preserves an unknown synchronized definition and continues operating the collection.

#### Scenario: Unknown widget on older device
- **WHEN** a device receives `com.example.future-widget`
- **THEN** it displays an unsupported placeholder, preserves the definition through unrelated edits and resynchronization, and continues rendering supported widgets

### Requirement: Supported platform acceptance
The project SHALL include Android foreground integration checks and a Linux desktop build/smoke check that does not rely on X11-specific application behavior.

#### Scenario: Android foreground smoke
- **WHEN** the generic collection app runs foregrounded on a supported Android test environment
- **THEN** secure identity, multicast discovery capability, pairing discovery, collection CRUD, and Quinn connectivity can initialize and stop with lifecycle

#### Scenario: Linux Wayland smoke
- **WHEN** the Flutter Linux application runs in a Wayland-capable test environment
- **THEN** its collection, schema, record, pairing, and device screens initialize without application-level X11 APIs

### Requirement: Multi-homed discovery acceptance
The end-to-end suite SHALL prove that discovery selects peer-routable addresses on a multi-homed host. Assertions SHALL be made on the resolved address values, not solely on whether pairing completed, because a single-host run cannot distinguish correct address selection from loopback succeeding by accident.

#### Scenario: Single-host address resolution harness
- **WHEN** two discovery instances with separate data directories run on one multi-homed host, one registering and one browsing
- **THEN** the harness records every resolved address and fails if the address selected for the peer is a loopback or host-local virtual address

#### Scenario: One device resolves once
- **WHEN** a registering host publishes more than one address for a single pairing instance
- **THEN** the browsing host resolves one candidate for that instance rather than one candidate per address

#### Scenario: Two-machine pairing confirmation
- **WHEN** two separate machines pair over real mDNS and QUIC on the same local network
- **THEN** the joining device discovers, dials, and completes pairing using an address reachable across machines, and any host firewall configuration required to achieve this is recorded

#### Scenario: In-memory transport is not evidence
- **WHEN** discovery address selection is assessed
- **THEN** results from suites running over an in-memory transport are not admitted as evidence for or against real mDNS and QUIC behaviour

### Requirement: Local multi-instance isolation acceptance
The project SHALL support running more than one application instance on a single host against separate datasets, so that multi-device behaviour can be exercised locally. The override that enables this SHALL NOT be reachable in a release build.

#### Scenario: Two instances on one host
- **WHEN** two application instances start on one host with distinct data directories
- **THEN** each opens its own dataset and neither adopts the other's already-initialized core

#### Scenario: Default location is unchanged
- **WHEN** no override is supplied
- **THEN** the application uses the platform application-support directory exactly as before

#### Scenario: Release build ignores the override
- **WHEN** a release build starts with the override present in its environment
- **THEN** the override has no effect and the platform application-support directory is used

### Requirement: Onboarding join reachability acceptance
The widget-level suite SHALL prove that a rootless installation can reach and complete the join flow
through its onboarding entry point alone, without creating a local dataset and without any
out-of-band action.

#### Scenario: Join is reachable from a fresh installation
- **WHEN** the application starts on a device with no local dataset
- **THEN** the onboarding surface offers a pairing entry point that is actionable, and reaching it does
  not require creating a dataset first

#### Scenario: Joining surface names the provisioner
- **WHEN** a rootless device confirms the SAS and the bootstrap state advances to joining
- **THEN** the rendered joining surface names the provisioning device and the pairing controller that
  drove the confirmation is still alive

#### Scenario: Create is blocked during pairing
- **WHEN** pairing mode is active on the onboarding surface
- **THEN** creating a dataset is unavailable with the reason stated, and stopping pairing makes it
  available again

### Requirement: Desktop revocation rotation acceptance
The suite SHALL prove that revoking a trusted device completes discovery-secret rotation on the
shipping desktop keystore path, and that a rotation failure does not leave the revocation unreported
or half-applied.

#### Scenario: Rotation completes on the desktop keystore
- **WHEN** a trusted device is revoked using the shipping desktop keystore implementation
- **THEN** the epoch advances, the previous secret is retained for the bounded migration window, and
  remaining trusted devices receive the new secret

#### Scenario: Rotation failure is reported distinctly
- **WHEN** retention is unavailable and rotation therefore fails after revocation committed
- **THEN** the device is still reported and presented as revoked, and the rotation failure is surfaced
  as a separate retriable condition


### Requirement: Reset-then-join acceptance
Two installations that each created their own root SHALL be able to converge after one of them resets and joins the other through pairing.

#### Scenario: Two rooted devices converge
- **WHEN** device A resets its dataset and then pairs with device B from onboarding
- **THEN** A joins B's root, reaches `Ready`, and B's records are visible on A

### Requirement: Crash-interrupted reset acceptance
An installation whose reset is interrupted at any step SHALL open successfully in `NeedsDecision` on the next start.

#### Scenario: Interruption between every step
- **WHEN** a reset is interrupted after each of: intent written, secrets removed, snapshots removed, read model removed
- **THEN** each subsequent open completes the reset and reports `NeedsDecision` with no inconsistency error

### Requirement: Schema-cliff reset acceptance
An installation whose root carries an unsupported application schema version SHALL be recoverable to `NeedsDecision` through the reset affordance.

#### Scenario: Reset from the error surface
- **WHEN** initialization fails with an unsupported schema version and the user confirms reset from the error surface
- **THEN** the installation reopens in `NeedsDecision` with the same `DeviceId`
