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
