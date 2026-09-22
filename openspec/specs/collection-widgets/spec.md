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
Flutter SHALL let the user edit an existing saved query through the same query builder used to create one, pre-filled from the projected definition, and SHALL submit the edit through the update-query command so the `QueryId` is preserved and every widget referencing it evaluates the edited definition. The editor SHALL state how many active widgets reference the query before the edit is saved. The queries dialog SHALL offer edit alongside delete for each saved query, and the widget form SHALL offer "Edit this query" when a saved query is selected.

#### Scenario: Edit from the queries dialog
- **WHEN** the user taps edit on a saved query in the computed-fields-and-queries dialog, changes its aggregation, and saves
- **THEN** the query keeps its id, the change synchronizes as an update, and every widget referencing it renders the new result on next evaluation

#### Scenario: Edit from the widget form
- **WHEN** a widget form has "Use a saved query" on with a query selected and the user chooses "Edit this query"
- **THEN** the query builder opens pre-filled with that query, and saving updates it in place rather than creating a new definition

#### Scenario: Save as new from the widget form
- **WHEN** the user chooses "Save as new" instead of editing in place
- **THEN** a new `QueryId` is created from the builder contents, the original query is unchanged, and the widget being edited references the new id

#### Scenario: Referencing widgets are disclosed
- **WHEN** the user opens the editor for a query referenced by three active widgets
- **THEN** the editor states that three widgets use this query before the save action is available

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
