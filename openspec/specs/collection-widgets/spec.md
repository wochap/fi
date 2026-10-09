## Purpose

TBD: Define synchronized widget definitions, open-ended type identity, lossless presentation configuration, query and result-shape contracts, command validation, logical lifecycle, per-widget evaluation isolation, and derived widget data.

## Requirements

### Requirement: Synchronized widget definitions
Each widget definition SHALL have a stable UUIDv7 `WidgetId`, owning collection ID, open-ended string widget type, query reference, optional title, structured presentation configuration, layout, order, and logical tombstone, and SHALL synchronize through the existing Automerge root.

#### Scenario: Widget synchronizes
- **WHEN** Device A creates a widget and synchronizes with Device B
- **THEN** Device B projects the same widget ID, type identifier, query reference, configuration, and order

### Requirement: Open-ended widget identity
Persisted widget type identity SHALL be a validated namespaced string such as `core.aggregate-number` and MUST NOT be encoded as a closed Rust or Dart enum.

#### Scenario: Future plugin identity
- **WHEN** a definition uses `com.example.calendar-heatmap`
- **THEN** its identity remains valid preserved data even when the local application has no implementation

### Requirement: Structured lossless presentation configuration
Widget presentation configuration SHALL use versioned serializable structured values and SHALL remain separate from query semantics. Unknown widget types and unknown configuration keys MUST survive projection, synchronization, reads, and unrelated metadata edits intact.

#### Scenario: Rename unknown widget
- **WHEN** a user renames the title of an unsupported widget
- **THEN** its widget type, query, and unknown presentation configuration are unchanged

### Requirement: Query and result-shape contract
A widget SHALL reference a declarative collection query, and known widget descriptors SHALL declare the query result shapes they accept. Widget implementations MUST NOT perform hidden filtering or aggregation that changes query semantics.

#### Scenario: Shape mismatch
- **WHEN** an AggregateNumber widget references a Series query
- **THEN** Rust rejects the local configuration or returns a typed per-widget mismatch for merged data

### Requirement: Widget command validation
Rust SHALL validate owning collection, IDs, known built-in type/configuration versions, referenced query, expected result shape, layout, ordering, and command target before accepting add or update operations.

#### Scenario: Invalid widget query
- **WHEN** a local widget command references a deleted or incompatible query
- **THEN** the command fails without committing Automerge or projection changes

### Requirement: Logical widget lifecycle
Widget removal SHALL set a monotonic tombstone, ordinary updates MUST NOT resurrect it, and active widgets SHALL use deterministic order with stable-ID tie breaking.

#### Scenario: Concurrent reorder
- **WHEN** devices reorder widgets concurrently and synchronize equal order values
- **THEN** both dashboards display every active widget in the same deterministic order

### Requirement: Per-widget evaluation isolation
Unsupported type, invalid merged definition, query failure, numeric overflow, or result-shape mismatch SHALL fail only the affected widget and MUST NOT prevent the collection screen, records, or other widgets from loading.

#### Scenario: One invalid widget
- **WHEN** one of three widgets has an invalid query after synchronization
- **THEN** the other two evaluate normally and the invalid widget returns a typed error descriptor

### Requirement: Derived widget data
Widget results and rendering coordinates SHALL be derived from the current SQLite projection and MUST NOT be written as authoritative synchronized data.

#### Scenario: Record changes widget result
- **WHEN** a synchronized record advances the projection
- **THEN** reevaluating its widget query produces updated data without synchronizing a cached result

### Requirement: Saved queries are editable in place
Flutter SHALL let the user edit an existing saved query through the same query builder used to create one, pre-filled from the projected definition, and SHALL submit the edit through the update-query command so the `QueryId` is preserved and every widget referencing it evaluates the edited definition. The editor SHALL state how many active widgets reference the query before the edit is saved; when at least one does, the line SHALL add that changes apply there too, for example "Used by 1 widget · changes apply there too". The queries dialog SHALL offer edit alongside delete for each saved query, and the widget form SHALL offer "Edit this query" and "Save as new" when "Use a saved query" is chosen and a query is selected. The widget form SHALL present the query source as a two-way choice, "Define here" or "Use a saved query" (mock widget-editor).

#### Scenario: Edit from the queries dialog
- **WHEN** the user taps edit on a saved query in the computed-fields-and-queries dialog, changes its aggregation, and saves
- **THEN** the query keeps its id, the change synchronizes as an update, and every widget referencing it renders the new result on next evaluation

#### Scenario: Edit from the widget form
- **WHEN** a widget form has "Use a saved query" chosen with a query selected and the user chooses "Edit this query"
- **THEN** the query builder opens pre-filled with that query, and saving updates it in place rather than creating a new definition

#### Scenario: Save as new from the widget form
- **WHEN** the user chooses "Save as new" instead of editing in place
- **THEN** a new `QueryId` is created from the builder contents, the original query is unchanged, and the widget being edited references the new id

#### Scenario: Referencing widgets are disclosed
- **WHEN** the user opens the editor for a query referenced by three active widgets
- **THEN** the editor states "Used by 3 widgets · changes apply there too" before the save action is available

#### Scenario: Pre-fill fidelity
- **WHEN** the builder is opened for a saved query with a filter, a Month grouping on a date field, and a Sum aggregation
- **THEN** every builder control reflects those values, and saving without changes produces a definition equal to the original apart from its version

### Requirement: Chart query controls are always visible and presettable
For line-chart and bar-chart widgets the query builder SHALL always show "Group by" (calendar period or none) and, when a period is chosen, "Date field", rather than revealing them conditionally, and SHALL label the ungrouped category selector "Category field". The builder SHALL offer presets that prefill aggregation, operand, group-by, and date field, at minimum "Daily total", "Monthly total", "Count per day", and "Latest values", and applying a preset SHALL leave every control editable afterward.

#### Scenario: Daily total in two taps
- **WHEN** the user picks line-chart and applies the "Daily total" preset in a collection with one FixedDecimal field and one Date field
- **THEN** aggregation is Sum over that FixedDecimal field, group-by is Day on that Date field, and the form is submittable without further choices

#### Scenario: Preset needs a choice
- **WHEN** the user applies "Daily total" in a collection with two numeric fields
- **THEN** group-by and date field are filled and the field-to-aggregate control is left for the user with the form blocker naming it

#### Scenario: Controls remain visible
- **WHEN** the user opens the builder for a bar chart with no grouping chosen
- **THEN** "Group by" is shown with "None" selected and "Category field" is shown, rather than the period controls being hidden until a bucket is chosen

### Requirement: Deleting a referenced saved query is confirmed
Deleting a saved query from the queries dialog SHALL ask for confirmation when at least one active widget references it: the title "Delete query “<name>”?", the line stating how many widgets use it and that they will show an error until edited (for example "1 widget uses it and will show an error until you edit it."), and the actions "Delete query" (secondary, left) and "Keep query" (primary, right). A query no widget references SHALL be deleted without the confirmation.

#### Scenario: Keep a referenced query
- **WHEN** the user deletes "Headache hours", which one widget uses, and chooses "Keep query"
- **THEN** the query and the widget are unchanged

#### Scenario: Delete a referenced query
- **WHEN** the user deletes "Headache hours" and chooses "Delete query"
- **THEN** the query is removed and the widget that used it shows "The saved query of this widget is no longer available."

#### Scenario: Unreferenced query
- **WHEN** the user deletes "Record count", which no widget uses
- **THEN** it is removed without a confirmation

### Requirement: Saved query result type and live result
Each saved-query row in the queries dialog SHALL show a tag with the type of the value its aggregation produces: "Integer" for Count, the operand field's type for Sum, Min and Max, and a decimal at the declared output scale for Average (mock queries). The query editor SHALL show a "Result now" line with the query's current result for this device's records, formatted exactly, reevaluated as the builder changes; while the builder is incomplete or the query cannot run the line SHALL be hidden. "Add query" SHALL open the query editor for a new query instead of creating one immediately.

#### Scenario: Duration sum tag and result
- **WHEN** the saved query "Headache hours" sums the Duration computed field over records whose total is 5 h 30 min
- **THEN** its row shows the tag "Duration" and its editor shows "Result now" with "5 h 30 min"

#### Scenario: Count tag
- **WHEN** the saved query "Record count" counts records
- **THEN** its row shows the tag "Integer"

#### Scenario: Add query opens the editor
- **WHEN** the user taps "Add query"
- **THEN** the query editor opens with an empty name, and nothing is created until the user saves

### Requirement: Overlap note for Choices grouping
A widget whose query groups by a Choices field SHALL show the muted note "Groups overlap: a record counts in each of its choices." under its content, in English and in its Spanish translation. Widgets grouped by any other key SHALL NOT show the note.

#### Scenario: Grouped by Choices
- **WHEN** a bar widget shows Sum of amount grouped by "tags", a Choices field
- **THEN** the widget shows "Groups overlap: a record counts in each of its choices."

#### Scenario: Grouped by Choice
- **WHEN** a widget groups by a Choice field
- **THEN** no overlap note is shown
