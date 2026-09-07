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
- **THEN** it receives `NeedsDecision` and no authoritative finance data is created

#### Scenario: Explicit new dataset
- **WHEN** Flutter invokes create-new-root and the operation succeeds
- **THEN** the returned state is ready and subsequent finance queries observe the initialized projection

### Requirement: Narrow command and query boundary
The bridge SHALL expose explicit category and transaction commands plus list, search, filter, and aggregate queries using FRB-safe owned DTOs, canonical string IDs, integer timestamps, and integer minor-unit amounts.

#### Scenario: Transaction command
- **WHEN** Dart invokes a transaction create, update, or delete API
- **THEN** the bridge delegates to the corresponding Rust application command and returns only after its documented durable projection boundary

#### Scenario: Transaction query
- **WHEN** Dart requests transactions with filters
- **THEN** the bridge delegates to the Rust query service and returns owned query DTOs without exposing SQLite or Automerge handles

### Requirement: Typed bridge errors
Rust initialization, validation, persistence, projection, lifecycle, and bootstrap failures SHALL cross the bridge as stable typed error categories with safe user-facing messages.

#### Scenario: Invalid form submission
- **WHEN** Rust rejects a submitted finance value
- **THEN** Flutter receives a validation category and field-safe message rather than a panic or opaque native failure

### Requirement: Typed event streams
The bridge SHALL expose streams for retained application/projection state and transient data-change/error events, and stream loss SHALL be recoverable by reopening the stream and refreshing queries.

#### Scenario: Data changes after subscription
- **WHEN** a projected finance command completes
- **THEN** Dart receives a typed data-changed event and can refresh the affected query

#### Scenario: Subscriber is recreated
- **WHEN** a widget or isolate cancels and reopens a status stream
- **THEN** it receives the latest retained state without requiring an application restart

### Requirement: Reproducible generated bridge
The project SHALL pin compatible Flutter/Dart and Rust FRB packages, commit generated bridge artifacts, and provide a command that verifies regeneration produces no unexpected changes.

#### Scenario: Clean code generation
- **WHEN** FRB generation runs in the project development shell
- **THEN** generated Rust and Dart sources match the checked-in API definitions and compile for supported native targets
