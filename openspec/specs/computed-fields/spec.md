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
