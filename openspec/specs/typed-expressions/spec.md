## Purpose

TBD: Define the versioned serializable expression AST, static validation, checked exact numeric semantics, comparison/boolean/null rules, temporal operations, and contextual isolation of current-period expressions.

## Requirements

### Requirement: Versioned structured expression AST
Expressions SHALL be represented as versioned serializable structured data. They SHALL contain only supported nodes: stable field access, record creation time, typed constants, arithmetic, comparison, boolean logic, null tests, absolute value, and temporal operations. The system MUST NOT execute arbitrary user code or SQL.

The record creation time node SHALL evaluate to the DateTime embedded in the record's time-ordered id. It SHALL be Null when the id carries no timestamp. It SHALL be accepted in query expressions, including filters and sort keys, and in any later expression context that is not a computed field, and SHALL be rejected in computed-field expressions.

#### Scenario: Expression synchronization round trip
- **WHEN** an expression is written to Automerge, projected, synchronized, and read on another device
- **THEN** its node kinds, stable field IDs, constants, and numeric policies are preserved

#### Scenario: Record creation time
- **WHEN** a query sorts by the record creation time node over a record whose UUIDv7 id embeds 2026-09-22 08:30:00.000 UTC
- **THEN** the node evaluates to that DateTime on every device and after a projection rebuild

#### Scenario: Creation time rejected in a computed field
- **WHEN** a computed field's expression uses the record creation time node
- **THEN** validation rejects the definition before persistence

### Requirement: Typed field access and constants
Field access SHALL identify source or supported computed fields by stable IDs, and constants SHALL retain explicit Text, Integer, FixedDecimal scale, Boolean, Date, DateTime, Duration, EnumOption, EnumOptionSet, or Null types as applicable. An EnumOptionSet constant SHALL hold option ids of exactly one EnumSet or Enum field.

#### Scenario: Field renamed after expression creation
- **WHEN** a referenced field is renamed
- **THEN** the expression continues to resolve the same `FieldId`

#### Scenario: Option set constant
- **WHEN** an expression holds an EnumOptionSet constant {"work", "urgent"} of the field "tags"
- **THEN** it round-trips with both option ids and its field

### Requirement: Static expression validation
Before a local definition is committed, Rust SHALL resolve referenced fields in the owning collection, infer output type and nullability, and reject missing/deleted fields or operator/type/scale combinations outside the defined language.

#### Scenario: Reject numeric aggregation input expression over Text
- **WHEN** a numeric expression attempts to add a Text field and Integer constant
- **THEN** validation returns a typed error identifying the invalid expression path

### Requirement: Checked exact numeric expressions
Integer arithmetic and compatible FixedDecimal arithmetic SHALL use checked integer operations. FixedDecimal addition and subtraction require equal scales; multiplication composes scales; division SHALL declare an output scale and `RejectInexact` or `HalfEven` rounding policy. Overflow, incompatible scale, and division by zero MUST be typed errors.

#### Scenario: Exact compatible addition
- **WHEN** two scale-two FixedDecimal values are added without overflow
- **THEN** the result has scale two and the exact checked integer sum

#### Scenario: Inexact division rejected
- **WHEN** division using `RejectInexact` cannot fit the declared output scale exactly
- **THEN** evaluation fails rather than truncating or using binary floating-point

### Requirement: Comparison and boolean semantics
Equal, NotEqual, GreaterThan, GreaterThanOrEqual, LessThan, and LessThanOrEqual SHALL accept only compatible operand types; And, Or, and Not SHALL accept Boolean operands; and evaluation SHALL be deterministic. Equal and NotEqual SHALL NOT accept an EnumSet operand, and ordering comparisons SHALL NOT accept EnumSet or Enum set operands.

HasAnyOf, HasAllOf and HasNoneOf SHALL take an EnumSet field operand and an EnumOptionSet constant of that field, and SHALL return Boolean: HasAnyOf is true when the record's set shares at least one option with the constant, HasAllOf when it holds every option of the constant, and HasNoneOf when it shares none. A Null (empty) record set SHALL make HasAnyOf and HasAllOf false and HasNoneOf true. IsNull and IsNotNull SHALL test a Choices field for an empty or non-empty set.

HasAnyOf and HasNoneOf SHALL also take a single-choice (Enum) field operand with an EnumOptionSet constant of that field, treating the record's value as a set of at most one option: HasAnyOf is true when the value is one of the constant's options, and HasNoneOf when it is not. A Null value SHALL make HasAnyOf false and HasNoneOf true. HasAllOf SHALL NOT accept an Enum operand.

#### Scenario: Reject incompatible comparison
- **WHEN** an expression compares DateTime with Text
- **THEN** validation rejects the definition before persistence

#### Scenario: Has any of
- **WHEN** a filter is "tags has any of {work, urgent}" over records holding {"work"}, {"food"} and the empty set
- **THEN** only the first record matches

#### Scenario: Has all of and has none of
- **WHEN** records hold {"work", "urgent"}, {"work"} and the empty set
- **THEN** "has all of {work, urgent}" matches only the first, and "has none of {urgent}" matches the second and the third

#### Scenario: Equality on a set rejected
- **WHEN** an expression uses Equal with a Choices field operand
- **THEN** validation rejects the definition before persistence

#### Scenario: Single choice is any of
- **WHEN** a filter is "type has any of {headache, migraine}" over records whose type is headache, stomach and empty
- **THEN** only the first record matches, and "type has none of {headache, migraine}" matches the second and the third

#### Scenario: Has all of rejects a single choice
- **WHEN** an expression uses HasAllOf with a single-choice field operand
- **THEN** validation rejects the definition before persistence

### Requirement: Explicit null semantics
Arithmetic or comparison with Null SHALL produce Null, boolean operators SHALL follow documented nullable three-valued logic, filters SHALL retain only explicit true, and `IsNull`/`IsNotNull` SHALL provide explicit null testing.

#### Scenario: Optional duration input absent
- **WHEN** `ended_at` is Null in `ended_at - started_at`
- **THEN** the expression result is Null rather than zero or an error

### Requirement: Temporal expression semantics
DateTime subtraction SHALL produce checked Duration milliseconds, Date subtraction SHALL produce a documented whole-day Duration, and unsupported temporal combinations SHALL be rejected.

#### Scenario: Headache duration
- **WHEN** ended_at is one hour after started_at
- **THEN** the computed expression returns exactly 3,600,000 duration milliseconds

### Requirement: Contextual expression isolation
Current-period boundary nodes SHALL be allowed only in query evaluation with one captured execution time and persisted calendar policy, and MUST be rejected in deterministic computed fields.

#### Scenario: Reject current time in computed field
- **WHEN** a computed-field definition refers to the current month boundary
- **THEN** validation rejects it because its value could change without an authoritative record change
