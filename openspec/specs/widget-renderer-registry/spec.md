## Purpose

TBD: Define the Flutter widget renderer registry boundary, built-in renderer set, unsupported-widget placeholders, chart dependency isolation, presentation-only floating point, and renderer failure containment.

## Requirements

### Requirement: Registry lookup boundary
Flutter SHALL resolve widget definitions through a registry keyed by their open-ended type strings, and adding a compiled renderer MUST NOT require changing persisted schema or query formats.

#### Scenario: Register future renderer
- **WHEN** a future build registers a factory for an existing unsupported type identifier
- **THEN** the preserved widget definition becomes renderable without data migration

### Requirement: Built-in renderer set
The initial registry SHALL include `core.aggregate-number`, `core.line-chart`, `core.bar-chart`, and `core.scatter-plot` with explicit accepted result shapes and typed configuration adapters.

#### Scenario: Resolve built-ins
- **WHEN** the registry receives each core identifier
- **THEN** it returns the corresponding compiled renderer and descriptor

### Requirement: Unsupported widget placeholder
An unknown widget type SHALL render a clear unsupported-widget placeholder containing safe identifying information and MUST NOT delete, rewrite, or fabricate support for its definition.

#### Scenario: Unknown synchronized widget
- **WHEN** a device receives `com.example.future-widget` without a registered factory
- **THEN** it shows an Unsupported widget card while preserving the complete definition

### Requirement: Chart dependency isolation
Line, bar, and scatter rendering SHALL be isolated behind application renderer adapters so persisted definitions, Rust result DTOs, and generic dashboard code do not depend on chart-library classes.

#### Scenario: Replace chart library
- **WHEN** the internal chart dependency is changed in a later build
- **THEN** existing widget definitions and query results require no migration

### Requirement: Presentation-only floating point
Exact Integer and FixedDecimal data SHALL cross Rust and FRB without binary floating-point conversion. Chart adapters MAY convert values to drawing coordinates, but labels and AggregateNumber formatting MUST use exact typed source values.

#### Scenario: Money balance formatting
- **WHEN** AggregateNumber receives representation `257650` at scale two
- **THEN** it displays `2576.50` without computing the aggregate through floating point

### Requirement: Renderer failure containment
Renderer configuration or drawing failures SHALL be contained to a stable per-widget error surface and MUST NOT crash the dashboard.

#### Scenario: Malformed preserved configuration
- **WHEN** a built-in renderer receives configuration it cannot decode after a concurrent merge
- **THEN** the widget shows a configuration error while other widgets remain usable
