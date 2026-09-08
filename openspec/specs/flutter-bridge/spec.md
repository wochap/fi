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
The bridge SHALL expose explicit collection, field, enum-option, and generic record commands plus list/get queries using FRB-safe owned typed DTOs and canonical string IDs.

#### Scenario: Generic record command
- **WHEN** Dart invokes a record create, field-update, or logical-delete API
- **THEN** the bridge delegates to the corresponding Rust application command and returns only after its documented durable projection boundary

#### Scenario: Generic record query
- **WHEN** Dart requests a collection schema or records
- **THEN** the bridge delegates to the Rust query service and returns owned typed DTOs without exposing SQLite or Automerge handles

### Requirement: Typed bridge errors
Rust initialization, validation, persistence, projection, lifecycle, and bootstrap failures SHALL cross the bridge as stable typed error categories with safe user-facing messages and stable entity/field context where applicable.

#### Scenario: Invalid dynamic form submission
- **WHEN** Rust rejects a submitted field value
- **THEN** Flutter receives a validation category, target field ID, and safe message rather than a panic or opaque native failure

### Requirement: Typed event streams
The bridge SHALL expose streams for retained application/projection state and transient collection/schema/record change and error events, and stream loss SHALL be recoverable by reopening the stream and refreshing queries.

#### Scenario: Record changes after subscription
- **WHEN** a projected record command or synchronized record change completes
- **THEN** Dart receives a typed data-changed event and can refresh the affected collection query

#### Scenario: Subscriber is recreated
- **WHEN** a widget or isolate cancels and reopens a status stream
- **THEN** it receives the latest retained state without requiring an application restart

### Requirement: Reproducible generated bridge
The project SHALL pin compatible Flutter/Dart and Rust FRB packages, commit generated bridge artifacts, and provide a command that verifies regeneration produces no unexpected changes.

#### Scenario: Clean code generation
- **WHEN** FRB generation runs in the project development shell
- **THEN** generated Rust and Dart sources match the checked-in API definitions and compile for supported native targets
