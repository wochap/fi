# collection-import-export Specification

## Purpose

Defines the portable CSV and JSON forms of collection data and the export and import behavior that moves records and whole collections in and out of a dataset without pairing.

## Requirements

### Requirement: CSV record export
The system SHALL export the active records of one collection as UTF-8 CSV (RFC 4180 quoting, comma separator, `\n` line ends). The header row SHALL contain the name of every active field in schema order, followed by the name of every active computed field. Deleted records, deleted fields, and deleted enum options SHALL NOT be exported. Values SHALL be rendered as: Integer as a decimal integer; FixedDecimal in its exact decimal form at the field scale; Boolean as `true` or `false`; Date as ISO-8601 `YYYY-MM-DD`; DateTime as ISO-8601 UTC with a `Z` suffix and millisecond precision; Duration as the raw millisecond integer; Enum as the option label; Null as an empty cell. When two active fields, or a field and a computed field, share a name, the export SHALL fail with an error naming the duplicated name and produce no file.

#### Scenario: Typed values rendered
- **WHEN** a record holds Integer 3, FixedDecimal 1.50 at scale 2, Boolean true, Date 2024-03-01, DateTime 2024-03-01T10:15:00.000Z, Duration 90000 ms, Enum option "Mild", and a Null text
- **THEN** the row reads `3,1.50,true,2024-03-01,2024-03-01T10:15:00.000Z,90000,Mild,`

#### Scenario: Computed columns appended
- **WHEN** a collection has fields `a`, `b` and computed field `sum`
- **THEN** the header is `a,b,sum` and each row carries the projected computed value, or an empty cell when it is null or invalid

#### Scenario: Duplicate names abort
- **WHEN** two active fields are both named `Notes`
- **THEN** the export fails with an error naming `Notes` and no file is produced

### Requirement: JSON collection export
The system SHALL export one or more collections as a single JSON document with top-level `format` equal to `fi-collection`, `version` equal to `1`, and `collections`, an array in which each entry carries the collection's schema (id, name, description, active fields with their active enum options), active computed fields, active queries, active widgets, and active records with their values. Ids SHALL be the current UUIDs. HLC stamps and tombstoned items SHALL NOT be exported. Exporting all collections SHALL include every active collection.

#### Scenario: Single collection envelope
- **WHEN** the user exports collection "Headache" as JSON
- **THEN** the document has `format: "fi-collection"`, `version: 1`, and one entry in `collections` whose records array holds every active record and whose widgets reference query ids present in the same entry

#### Scenario: Export all
- **WHEN** the user exports all collections and three collections are active and one is deleted
- **THEN** `collections` holds exactly the three active collections

### Requirement: CSV record import validates before writing
The system SHALL import CSV rows into an existing active collection only after parsing and validating every row. Header columns SHALL be matched to active fields by exact name. A column that matches no active field SHALL abort the import, except a column that matches an active computed field, which SHALL be ignored. A missing column for an optional field SHALL yield Null; a missing column for a required field SHALL abort. Cell text SHALL be trimmed before parsing and parsed strictly for the field type: Integer as a decimal integer; FixedDecimal by exact parse at the field scale; Boolean as `true` or `false`; Date as ISO-8601 date; DateTime as ISO-8601 with `Z` or offset; Duration as a millisecond integer; Enum by exact match on an active option label. An empty cell SHALL be Null. Each row SHALL be validated with the same rules as a record draft. Any parse, mapping, or validation failure SHALL abort the whole import, reporting the 1-based data row number, the column name, and the reason, and SHALL write nothing.

#### Scenario: All rows valid
- **WHEN** a CSV with 200 valid rows is imported into "Headache"
- **THEN** 200 new records with fresh ids appear in the collection, in file order, and the projection refreshes once

#### Scenario: One bad row aborts
- **WHEN** row 57 holds `high` in an Integer column
- **THEN** the import is rejected naming row 57 and that column, and the collection's record count is unchanged

#### Scenario: Unknown column aborts
- **WHEN** the header contains `Mood` and no active field or computed field is named `Mood`
- **THEN** the import is rejected naming `Mood` before any row is parsed

#### Scenario: Enum label lookup
- **WHEN** a Choice column holds `Severe` and no active option has that exact label, or two active options share it
- **THEN** the import is rejected naming the row and column

#### Scenario: Required empty cell
- **WHEN** a required field's cell is empty in some row
- **THEN** the import is rejected naming that row and column

### Requirement: Import commits as one change
An accepted CSV or JSON import SHALL be applied inside exactly one Automerge change carrying exactly one HLC stamp, SHALL produce exactly one projection pass, and SHALL emit exactly one `DataChanged` event per affected domain. A failure at write time SHALL leave no partial records or collections.

#### Scenario: Peer sees import whole
- **WHEN** a device imports 500 records and later synchronizes with a trusted peer
- **THEN** the peer's projection goes from none of the imported records to all of them in one pass

### Requirement: JSON import creates new collections
Importing a `fi-collection` document SHALL create a new collection for every entry in `collections` and SHALL never modify or replace an existing collection, even when an id or name in the document matches one already present. Every collection, field, enum option, computed field, query, widget, and record SHALL receive a fresh id, and every internal reference (widget to query, query and computed expressions to fields and computed fields, enum values and defaults to options) SHALL be remapped to the new ids. Imported records SHALL receive fresh stamps at import time. The imported collection SHALL keep the name in the document. A document whose `format` is not `fi-collection` or whose `version` is not `1`, or whose content fails schema, query, widget, or record validation, SHALL abort the import with a reason and write nothing.

#### Scenario: Import own export twice
- **WHEN** the user imports the same exported envelope two times
- **THEN** two additional collections with the same name exist, each with distinct ids for every field, option, query, widget, and record, and the original collection is unchanged

#### Scenario: References remapped
- **WHEN** an imported collection has a widget bound to a query that filters on field `severity`
- **THEN** the new widget references the new query id, and the new query references the new `severity` field id, and the widget renders data from the imported records

#### Scenario: Wrong version
- **WHEN** the document has `version: 2`
- **THEN** the import is rejected with a version error and no collection is created

#### Scenario: Invalid entry aborts all
- **WHEN** an envelope with three collections has a record in the third that violates its schema
- **THEN** none of the three collections is created

### Requirement: Export and import use platform file dialogs
The application SHALL let the user choose the destination file for an export and the source file for an import with the platform's native file dialog on Linux and Android. An export SHALL write the file only after the user confirms a location, and an import SHALL read only the chosen file. Cancelling either dialog SHALL perform no export or import. The user SHALL be told the outcome: the written file name, the number of records or collections imported, or the abort reason.

#### Scenario: Cancel save dialog
- **WHEN** the user picks Export CSV and dismisses the save dialog
- **THEN** no file is written and no error is shown

#### Scenario: Import outcome shown
- **WHEN** a CSV import of 120 rows succeeds
- **THEN** the UI reports 120 records imported and the record list shows them
