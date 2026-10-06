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
Widget layout SHALL use deterministic ordered responsive list/grid behavior with bounded structured sizing hints and MUST NOT require a free-form coordinate editor. At 720px and wider the dashboard SHALL be a four-column grid in which a Small widget spans one column, Medium two, Large three and Full four, wrapping to the next row in widget order (mock collection-dashboard). Below 720px every widget SHALL span the full width in one column. The widget editor SHALL state what the chosen size spans, for example "Medium spans 2 of 4 columns."

#### Scenario: Android and Linux layout
- **WHEN** the same dashboard opens on a narrow Android screen and wide Linux Wayland window
- **THEN** all widgets and records remain reachable with platform-appropriate responsive arrangement

#### Scenario: Size spans on a wide screen
- **WHEN** a dashboard 1000px wide holds, in order, a Small, a Medium and a Large widget
- **THEN** the Small and Medium widgets share the first row spanning one and two of four columns, and the Large widget starts the next row spanning three columns

#### Scenario: Phone stacks widgets
- **WHEN** the same dashboard is shown 390px wide
- **THEN** each widget spans the full width, one per row, in the same order

### Requirement: Reactive dashboard refresh
The dashboard SHALL reread definitions and reevaluate visible widget queries after relevant widget, query, record, or projection events; stream lag SHALL recover through a complete refresh.

#### Scenario: Remote record updates chart
- **WHEN** another trusted device adds a record and synchronization advances the local projection
- **THEN** affected visible widgets reevaluate and display the new result

### Requirement: Widget tile menu
Every widget tile SHALL show a ⋮ button that opens the widget's actions: "Edit widget", "Reorder" and "Remove…". At 720px and wider the actions SHALL open as a menu anchored to the button; below 720px they SHALL open as an action sheet headed by the widget title. "Reorder" SHALL be unavailable while the dashboard holds fewer than two widgets. Tapping the tile body SHALL keep opening the widget editor. "Remove…" SHALL ask "Remove widget “<title>”?" with the line "Its saved query and the records stay." and the actions "Remove" (secondary, left) and "Keep widget" (primary, right); only "Remove" SHALL remove the widget. The widget editor's remove action SHALL ask the same confirmation.

#### Scenario: Phone widget menu
- **WHEN** the user taps ⋮ on the "Level over time" widget on a 390px-wide screen
- **THEN** an action sheet headed "Level over time" lists "Edit widget", "Reorder" and "Remove…"

#### Scenario: Remove is confirmed
- **WHEN** the user chooses "Remove…" and then "Keep widget"
- **THEN** the widget is still on the dashboard

#### Scenario: Remove after confirming
- **WHEN** the user chooses "Remove…" and then "Remove"
- **THEN** the widget disappears from the dashboard and its saved query is unchanged

### Requirement: Inline reorder mode
Choosing "Reorder" SHALL put the dashboard into a reorder mode in place, without opening a dialog. In reorder mode every tile SHALL show a drag handle, "Move up", "Move down" and "Remove widget" buttons, each at least 44×44 below 720px, and the dashboard header SHALL show "Done" in place of "Reorder" and "Add widget". "Move up" SHALL be unavailable on the first widget and "Move down" on the last. Every move SHALL be submitted as a deterministic reorder of the active widgets. "Remove widget" SHALL ask the same confirmation as "Remove…". "Done" SHALL leave reorder mode. Tapping a tile in reorder mode SHALL NOT open the editor.

#### Scenario: Move a widget down
- **WHEN** the dashboard holds "Avg level", "Level over time" and "Episodes by type" in that order, the user enters reorder mode and taps "Move down" on "Avg level"
- **THEN** the order becomes "Level over time", "Avg level", "Episodes by type" and stays so after leaving reorder mode

#### Scenario: Edges are disabled
- **WHEN** the dashboard is in reorder mode
- **THEN** "Move up" is unavailable on the first widget and "Move down" on the last

### Requirement: Widget state presentation
Each widget tile SHALL present its evaluation state (mock widget-states):
- While its result is not yet available: a quiet skeleton in the shape of its widget type under the title, without a spinner.
- When the query returns no rows or no value: "No records match yet".
- When evaluation fails: the localized message for the typed error kind with an error icon, and an "Edit widget" button that opens the widget editor. Rust's technical wording SHALL NOT be shown in the tile.
- For a widget type this build cannot render: the title, "Unsupported widget", the explanation that the configuration is preserved and can be renamed, reordered or removed, and the exact widget type string in small monospace text, with no Edit widget button.
One tile's state SHALL NOT affect any other tile.

#### Scenario: Invalid saved query
- **WHEN** a widget's saved query is invalid after a merge
- **THEN** its tile shows "The saved query of this widget is not valid." and an "Edit widget" button, and the other tiles render normally

#### Scenario: Empty chart
- **WHEN** a line chart's query matches no records
- **THEN** its tile shows "No records match yet"

#### Scenario: Unsupported type
- **WHEN** a synchronized widget has type `com.example.mood-heatmap`
- **THEN** its tile shows its title, "Unsupported widget", the explanation and `com.example.mood-heatmap`, and no Edit widget button
