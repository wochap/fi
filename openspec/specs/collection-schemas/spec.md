## Purpose

TBD: Define versioned synchronized collection schemas, stable identities, validation, evolution, ordering, and logical deletion.

## Requirements

### Requirement: Versioned synchronized collection schemas
The authoritative Automerge root SHALL contain a versioned generic application model with collection schemas keyed by canonical UUIDv7 `CollectionSchemaId` values, and schemas MUST synchronize through the existing Repo protocol.

#### Scenario: Create schema on one device
- **WHEN** Device A creates a collection schema while connected or later reconnects
- **THEN** Device B receives the same schema ID and definition through ordinary Automerge synchronization

### Requirement: Stable field and enum identities
Every field and enum option SHALL have a globally unique stable ID independent of its display name, and records MUST refer to those IDs rather than names or labels.

#### Scenario: Rename field
- **WHEN** a field is renamed after records contain values for its `FieldId`
- **THEN** those values remain associated with the renamed field

#### Scenario: Rename enum option
- **WHEN** an enum option label is renamed
- **THEN** records referencing its `EnumOptionId` display the new label without changing their stored value

### Requirement: Supported field definitions
Field definitions SHALL support Text, Integer, FixedDecimal with scale, Boolean, Date, DateTime, Duration, and Enum types plus requiredness, optional default, applicable validation metadata, display metadata, deterministic order, and logical deletion. Multiline text SHALL be represented as Text display metadata.

#### Scenario: Add every supported field type
- **WHEN** a user adds one valid field of every supported type
- **THEN** the schema round-trips through Automerge and projection without losing type or metadata

#### Scenario: Future field type
- **WHEN** field-type serialization is extended with a future type
- **THEN** existing records remain keyed by stable schema and field IDs without requiring a new per-schema Rust record type

### Requirement: Schema validation before mutation
Rust application-core commands SHALL validate names, field types, scale bounds, defaults, min/max constraints, enum membership metadata, duplicate identities, and command targets before committing authoritative schema changes.

#### Scenario: Invalid field definition
- **WHEN** a field default has the wrong type or its minimum exceeds its maximum
- **THEN** the command returns a typed validation error and commits neither Automerge nor projection changes

### Requirement: Safe schema evolution
Schema commands SHALL support collection create, rename, logical delete, field add/update/logical removal/reorder, and enum option maintenance. A field base type or FixedDecimal scale MUST NOT change once active records contain a value for that field. A required constraint MAY be introduced or a default removed while active records lack the field; the command SHALL be accepted, and each active record lacking the field SHALL be projected as invalid with a typed missing-required diagnostic until it is repaired or the constraint is relaxed. When the field carries a default, the default SHALL continue to satisfy the constraint for records lacking the field.

#### Scenario: Remove field logically
- **WHEN** a populated field is removed
- **THEN** the field is hidden from ordinary editing while its definition and existing authoritative record values remain recoverable

#### Scenario: Unsafe type change
- **WHEN** a user attempts to change the type or decimal scale of a populated field
- **THEN** Rust rejects the command without modifying the schema

#### Scenario: Required introduced over records lacking the field
- **WHEN** a field with no default is added as required, or an existing optional field without a default is made required, while active records in the collection lack a value for it
- **THEN** the schema command commits, those records are projected with `valid = false` and a missing-required diagnostic naming the field, records that already hold a value remain valid, and unrelated collections are unaffected

#### Scenario: Required introduced with a default
- **WHEN** a field is added as required with a valid default while active records lack it
- **THEN** the schema command commits and those records remain valid because the default satisfies the constraint on read

#### Scenario: Invalid record repaired
- **WHEN** a record marked invalid for a missing required field receives a value for that field through an ordinary field update
- **THEN** the record is projected as valid with no missing-required diagnostic

### Requirement: Deterministic schema ordering
Fields and enum options SHALL have explicit order metadata and SHALL be presented using the stable ID as a final tie-breaker so concurrent reorder operations converge deterministically.

#### Scenario: Concurrent equal order
- **WHEN** synchronization yields two active fields with the same order value
- **THEN** all devices display them in the same ID-tiebroken order without dropping either field

### Requirement: Logical collection deletion
Collection deletion SHALL set a monotonic tombstone, SHALL hide the collection and its records from ordinary lists, and MUST NOT destructively remove its fields or records.

#### Scenario: Delete populated collection
- **WHEN** a user deletes a collection containing records
- **THEN** the collection disappears from active lists while its authoritative schema and records remain tombstoned and reconstructible

### Requirement: Temporal value semantics
A Date value SHALL be a calendar day without a timezone, stored as a signed count of days since 1970-01-01, and MUST NOT be shifted by any timezone when stored, read, or displayed. A DateTime value SHALL be an instant, stored as signed milliseconds since the Unix epoch in UTC; clients SHALL display it in the device's local timezone and convert local input to UTC before submitting it. Query grouping of these values remains governed by the query's persisted timezone policy.

#### Scenario: Date is the same day everywhere
- **WHEN** a record's Date field is set to 2026-09-24 on a device in UTC-5 and read on a device in UTC+9
- **THEN** both devices show September 24, 2026 and the stored value is the same day count

#### Scenario: DateTime follows the viewer's timezone
- **WHEN** a DateTime field is set to 2026-09-24 23:00 on a device in UTC-5
- **THEN** the stored value is the instant 2026-09-25 04:00 UTC, and a device in UTC+9 shows 2026-09-25 13:00
