## Purpose

TBD: Define exact fixed-decimal storage, parsing, formatting, arithmetic, and locale boundaries.

## Requirements

### Requirement: Scaled integer representation
FixedDecimal field values SHALL store a signed `i64` integer representation while the non-negative bounded scale belongs to the field definition, and binary floating-point MUST NOT be authoritative.

#### Scenario: Scale-two representation
- **WHEN** a scale-two field stores `-2350`
- **THEN** its exact displayed decimal value is `-23.50`

### Requirement: Exact input parsing
The core SHALL parse signed decimal user input directly into a scaled integer, reject excessive fractional digits unless an explicit rounding operation is requested, and detect overflow.

#### Scenario: Parse negative value
- **WHEN** `-900.00` is parsed for scale two
- **THEN** the resulting authoritative representation is exactly `-90000`

#### Scenario: Reject excess precision
- **WHEN** `1.005` is parsed for scale two without a rounding policy
- **THEN** parsing returns a typed precision error rather than storing an approximation

### Requirement: Exact display formatting
Formatting SHALL derive sign, whole digits, and padded fractional digits from the scaled integer without converting through binary floating-point.

#### Scenario: Format small negative value
- **WHEN** representation `-1` is formatted at scale two
- **THEN** the result is `-0.01`

### Requirement: Checked compatible arithmetic
FixedDecimal addition, subtraction, sum, and comparison SHALL operate on integers with compatible scales and SHALL return typed overflow or incompatible-scale errors instead of wrapping or losing precision.

#### Scenario: Checked Money Movement sum
- **WHEN** values `350000`, `-90000`, and `-2350` at scale two are summed
- **THEN** the result is exactly `257650`

#### Scenario: Sum overflow
- **WHEN** a checked sum exceeds the signed 64-bit representation
- **THEN** evaluation fails with a typed overflow error

#### Scenario: Incompatible scales
- **WHEN** an operation combines scale-two and scale-three values without explicit normalization
- **THEN** the operation is rejected with a typed scale error

### Requirement: Locale separation
Locale-specific separators SHALL be handled only at the input/display boundary, while Rust receives or produces an exact canonical scaled representation.

#### Scenario: Localized entry
- **WHEN** Flutter accepts a locale-specific decimal string
- **THEN** it submits an exact canonical value for Rust validation and never submits a floating-point amount
