## Purpose

TBD: Define synchronized per-collection saved views (filter and sort), the implicit All view, view validation, execution, listing with counts, commands, and broken-view isolation.

## Requirements

### Requirement: Synchronized view definitions
Each saved view SHALL have a stable UUIDv7 `ViewId`, its owning collection ID, a name, a versioned view body, an order value, and a logical tombstone, and SHALL be stored in the collection's entry of the Automerge root under its own `views` map, separate from saved queries. The name, body, order and tombstone SHALL be separate Automerge last-writer-wins registers of the view's entry, in the same per-key pattern as widget definitions, so concurrent changes to different parts of one view all survive. The view body SHALL hold an optional filter expression and an ordered list of zero to three sort clauses, and MAY hold further optional parts defined by other requirements of this capability. Views SHALL synchronize through ordinary repository synchronization and SHALL be projected into the read model, where a complete projection rebuild SHALL reproduce them. Views SHALL NOT be query definitions: they SHALL NOT be listed with saved queries and a widget SHALL NOT reference a view.

#### Scenario: View synchronizes
- **WHEN** Device A creates the view "Headaches" on the collection "pains" and synchronizes with Device B
- **THEN** Device B lists a view with the same `ViewId`, name, filter, sort clauses and order

#### Scenario: Views are not saved queries
- **WHEN** a collection has two saved queries and one view
- **THEN** listing the collection's query definitions returns the two queries only, and the widget editor offers only those two as data sources

#### Scenario: Projection rebuild keeps views
- **WHEN** the read model is deleted and rebuilt at unchanged Automerge heads
- **THEN** the collection's views, their order and their execution results equal those before deletion

### Requirement: Implicit All view
Every active collection SHALL have an implicit view "All" that is not stored in Automerge: it SHALL have no filter and the single sort key record creation time descending. All SHALL always be listed first, ahead of every saved view, and SHALL NOT be renamed, edited in place, reordered or deleted. It SHALL be addressed by a reserved identifier that is never a UUID. Commands that would rename, reorder, replace or delete All SHALL NOT exist.

#### Scenario: New collection
- **WHEN** a collection with no saved views is opened
- **THEN** its view list holds exactly All, which shows every active record newest first by creation time with record id as the tie breaker

#### Scenario: All cannot be deleted
- **WHEN** a remove-view command is attempted for an id that is not a saved view of the collection
- **THEN** Rust returns a typed not-found error and nothing changes

### Requirement: View validation
Before persisting a local create, rename or body update, Rust SHALL validate the structure of the view against the collection's active schema and computed fields:
- The name SHALL be trimmed and SHALL be 1 to 40 characters.
- A filter, when present, SHALL produce Boolean under the typed-expression rules.
- There SHALL be at most three sort clauses. Each SHALL be record creation time or an active source or computed field whose type is orderable, and SHALL NOT be a multi-option Choices field.
- Every sort clause SHALL keep empty values last. Rust SHALL store the null order "last" for every clause of a view, whatever null order the command carried.

A failed validation SHALL return a typed validation error whose issues carry one of the stable codes `length` (name), `view_filter_type`, `view_sort_key` or `view_sort_limit` and name the offending part, and SHALL write nothing. Rust SHALL NOT reject a name for being equal to another view's name or to the localized name of All; those checks belong to the app.

#### Scenario: Reject sort by a multi-option Choices field
- **WHEN** a view sorts by "tags", a multi-option Choices field
- **THEN** validation fails with the code `view_sort_key` on that sort clause and the view is not persisted

#### Scenario: Reject a fourth sort key
- **WHEN** a view carries four sort clauses
- **THEN** validation fails with the code `view_sort_limit` and the view is not persisted

#### Scenario: Null order is normalized
- **WHEN** a create-view command carries a sort clause with null order "first"
- **THEN** the stored view's clause has null order "last"

### Requirement: Duplicate view names after merge
Two saved views of one collection MAY carry the same name, for example after two devices each create "Headaches" while offline and then synchronize. Both views SHALL be kept, listed in order with their own ids, and remain renamable and deletable. The system SHALL NOT rename, suffix or merge them automatically.

#### Scenario: Offline creates with the same name
- **WHEN** Device A and Device B each create a view "Headaches" on "pains" while offline and then synchronize
- **THEN** both devices list two views named "Headaches" with different ids, ordered by order value then `ViewId`

### Requirement: View execution returns ordered ids
Executing a saved view, or an unsaved view body, for a collection SHALL return the ids of the active records the filter keeps, in view order, and the view's count. View order SHALL apply the effective sort clauses in turn, with empty values last in every clause and the record id ascending as the final tie breaker. Execution SHALL be deterministic for the same Automerge heads and SHALL NOT depend on, nor change, any widget, saved query or dashboard result.

#### Scenario: Filter and sort
- **WHEN** the view "Headaches" filters "type is any of {headache}" and sorts by "start at" descending over 47 records of which 31 are headaches
- **THEN** execution returns the 31 headache ids from latest to earliest start, ties broken by record id, and the count 31

#### Scenario: Empty values last both ways
- **WHEN** a view sorts by "level" ascending, then the same view is flipped to descending, and two records have no level
- **THEN** both results end with those two records, ordered by record id

### Requirement: View listing carries counts
Listing a collection's views SHALL be one call returning All first and then every active saved view in order, each with its id, name, body, effective sort, health, and its count of records. A broken view SHALL report no count and its diagnostic instead of failing the call. Counts SHALL use the same filter semantics as view execution.

#### Scenario: Chip counts
- **WHEN** "pains" has 47 active records, "Headaches" keeps 31 and "Stomach" keeps 9
- **THEN** listing returns All 47, Headaches 31, Stomach 9

#### Scenario: Broken view in the listing
- **WHEN** one of three saved views is broken
- **THEN** the listing returns counts for All and the two other views, and the broken view reports no count with its diagnostic

### Requirement: View commands
Rust SHALL provide commands to:
- create a view with a name and body, placed after the last saved view;
- replace a view's body;
- rename a view;
- reorder the saved views of a collection;
- logically delete a view.

Each command SHALL validate before writing, SHALL apply as one Automerge change under one HLC stamp with one projection pass and one data-changed notification, and SHALL leave records, saved queries and widgets unchanged. Concurrent changes to the same part of a view SHALL resolve by the repository's last-writer rule. A concurrent delete SHALL win over an edit, because an edit never clears the tombstone. Views with equal order values SHALL be listed by `ViewId`.

#### Scenario: Concurrent rename and edit
- **WHEN** Device A renames "Headaches" to "Head" while Device B changes its sort, and they synchronize
- **THEN** both devices show the view "Head" with Device B's sort

#### Scenario: Concurrent delete and edit
- **WHEN** Device A deletes "Stomach" while Device B edits its filter, and they synchronize
- **THEN** "Stomach" is deleted on both devices

#### Scenario: Delete keeps records
- **WHEN** the user deletes the view "Headaches"
- **THEN** the view is tombstoned and every record it showed is unchanged

### Requirement: Broken views are isolated
A saved view or unsaved body whose filter no longer validates against the current schema, or whose body version is unsupported, SHALL be preserved and SHALL be reported as broken with a diagnostic naming the missing or incompatible field. This covers a deleted field, a deleted option used in a filter constant, and a field changed between single and multi-option Choices. Executing a broken view or body SHALL return a typed broken-view error. A broken view SHALL NOT prevent All, other views, saved queries, widgets or the record list from working.

A sort clause that no longer resolves to an orderable field SHALL NOT break the view: the view is degraded, and execution SHALL skip that clause. When no clause is left, it SHALL sort by record creation time descending. The view's listing SHALL report the effective sort, which is the stored sort with the unresolvable clauses removed.

#### Scenario: Filter field deleted
- **WHEN** the field "type" is deleted while the view "Headaches" filters on it
- **THEN** "Headaches" is listed as broken with a diagnostic naming "type", executing it returns the broken-view error, and All still executes

#### Scenario: Sort field deleted
- **WHEN** the only sort key of a view is the field "level" and "level" is deleted
- **THEN** the view is not broken, it executes sorted by creation time descending, and its listing reports that effective sort

#### Scenario: Sort field becomes multi-option
- **WHEN** a view sorts by "type" and "type" is changed from single to multi-option Choices
- **THEN** the view is degraded, not broken, and its effective sort no longer contains "type"
