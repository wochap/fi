## Purpose

TBD: Define typed application notifications and bounded actor-owned orchestration for application state and events.

## Requirements

### Requirement: Typed application notifications
The Rust application core SHALL publish distinct typed notifications for collection/schema/record data changes, projection state, application lifecycle state, and operational errors rather than using an untyped event bus.

#### Scenario: Generic domain projection commits
- **WHEN** a projection containing new authoritative collection or record heads commits
- **THEN** subscribers receive a data-changed notification identifying affected kinds or collection IDs and the checkpoint

#### Scenario: Projection fails
- **WHEN** persistence, structural decoding, or SQLite projection fails
- **THEN** subscribers receive a typed error and projection-state notification without a false data-changed event

### Requirement: Widget change notifications
The Rust application core SHALL publish typed widget-change or conservative projection-update notifications only after the authoritative change is durably projected, and notification loss SHALL remain recoverable through widget/query APIs.

#### Scenario: Local widget command commits
- **WHEN** an add, update, remove, or reorder widget command completes successfully
- **THEN** subscribers receive the affected collection/widget scope and committed checkpoint

#### Scenario: Remote widget projects
- **WHEN** synchronization changes widget definitions and the projection commits
- **THEN** subscribers receive a refresh notification without a separate widget synchronization channel

#### Scenario: Widget projection fails
- **WHEN** structural decoding or SQLite projection fails
- **THEN** subscribers receive projection/error state and no false widget-changed event

### Requirement: Retained state and transient events
Current lifecycle and projection status SHALL use retained watch semantics, while discrete data changes and errors SHALL use bounded broadcast semantics with explicit lag behavior.

#### Scenario: Late lifecycle subscriber
- **WHEN** a subscriber attaches after initialization completes
- **THEN** it immediately observes the current retained application state

#### Scenario: Lagging transient subscriber
- **WHEN** a transient-event subscriber falls behind bounded retention
- **THEN** it receives an explicit lag indication and can refresh through query APIs

### Requirement: Actor-owned mutable orchestration
Concurrent mutable application and HLC state SHALL be owned by bounded Tokio tasks and accessed through typed messages or watch/broadcast channels rather than shared ad-hoc mutable globals.

#### Scenario: Concurrent commands
- **WHEN** multiple callers submit schema or record commands concurrently
- **THEN** accepted HLC, Automerge, and projection effects have a deterministic serialized ownership boundary without bypassing Repo document actors
