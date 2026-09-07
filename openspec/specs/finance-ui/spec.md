## Purpose

TBD: Define the native Flutter finance UI, onboarding, transaction and category workflows, responsive presentation, and truthful local status behavior.

## Requirements

### Requirement: Root onboarding
The Flutter application SHALL route a fresh installation to onboarding that offers explicit new-dataset creation and explains joining, and MUST NOT show enabled finance-entry actions before Rust reports a ready root.

#### Scenario: Fresh installation
- **WHEN** application initialization returns `NeedsDecision`
- **THEN** the UI shows onboarding instead of transaction data entry

#### Scenario: Root becomes ready
- **WHEN** explicit root creation completes
- **THEN** the UI enters the finance shell and loads categories and transactions through bridge queries

### Requirement: Transaction list and filtering
The application SHALL show active transactions in deterministic order with occurrence date, category presentation, description, signed amount, search, category filter, and date filter controls.

#### Scenario: Apply filters
- **WHEN** the user supplies search text or category/date filters
- **THEN** the UI requests and displays the corresponding SQLite-backed Rust query result

#### Scenario: Deleted transaction
- **WHEN** a deletion command completes and data-change notification arrives
- **THEN** the default list refresh no longer displays that transaction

### Requirement: Transaction editing workflows
The application SHALL provide create and edit forms that collect date/time, category, signed minor-unit amount through locale-safe text conversion, and description, and SHALL submit explicit Rust commands.

#### Scenario: Successful create
- **WHEN** the user submits valid transaction fields
- **THEN** the command succeeds, the form closes, and the list refreshes from Rust

#### Scenario: Validation failure
- **WHEN** Rust rejects submitted transaction fields
- **THEN** the form remains open and displays the mapped validation error without locally inserting a row

### Requirement: Logical transaction deletion
The transaction UI SHALL require user intent before invoking logical deletion and MUST NOT directly remove or alter SQLite data.

#### Scenario: Confirm deletion
- **WHEN** the user confirms transaction deletion
- **THEN** Flutter invokes the Rust delete command and refreshes only after completion or a data-change event

### Requirement: Category workflows
The application SHALL list active categories and provide create and rename workflows using Rust commands and query refresh.

#### Scenario: Create category
- **WHEN** the user submits a valid category name
- **THEN** the category is created authoritatively through Rust and appears after query refresh

#### Scenario: Rename category
- **WHEN** the user saves a valid new category name
- **THEN** visible transaction category presentation updates from the newly projected query result

### Requirement: Native responsive shell
The UI SHALL run on Android and Linux desktop using adaptive Flutter navigation and MUST NOT depend on X11-specific behavior.

#### Scenario: Linux Wayland launch
- **WHEN** the Flutter Linux executable runs in a Wayland session supported by Flutter
- **THEN** onboarding and finance screens remain usable without application-level X11 APIs

### Requirement: Truthful local status
Before networking is implemented, the UI SHALL display only local readiness/projection states and MUST NOT claim that a peer is connected, syncing, or synchronized.

#### Scenario: Local-only ready application
- **WHEN** the root and projection are ready but no network capability exists
- **THEN** the status presentation reports an offline/local-ready state
