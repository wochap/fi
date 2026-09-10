## Purpose

TBD: Define generic collection dashboard composition, guided widget configuration, built-in visualization presentations, responsive simple layout, and reactive dashboard refresh.

## Requirements

### Requirement: Collection dashboard composition
The generic collection screen SHALL present its active widgets in deterministic order together with the record list and add-record action, driven entirely by synchronized schema, query, and widget definitions.

#### Scenario: Open configured collection
- **WHEN** a user opens a collection with active widgets
- **THEN** the screen evaluates and renders the dashboard above or alongside its generic record list according to responsive layout

### Requirement: Guided widget configuration
Flutter SHALL provide guided add, type choice, title, query selection/configuration, basic presentation, remove, and reorder workflows for built-in widgets without accepting executable code or SQL.

#### Scenario: Configure Average Intensity
- **WHEN** the user selects AggregateNumber, Average, and the intensity field with an explicit numeric policy
- **THEN** Flutter submits typed query and widget definitions that Rust validates before mutation

#### Scenario: Configure monthly chart
- **WHEN** the user selects a DateTime field, Month bucket, numeric aggregation, and LineChart
- **THEN** the resulting query is separate from the line-chart presentation configuration

### Requirement: AggregateNumber presentation
AggregateNumber SHALL accept a Scalar result and display Integer, FixedDecimal, Count, Average, Min, or Max values using exact formatting metadata and optional title.

#### Scenario: Display exact Balance
- **WHEN** Balance evaluates to FixedDecimal representation `257650` at scale two
- **THEN** AggregateNumber displays `2576.50`

### Requirement: LineChart presentation
LineChart SHALL accept an ordered numeric/time Series and render X/Y points, axes, empty state, and safe error state without changing query ordering or aggregation.

#### Scenario: Intensity history
- **WHEN** the query returns started_at and intensity ordered chronologically
- **THEN** LineChart plots those points in the returned order

### Requirement: BarChart presentation
BarChart SHALL accept compatible CategorySeries or ordered bucket Series results and render category/period labels with exact formatted values.

#### Scenario: Weekly headache frequency
- **WHEN** the query returns weekly bucket keys and Count values
- **THEN** BarChart displays one bar per returned week

### Requirement: ScatterPlot presentation
ScatterPlot SHALL accept an ordered numeric/time Series and render individual observations without connecting or aggregating them implicitly.

#### Scenario: Individual measurements
- **WHEN** the query returns timestamp and measurement pairs
- **THEN** ScatterPlot renders one point per pair

### Requirement: Responsive simple layout
Widget layout SHALL use deterministic ordered responsive list/grid behavior with bounded structured sizing hints and MUST NOT require a free-form coordinate editor.

#### Scenario: Android and Linux layout
- **WHEN** the same dashboard opens on a narrow Android screen and wide Linux Wayland window
- **THEN** all widgets and records remain reachable with platform-appropriate responsive arrangement

### Requirement: Reactive dashboard refresh
The dashboard SHALL reread definitions and reevaluate visible widget queries after relevant widget, query, record, or projection events; stream lag SHALL recover through a complete refresh.

#### Scenario: Remote record updates chart
- **WHEN** another trusted device adds a record and synchronization advances the local projection
- **THEN** affected visible widgets reevaluate and display the new result
