## Purpose

TBD: Define schema-owned computed field definitions, validation, deterministic source-derived evaluation, null propagation, query access, and isolation of invalid merged definitions.

## Requirements

### Requirement: Stable computed-field definitions
Each computed field SHALL have a stable ID, name, declared output type, versioned expression, ordering, and logical tombstone within one collection schema.

#### Scenario: Rename computed field
- **WHEN** a computed field is renamed
- **THEN** queries referring to its stable ID continue to resolve it

### Requirement: Deterministic source-derived values
Computed fields SHALL derive values from authoritative source record fields and pure deterministic expressions, and their results MUST NOT be synchronized back into Automerge.

#### Scenario: Rebuild computed duration
- **WHEN** SQLite is rebuilt from a record containing started_at and ended_at
- **THEN** the same duration is derived without a synchronized duration value

### Requirement: Computed-field validation
Rust SHALL verify referenced source fields, output type, nullability, scale, temporal semantics, and expression version before accepting a computed-field definition. Computed fields MUST NOT reference other computed fields in this phase.

#### Scenario: Reject declared output mismatch
- **WHEN** an Integer output is declared for a DateTime subtraction expression
- **THEN** validation rejects the definition because the inferred output is Duration

#### Scenario: Reject computed dependency
- **WHEN** a computed expression references another computed field
- **THEN** validation rejects it without needing cycle detection

### Requirement: Null propagation
Computed fields SHALL preserve expression null semantics and SHALL not invent defaults for absent optional inputs.

#### Scenario: Ongoing headache
- **WHEN** ended_at is Null
- **THEN** computed duration is Null

### Requirement: Query access to computed fields
Validated collection queries SHALL be able to filter, sort, select, or aggregate computed fields when the inferred type supports the requested operation.

#### Scenario: Sort by derived duration
- **WHEN** a record-set query sorts by computed headache duration
- **THEN** non-null derived durations are ordered deterministically under the query's null-order policy

### Requirement: Invalid merged computed-field isolation
Structurally preserved computed definitions that become invalid after synchronization SHALL produce typed diagnostics and unavailable computed values without preventing source records from being projected or edited.

#### Scenario: Source field concurrently removed
- **WHEN** a computed definition synchronizes concurrently with logical removal of its source field
- **THEN** the definition and source record data remain preserved while evaluation reports the invalid dependency

### Requirement: Pre-commit expression inference
The core SHALL expose a read-only operation that, given a collection ID and a candidate computed-field expression, resolves referenced source fields against the active schema and returns either the inferred output type and nullability or the typed, path-addressed validation error, using the same inference rules that `validate_computed_field` applies at commit time. The operation MUST NOT persist anything and MUST reject computed-field references and contextual time nodes exactly as commit-time validation does.

#### Scenario: Inference for a valid multiplication
- **WHEN** a client submits `amount * rate` where `amount` is a required scale-two FixedDecimal and `rate` is an optional scale-three FixedDecimal
- **THEN** the core returns output type FixedDecimal with scale five and nullable true, and nothing is written

#### Scenario: Inference surfaces the commit-time error
- **WHEN** a client submits `amount + count` where `amount` is FixedDecimal and `count` is Integer
- **THEN** the core returns the validation error at path `$` with the same message that a `CreateComputedField` command for that expression would produce

#### Scenario: Inference rejects computed references
- **WHEN** a client submits an expression whose `Field` node references a computed field
- **THEN** the core returns the "computed fields may reference source fields only" error at that node's path

### Requirement: In-place computed-field update
A computed-field definition SHALL be updatable under its existing stable ID with a new name, expression, declared type and nullability, subject to the same validation as creation, and consumers that reference the ID SHALL observe the new definition after projection without re-binding.

#### Scenario: Edit expression of a referenced field
- **WHEN** a computed field referenced by a saved query has its expression changed from `abs(amount)` to `amount * 2` and the update validates
- **THEN** the saved query continues to reference the same ID and its next execution uses the new expression

#### Scenario: Edit that changes the inferred type
- **WHEN** an update changes an expression whose inferred type is FixedDecimal to one whose inferred type is Duration, and the submitted declared type is the new inferred type
- **THEN** the update is accepted and the definition's declared type becomes Duration

### Requirement: Term-based computed-field editor
The computed-field editor SHALL present the expression as a sequence of term cards joined by operators (mock computed-field-editor). Each term card SHALL offer a choice between "Field", "Number" and "Function", a drag handle and a remove (✕) action; the first term SHALL carry no operator. "Function" SHALL offer only "Absolute value" and "Divide"; Divide SHALL show an output scale and a rounding choice between "Half to even" and "Reject inexact". An "Add term" button SHALL append a term. Dragging a term SHALL move it within its chain of terms and keep the operators in their positions. Under the terms a result line SHALL show the inferred type with a check icon, followed by " · may be empty" when the result is nullable. When inference reports an error, the term at the error's path SHALL be outlined with a dashed accent border and show the error message under it with a warning icon, the result line SHALL be hidden, and Save SHALL be unavailable until the error is resolved. No other functions SHALL be offered.

#### Scenario: Duration result
- **WHEN** the user builds "End at − Start at" from two Date & time fields, one of them optional
- **THEN** the result line reads "Result: Duration · may be empty" with a check icon and Save is available

#### Scenario: Error on a term
- **WHEN** the user replaces "Start at" with the Text field "Note"
- **THEN** the "Note" term is outlined with "Can't subtract a Text from a Date & time." under it and Save is unavailable

#### Scenario: Divide function
- **WHEN** the user chooses Function › Divide on a term
- **THEN** the term shows an output scale input and the choice "Half to even" / "Reject inexact"
