## Purpose

TBD: Define synchronized declarative query definitions, schema-aware validation, filtering and sorting, exact checked aggregations, calendar bucketing, limits, typed result shapes, and safe projected execution.

## Requirements

### Requirement: Synchronized declarative query definitions
Each query definition SHALL have a stable UUIDv7 `QueryId`, owning collection ID, name, versioned structured plan, ordering, and logical tombstone, and SHALL synchronize through the existing Automerge root without storing executable code.

#### Scenario: Query synchronizes
- **WHEN** Device A creates a valid query and synchronizes with Device B
- **THEN** Device B projects the same ID and structured definition

### Requirement: Schema-aware query validation
Rust SHALL validate filters, grouping, aggregation, sorting, limits, field membership, result shape, calendar policy, and all contained expressions before accepting a local query definition or execution request.

#### Scenario: Reject Sum over Text
- **WHEN** a query requests Sum for a Text field
- **THEN** Rust returns a typed validation error and does not persist the query

### Requirement: Filtering and sorting
Queries SHALL support typed filtering expressions and deterministic ascending or descending sorting by compatible source or computed values, with record ID as the final tie-breaker.

#### Scenario: Filter severe headaches
- **WHEN** a query filters intensity greater than or equal to seven and sorts by started_at ascending
- **THEN** only matching records are returned in deterministic timestamp-and-ID order

### Requirement: Checked aggregations
Queries SHALL support Count, Sum, Average, Min, and Max. Sum SHALL use checked compatible integer arithmetic; Average SHALL require explicit output scale and rounding policy when its result may be inexact; and no authoritative aggregation SHALL use binary floating-point.

#### Scenario: Count records
- **WHEN** Count evaluates over three filtered active records
- **THEN** it returns Integer three

#### Scenario: Exact Money balance
- **WHEN** Sum evaluates scale-two values `350000`, `-90000`, and `-2350`
- **THEN** it returns exact representation `257650` at scale two

#### Scenario: Average with explicit policy
- **WHEN** Average evaluates intensity values using declared output scale and HalfEven rounding
- **THEN** it returns the deterministically rounded scaled-integer result and declared scale

#### Scenario: Aggregate overflow
- **WHEN** a Sum exceeds the supported signed representation
- **THEN** query execution returns a typed overflow error

### Requirement: Calendar bucketing
Queries SHALL group compatible Date or DateTime values by Day, Week, Month, or Year using a persisted IANA timezone and week-start policy. One captured UTC time SHALL govern all current-period expressions in an execution.

#### Scenario: Monthly grouping
- **WHEN** records are grouped by month(timestamp) in the query's timezone
- **THEN** every record is assigned to one deterministic calendar-month key

#### Scenario: Week boundary
- **WHEN** ISO Monday week-start is configured
- **THEN** dates around Sunday/Monday are assigned according to ISO week boundaries on every device

### Requirement: Query limits
Record-set and series queries SHALL support a validated positive bounded limit applied after semantic filtering and ordering unless an equivalent safe pushdown is proven.

#### Scenario: Latest records
- **WHEN** a query sorts by DateTime descending and requests the first ten
- **THEN** it returns at most ten latest records with deterministic ID tie-breaking

### Requirement: Typed result shapes
Query execution SHALL return one of Scalar, ordered Series, CategorySeries, or RecordSet with exact typed values and enough metadata to format FixedDecimal results without guessing scale.

#### Scenario: Intensity history
- **WHEN** a query selects started_at as X and intensity as Y ordered by started_at
- **THEN** it returns an ordered Series with DateTime X values and Integer Y values

### Requirement: Safe projected execution
The query service SHALL read SQLite only, generate SQL exclusively from whitelisted templates with bound parameters, and perform precision-sensitive or non-equivalent semantics in Rust. It MUST NOT execute SQL text supplied by a user or synchronized definition.

#### Scenario: Text resembling SQL
- **WHEN** a Text constant contains SQL syntax
- **THEN** it is treated only as a bound value and cannot alter the generated statement

### Requirement: Pure and projected evaluator equivalence
Operations pushed into SQLite and operations evaluated in Rust SHALL follow one tested semantic contract, and rebuilding the projection at unchanged Automerge heads MUST NOT change results.

#### Scenario: Query after rebuild
- **WHEN** the read model is deleted and rebuilt
- **THEN** filter, sort, grouping, and aggregation results equal those returned before deletion

### Requirement: Invalid merged query isolation
A query definition that becomes invalid through concurrency or unsupported versioning SHALL be preserved with a diagnostic, SHALL fail evaluation with a typed error, and MUST NOT prevent other queries or record lists from working.

#### Scenario: Referenced field concurrently removed
- **WHEN** a query and field removal merge into an invalid definition
- **THEN** the query remains inspectable, reports the missing field, and unrelated collection queries still execute
