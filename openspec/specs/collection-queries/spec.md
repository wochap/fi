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
Queries SHALL support typed filtering expressions and deterministic ascending or descending sorting by compatible source or computed values, or by the record creation time, with record ID as the final tie-breaker.

Sort order by type SHALL be:
- Text: case- and accent-insensitive, comparing a folded key of each value: Unicode canonical decomposition (NFD) with combining marks removed, then simple Unicode lowercase. Ties SHALL be broken by the exact code-point order of the original text. It SHALL NOT be locale-aware and SHALL NOT compare digit runs numerically.
- Boolean: false before true.
- A single-choice (Enum) value: the position of its option in the field's option order, active and removed options keeping their stored position, with the option id breaking ties.
- Integer, FixedDecimal of one scale, Date, DateTime and Duration: by value.
- Record creation time: as DateTime.
- A multi-option Choices (EnumSet) value: not orderable, so it SHALL NOT be a sort key.

These sort orders SHALL NOT change the semantics of comparison operators in filters.

#### Scenario: Filter severe headaches
- **WHEN** a query filters intensity greater than or equal to seven and sorts by started_at ascending
- **THEN** only matching records are returned in deterministic timestamp-and-ID order

#### Scenario: Text ignores case
- **WHEN** a query sorts the Text values "banana", "Apple" and "apple" ascending
- **THEN** the order is "Apple", "apple", "banana"

#### Scenario: Text ignores accents
- **WHEN** a query sorts the Text values "zanahoria", "élite" and "edad" ascending
- **THEN** the order is "edad", "élite", "zanahoria"

#### Scenario: Digit runs compare as text
- **WHEN** a query sorts the Text values "item 10" and "item 2" ascending
- **THEN** the order is "item 10", "item 2"

#### Scenario: Removed option keeps its position
- **WHEN** "type" has the options headache, stomach, migraine in that order, stomach is removed, and a query sorts by "type" ascending
- **THEN** records holding stomach still sort between headache and migraine

#### Scenario: Single choice in option order
- **WHEN** "type" has the options headache, stomach, migraine in that order and a query sorts by "type" ascending
- **THEN** headache records come first, then stomach, then migraine, regardless of the option ids

#### Scenario: Boolean sort
- **WHEN** a query sorts a Boolean field descending
- **THEN** true values come before false values and empty values follow the clause's null order

#### Scenario: Reject multi-option sort
- **WHEN** a query sorts by a multi-option Choices field
- **THEN** validation rejects it as not orderable

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

### Requirement: Grouping by a Choices field
A query SHALL accept a Choices field as a grouping key. Each record SHALL contribute to the group of every option in its set, and a record with an empty set SHALL contribute to the Null group. Groups SHALL be ordered by the field's option order with the option id as tie-breaker, and a removed option SHALL form its own group under its last label. Aggregations SHALL be computed per group over the records in that group, so group totals may add up to more than the ungrouped total.

#### Scenario: Record counted in each group
- **WHEN** Sum of amount is grouped by "tags" over a record "Lunch" 12.50 holding {"food", "work"} and a record 5.00 holding {"food"}
- **THEN** the result is food 17.50 and work 12.50

#### Scenario: Empty set in the Null group
- **WHEN** Count is grouped by "tags" and one record has an empty set
- **THEN** that record is counted in the Null group only
