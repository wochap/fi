## Purpose

TBD: Define collection navigation, schema editing, registry-driven field controls, generic forms, and projection-driven refresh.

## Requirements

### Requirement: Collection list and navigation
The Flutter application SHALL show active user-defined collections and open a generic collection screen containing its record list, add action, and schema/settings access.

#### Scenario: Open Headache collection
- **WHEN** the user selects the Headache collection
- **THEN** the screen is constructed from its synchronized schema without a Headache-specific page

### Requirement: Functional schema editor
Flutter SHALL provide create, rename, logical-delete, add-field, edit-field, remove-field, enum-option, and reorder workflows for supported schema metadata, while Rust remains the authoritative validator.

#### Scenario: Rust rejects schema edit
- **WHEN** a submitted field definition violates a core validation rule
- **THEN** the editor remains open and displays the typed field-safe error without local authoritative insertion

### Requirement: Registry-driven field rendering
A Flutter field renderer registry SHALL map supported field kinds to editor and display components, and generic forms MUST NOT use domain-specific Headache or Money implementations.

#### Scenario: Render supported controls
- **WHEN** a schema contains Text, Integer, FixedDecimal, Boolean, Date, DateTime, Duration, and Enum fields
- **THEN** the generic form renders the registered text, numeric, decimal, switch, picker, duration, and selection controls

#### Scenario: Unsupported future field type
- **WHEN** a device reads a field type it cannot render
- **THEN** it shows a non-destructive unsupported-field placeholder and preserves the definition

### Requirement: Generic record CRUD experience
The generated collection experience SHALL create, edit, view, logically delete, and list records using stable field IDs and typed values obtained through the bridge.

#### Scenario: Create Headache record
- **WHEN** the user completes a schema-generated Headache form
- **THEN** Flutter submits a generic typed record command and reloads the projected record after success

#### Scenario: Edit one field
- **WHEN** the user changes one field in an existing record
- **THEN** Flutter submits field-specific updates rather than replacing the record

### Requirement: Exact FixedDecimal editor
The FixedDecimal editor SHALL accept signed decimal text appropriate to the field scale and serialize an exact scaled integer without using binary floating-point as authoritative state.

#### Scenario: Enter Money amount
- **WHEN** the user enters `-23.50` in a scale-two field
- **THEN** the form submits representation `-2350` and displays the projected value as `-23.50`

### Requirement: Sensible record list defaults
The collection screen SHALL select deterministic generic primary/secondary display and ordering defaults from active schema fields, with stable-ID tie breaking when metadata is equal.

#### Scenario: No explicit list configuration
- **WHEN** a new schema has records but no chosen display fields
- **THEN** the UI lists them predictably using active field order and record ID fallback

### Requirement: Reactive projection refresh
Collection and record controllers SHALL react to typed data/projection events by rereading SQLite-backed queries, and stream lag SHALL recover through a complete refresh.

#### Scenario: Remote record arrives
- **WHEN** synchronization advances the projection for the visible collection
- **THEN** its generic record list refreshes without reading Automerge directly
