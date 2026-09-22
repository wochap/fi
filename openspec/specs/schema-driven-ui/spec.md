## Purpose

TBD: Define collection navigation, schema editing, registry-driven field controls, generic forms, and projection-driven refresh.

## Requirements

### Requirement: Collection list and navigation
The Flutter application SHALL show active user-defined collections and open a generic collection screen containing its record list, add action, and schema/settings access.

#### Scenario: Open Headache collection
- **WHEN** the user selects the Headache collection
- **THEN** the screen is constructed from its synchronized schema without a Headache-specific page

### Requirement: Functional schema editor
Flutter SHALL provide create, rename, logical-delete, add-field, edit-field, remove-field, enum-option, and reorder workflows for supported schema metadata, while Rust remains the authoritative validator. When the field editor has Required on, no default, and the collection contains active records lacking the field, the editor SHALL show an inline warning stating how many records will become invalid, and the save action SHALL open a confirmation dialog stating that count before the schema command is submitted. The count SHALL be derived from the projected record list already loaded for the collection.

Schema metadata that holds a value of the field's own type — the default and the minimum and maximum bounds — SHALL be edited with the same typed control the record editor uses for that type, never as the raw stored integer, and each such control SHALL offer an explicit unset state because the slot is optional whatever the field requires of records. Changing the field type or the decimal scale SHALL clear those slots rather than reinterpret them.

#### Scenario: Rust rejects schema edit
- **WHEN** a submitted field definition violates a core validation rule
- **THEN** the editor remains open and displays the typed field-safe error without local authoritative insertion

#### Scenario: Required without default over existing records
- **WHEN** the user turns Required on for a field with an empty default while the collection has records lacking that field
- **THEN** an inline warning appears naming the number of records that will become invalid, and it disappears when a default is entered, Required is turned off, or no record lacks the field

#### Scenario: Confirm before making records invalid
- **WHEN** the user taps Save while the inline warning is showing
- **THEN** a confirmation dialog states the number of records that will be marked invalid; confirming submits the schema command and cancelling returns to the editor with values intact

#### Scenario: Default and bounds are typed, not raw
- **WHEN** the user edits the default, minimum, or maximum of a Date, DateTime, or FixedDecimal field
- **THEN** the control is the typed editor for that field — a date picker for a Date, an exact decimal box stating the scale for a FixedDecimal — and the value submitted is the stored integer the bound is compared as, with no epoch number or scaled integer typed by hand

#### Scenario: An optional slot can be left unset
- **WHEN** the field type is Boolean or Enum, or a date default has already been picked
- **THEN** the control offers an explicit unset choice, so a boolean default reads None, True, or False, an enum default is chosen by option label with a None entry, and a picked date can be cleared

#### Scenario: Retyping a field drops metadata typed for the old type
- **WHEN** the user changes the field type, or the decimal scale, after entering a default or a bound
- **THEN** those slots are cleared, so no value is submitted meaning something other than what was typed

#### Scenario: No confirmation when nothing becomes invalid
- **WHEN** the user saves a required field with a default, or a required field in a collection with no records lacking it
- **THEN** the schema command is submitted without a confirmation dialog

### Requirement: Registry-driven field rendering
A Flutter field renderer registry SHALL map supported field kinds to editor and display components, and generic forms MUST NOT use domain-specific Headache or Money implementations.

#### Scenario: Render supported controls
- **WHEN** a schema contains Text, Integer, FixedDecimal, Boolean, Date, DateTime, Duration, and Enum fields
- **THEN** the generic form renders the registered text, numeric, decimal, switch, picker, duration, and selection controls

#### Scenario: Unsupported future field type
- **WHEN** a device reads a field type it cannot render
- **THEN** it shows a non-destructive unsupported-field placeholder and preserves the definition

### Requirement: Generic record CRUD experience
The generated collection experience SHALL create, edit, view, logically delete, and list records using stable field IDs and typed values obtained through the bridge. Records projected as invalid SHALL be visibly marked in the list with an indicator and their diagnostics, and opening such a record for editing SHALL present the missing required field as needing a value.

#### Scenario: Create Headache record
- **WHEN** the user completes a schema-generated Headache form
- **THEN** Flutter submits a generic typed record command and reloads the projected record after success

#### Scenario: Edit one field
- **WHEN** the user changes one field in an existing record
- **THEN** Flutter submits field-specific updates rather than replacing the record

#### Scenario: Invalid record in list
- **WHEN** the record list contains a record with `valid = false` and a missing-required diagnostic
- **THEN** the row shows an invalid indicator and the diagnostic text, and opening it highlights the missing field

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
