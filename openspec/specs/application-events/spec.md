## Purpose

TBD: Define typed application notifications and bounded actor-owned orchestration for application state and events.

## Requirements

### Requirement: Typed application notifications
The Rust application core SHALL publish distinct typed notifications for authoritative data changes, projection state, application lifecycle state, and operational errors rather than using an untyped event bus.

#### Scenario: Domain projection commits
- **WHEN** a projection containing new authoritative heads commits
- **THEN** subscribers receive a data-changed notification identifying the affected domain kinds and checkpoint

#### Scenario: Projection fails
- **WHEN** persistence, decoding, or SQLite projection fails
- **THEN** subscribers receive a typed error and projection-state notification without a false data-changed event

### Requirement: Retained state and transient events
Current lifecycle and projection status SHALL use retained watch semantics, while discrete data changes and errors SHALL use bounded broadcast semantics with explicit lag behavior.

#### Scenario: Late lifecycle subscriber
- **WHEN** a subscriber attaches after initialization completes
- **THEN** it immediately observes the current retained application state

#### Scenario: Lagging transient subscriber
- **WHEN** a transient-event subscriber falls behind bounded retention
- **THEN** it receives an explicit lag indication and can refresh through query APIs

### Requirement: Actor-owned mutable orchestration
Concurrent mutable application state SHALL be owned by bounded Tokio tasks and accessed through typed messages or watch/broadcast channels rather than shared ad-hoc mutable globals.

#### Scenario: Concurrent commands
- **WHEN** multiple callers submit finance commands concurrently
- **THEN** accepted command/projection effects have a deterministic serialized ownership boundary without bypassing Repo document actors
