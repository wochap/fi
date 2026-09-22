## Purpose

TBD: Define the native Flutter-to-Rust adapter boundary, bootstrap and finance APIs, typed errors and events, and reproducible bridge generation.

## Requirements

### Requirement: Dedicated native bridge adapter
The workspace SHALL contain a dedicated flutter_rust_bridge adapter crate that depends on `app_core`, builds as a native library for Android and Linux, and contains no authoritative domain implementation.

#### Scenario: Bridge dependency graph
- **WHEN** Cargo metadata and bridge source are inspected
- **THEN** `app_bridge` depends on `app_core`, `app_core` remains independently usable, and neither `app_core` nor `automerge_repo` depends on Flutter

### Requirement: Explicit initialization and bootstrap API
The bridge SHALL expose application initialization and explicit create-new-root operations returning typed bootstrap state, and initialization MUST NOT create a root implicitly.

#### Scenario: Fresh bridge initialization
- **WHEN** Flutter initializes the bridge against fresh storage
- **THEN** it receives `NeedsDecision` and no authoritative collection data is created

#### Scenario: Explicit new dataset
- **WHEN** Flutter invokes create-new-root and the operation succeeds
- **THEN** the returned state is ready and subsequent collection queries observe the initialized generic projection

### Requirement: Narrow command and query boundary
The bridge SHALL expose explicit generic collection, record, query-definition, computed-field, and query-execution APIs using FRB-safe owned typed DTOs and canonical string IDs.

#### Scenario: Generic record command
- **WHEN** Dart invokes a record create, field-update, or logical-delete API
- **THEN** the bridge delegates to the corresponding Rust application command and returns only after its documented durable projection boundary

#### Scenario: Generic record query
- **WHEN** Dart requests a collection schema or records
- **THEN** the bridge delegates to the Rust query service and returns owned typed DTOs without exposing SQLite or Automerge handles

#### Scenario: Query definition command
- **WHEN** Dart creates, updates, reorders, or removes a query or computed-field definition
- **THEN** the bridge delegates to a validated Rust application command and returns only after its durable projection boundary

#### Scenario: Execute collection query
- **WHEN** Dart submits a typed query or references a stored `QueryId`
- **THEN** the bridge delegates to the SQLite-backed Rust query service and returns a typed result shape without exposing SQL or Automerge handles

#### Scenario: Unsupported expression DTO
- **WHEN** Dart receives a definition version it cannot construct or edit
- **THEN** the bridge preserves its structured identity and returns a typed unsupported-definition status rather than coercing it

### Requirement: Widget bridge APIs
The bridge SHALL expose typed add, update, remove, reorder, list, get, and evaluate widget APIs using canonical IDs, open string widget types, structured configuration, and typed query result DTOs without exposing Automerge, SQLite, or chart-library objects.

#### Scenario: Evaluate widget
- **WHEN** Dart requests data for a valid widget ID
- **THEN** the bridge delegates to the Rust widget/query service and returns its exact typed result or per-widget typed error

#### Scenario: Unknown widget round trip
- **WHEN** Dart reads an unsupported widget and updates only supported metadata
- **THEN** the bridge preserves the unknown type and structured configuration unchanged

### Requirement: Typed bridge errors
Rust initialization, validation, persistence, projection, lifecycle, and bootstrap failures SHALL cross the bridge as stable typed error categories with safe user-facing messages and stable entity/field context where applicable.

#### Scenario: Invalid dynamic form submission
- **WHEN** Rust rejects a submitted field value
- **THEN** Flutter receives a validation category, target field ID, and safe message rather than a panic or opaque native failure

### Requirement: Typed event streams
The bridge SHALL expose streams for retained application/projection state and transient collection/schema/record change and error events, and stream loss SHALL be recoverable by reopening the stream and refreshing queries. A transient failure of a query used to build a stream emission MUST NOT silently
end the stream; the emission SHALL be skipped and the stream SHALL continue. When a stream does end
unexpectedly, its subscriber SHALL detect the closure and reopen the stream with a query refresh rather
than presenting stale state indefinitely.

#### Scenario: Record changes after subscription
- **WHEN** a projected record command or synchronized record change completes
- **THEN** Dart receives a typed data-changed event and can refresh the affected collection query

#### Scenario: Subscriber is recreated
- **WHEN** a widget or isolate cancels and reopens a status stream
- **THEN** it receives the latest retained state without requiring an application restart

#### Scenario: Query fails transiently
- **WHEN** a query used to build a stream emission fails while the underlying subscription is still live
- **THEN** that emission is skipped, the stream remains open, and the next change produces an emission

#### Scenario: Stream ends unexpectedly
- **WHEN** a bridge stream closes without the subscriber cancelling it
- **THEN** the subscriber reopens the stream and refreshes the associated queries, and long-lived
  application-scoped controllers recover without a screen remount or application restart

### Requirement: Widget event stream
The bridge SHALL expose widget-specific data-change information sufficient for Flutter to refresh affected collection dashboards, with projection refresh remaining the recovery path after lag.

#### Scenario: Remote widget arrives
- **WHEN** a synchronized widget definition reaches the committed projection
- **THEN** Dart receives an event identifying the affected collection or a conservative full-refresh scope

### Requirement: Reproducible generated bridge
The project SHALL pin compatible Flutter/Dart and Rust FRB packages, commit generated bridge artifacts, and provide a command that verifies regeneration produces no unexpected changes.

#### Scenario: Clean code generation
- **WHEN** FRB generation runs in the project development shell
- **THEN** generated Rust and Dart sources match the checked-in API definitions and compile for supported native targets


### Requirement: Dataset reset bridge API
The bridge SHALL expose a reset operation that stops pairing, shuts down the process core if one is live, resets the application-data directory it was initialized with, reopens, and returns the resulting bootstrap state. It SHALL NOT accept a directory path from the caller.

#### Scenario: Reset with a live core
- **WHEN** the reset operation is called while the core is open
- **THEN** it returns a bootstrap state of `NeedsDecision` and subsequent bridge calls operate on the reopened core

#### Scenario: Reset without a live core
- **WHEN** the reset operation is called after initialization failed
- **THEN** it resets the directory that initialization was attempted against and returns `NeedsDecision`

### Requirement: Bridge errors carry reset resolvability
Bridge errors raised from initialization SHALL carry a typed indicator of whether a dataset reset can resolve them.

#### Scenario: Schema error is resolvable
- **WHEN** initialization fails with an unsupported application schema version
- **THEN** the returned bridge error is marked reset-resolvable

#### Scenario: Transient error is not resolvable
- **WHEN** initialization fails because the secure store is locked or the disk is unavailable
- **THEN** the returned bridge error is not marked reset-resolvable
