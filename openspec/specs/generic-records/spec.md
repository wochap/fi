## Purpose

TBD: Define generic typed records, authoritative validation, field-granular mutation, synchronization, diagnostics, and reads.

## Requirements

### Requirement: Generic typed record representation
Records SHALL use canonical UUIDv7 `RecordId` and `CollectionSchemaId` values, a map from stable `FieldId` to strongly typed `FieldValue`, and logical deletion metadata; the application MUST NOT generate a Rust struct or physical SQLite table per user schema. `FieldValue` SHALL include an EnumSet variant holding a set of option ids, ordered by the field's option order with the option id as tie-breaker when read. An empty EnumSet value SHALL read as Null.

#### Scenario: Create records for unrelated schemas
- **WHEN** the user creates Headache and Money Movement records
- **THEN** both use the same generic record command, authoritative representation, projection, and query path

#### Scenario: Choices value in a record
- **WHEN** a record is created with the Choices field "tags" set to {"urgent", "work"}
- **THEN** the record reads "tags" as the set of both option ids in the field's option order

#### Scenario: Empty set is Null
- **WHEN** an optional Choices field is updated to the empty set
- **THEN** the record reads that field as Null, and a required Choices field updated to the empty set is rejected with a missing-required issue

### Requirement: Rust-authoritative record validation
Before authoritative mutation, Rust SHALL verify that the collection and field are active, value types match definitions, required fields are present, numeric ranges hold, enum options are active members (except that an existing record may keep a removed option it already holds, as long as the command does not newly set it), relative Date defaults resolve from the record's creation day, defaults are valid, and FixedDecimal representations use the field's scale. Validation SHALL report every issue it finds rather than stopping at the first, and each issue SHALL carry the ids of the fields it concerns, a stable code, and a safe message that contains no ids.

#### Scenario: Reject wrong value type
- **WHEN** Flutter supplies Text for an Integer field
- **THEN** Rust returns a typed field validation error and commits no authoritative or projected change

#### Scenario: Reject missing required value
- **WHEN** a create command omits a required field without a valid default
- **THEN** Rust rejects the complete record creation atomically

#### Scenario: Report all issues
- **WHEN** a create command omits one required field and gives another field a value outside its range
- **THEN** Rust rejects the creation and reports two issues, each naming its own field id

#### Scenario: Keep a removed option on update
- **WHEN** a record holds the removed option "option 3" and an update changes only another field
- **THEN** Rust accepts the update and the record stays valid

#### Scenario: Newly set a removed option
- **WHEN** a create or update command sets a Choice field to a removed option
- **THEN** Rust rejects it with the inactive-option issue for that field

#### Scenario: Relative default applied on create
- **WHEN** a record created on 2026-09-28 (UTC) omits a Date field whose relative default is +7 days
- **THEN** the stored value is 2026-10-05

#### Scenario: Messages without ids
- **WHEN** a text value is longer than the field allows
- **THEN** the issue message states the allowed length (for example "Must be 1–40 characters") and does not contain the field id

### Requirement: Field-granular record commands
Record creation SHALL initialize fields individually, record updates SHALL write only explicitly targeted fields, and ordinary edits MUST NOT replace the entire record object.

#### Scenario: Edit one field
- **WHEN** a command changes only Headache intensity
- **THEN** no Automerge write is produced for notes or other record fields

### Requirement: Explicit null and optional values
The record model SHALL distinguish an explicit Null field value from an absent never-written value, SHALL permit Null only where the field is optional, and MUST NOT parse arbitrary text into another field type implicitly.

#### Scenario: Clear optional end time
- **WHEN** an optional DateTime field is updated to Null
- **THEN** its synchronized value is explicitly null and other fields are unchanged

### Requirement: Logical record deletion
DeleteRecord SHALL set a monotonic tombstone that ordinary field updates do not clear, and default queries SHALL omit tombstoned records.

#### Scenario: Concurrent edit and delete
- **WHEN** one device edits a record field while another deletes the record
- **THEN** the edit history remains but the converged record stays logically deleted

### Requirement: Record synchronization
Generic records and typed field values SHALL synchronize through the existing Automerge root and Repo protocol with no record-specific transport infrastructure.

#### Scenario: Phone creates desktop-visible record
- **WHEN** a phone creates a valid record and later synchronizes with a trusted desktop
- **THEN** the desktop projection and generic record query return that record with the same IDs and typed values

### Requirement: Semantic inconsistency preservation
Structurally valid values made semantically inconsistent by schema evolution, whether concurrent across devices or performed locally over existing records, SHALL be retained and projected with typed diagnostics rather than dropped or allowed to block unrelated collections.

#### Scenario: Concurrent required field and record creation
- **WHEN** one offline device makes a field required while another creates a record without it and both states merge
- **THEN** the record remains recoverable, is marked invalid, and can be repaired through typed editing

#### Scenario: Local required field over existing records
- **WHEN** a device makes a field required with no default while its own active records lack that field
- **THEN** those records remain recoverable, are marked invalid with the same missing-required diagnostic as the merged case, and can be repaired through typed editing

#### Scenario: Diagnostics do not block creation elsewhere
- **WHEN** a collection holds records marked invalid for a missing required field
- **THEN** creating a valid new record in that collection, and any record in another collection, succeeds normally

### Requirement: Generic record read APIs
The application SHALL provide list and get queries backed by SQLite, exclude logically deleted data by default, use deterministic ordering, and return owned typed views without opening Automerge transactions.

#### Scenario: Rebuild preserves record view
- **WHEN** the read model is deleted and rebuilt from Automerge
- **THEN** record IDs, field values, validation status, and default ordering match the pre-deletion query result

### Requirement: Atomic record batch commands
The generic command model SHALL provide a batch command whose members are record-scoped commands (`CreateRecord`, `UpdateRecordField`, `DeleteRecord`) targeting distinct records of one active collection. A `CreateRecord` member SHALL carry a fresh record id that does not exist in the snapshot; `UpdateRecordField` and `DeleteRecord` members SHALL target active records. A batch MUST be non-empty, MUST NOT contain another batch, and MUST NOT contain schema, computed-field, query, or widget commands. Every member SHALL be validated against the same pre-change snapshot before any write, and a validation failure of any member SHALL reject the whole batch with the failing member identified. An accepted batch SHALL be applied inside exactly one Automerge change carrying exactly one HLC stamp, SHALL produce exactly one projection pass, and SHALL emit exactly one `DataChanged` event naming the affected collection.

#### Scenario: Batch delete commits once
- **WHEN** a batch of twelve `DeleteRecord` members is applied
- **THEN** the root document gains exactly one new change, every tombstone carries the same HLC stamp, and subscribers receive one `DataChanged` event for `Records` in that collection

#### Scenario: Batch field set writes one register per record
- **WHEN** a batch sets field `category` to the same value on five records
- **THEN** five field registers are replaced under their stable field ID with the same stamp, no other field of those records is written, and later single-field edits to any of them resolve by ordinary field-level LWW

#### Scenario: Batch create commits once
- **WHEN** a batch of 300 `CreateRecord` members for one collection is applied
- **THEN** the root document gains exactly one new change, every record's field registers carry the same HLC stamp, one projection pass runs, and subscribers receive one `DataChanged` event for `Records` in that collection

#### Scenario: One invalid member rejects all
- **WHEN** a batch sets a required field to `Null` on three records, one member targets a record that is not active, or a `CreateRecord` member fails schema validation
- **THEN** Rust returns a typed error identifying the failing member and commits no authoritative or projected change for any member

#### Scenario: Nested or mixed batch rejected
- **WHEN** a batch contains another batch, a schema command, two members targeting the same record, or a `CreateRecord` whose id already exists
- **THEN** validation rejects the batch before any write

#### Scenario: Peer sees the batch whole
- **WHEN** a device applies a batch and later synchronizes with a trusted peer
- **THEN** the peer's projection transitions from none of the batch applied to all of it in one projection pass, never a strict subset

### Requirement: Record draft validation query
Rust SHALL expose a read-only query that validates a draft record for a collection (and optionally an existing record id) with the same rules as record create and update, returning the list of issues and committing nothing.

#### Scenario: Valid draft
- **WHEN** Flutter validates a draft whose values all satisfy the schema
- **THEN** the query returns an empty list and no command is recorded

#### Scenario: Invalid draft
- **WHEN** Flutter validates a draft missing a required field
- **THEN** the query returns an issue with code `required` naming that field, and no record is created

### Requirement: Record creation time
Every record view returned by the list and get queries SHALL carry the record's creation time in Unix milliseconds, derived from the timestamp embedded in its time-ordered (UUIDv7) record id, so that the value is identical on every device and survives a read-model rebuild without being stored separately. A record whose id carries no embedded timestamp SHALL report no creation time rather than a guessed one.

#### Scenario: Creation time from the id
- **WHEN** a record is created at 2026-09-22 10:15:00.000 UTC and then listed
- **THEN** its view reports a creation time of that instant to the millisecond

#### Scenario: Same on every device
- **WHEN** the record syncs to a second device and is listed there
- **THEN** the second device reports the same creation time

#### Scenario: Id without a timestamp
- **WHEN** a record's id is not a time-ordered id
- **THEN** its view reports no creation time and the record is still listed

### Requirement: Clone records command
The application core SHALL provide a command that clones one or more active records of one active collection and returns the new record ids in the order of the source ids. Each clone SHALL receive a fresh time-ordered record id and SHALL hold the source record's current value for every active field of the collection, copied as-is (Date and DateTime values included), with these exceptions: a value of a deleted field SHALL NOT be copied, and a Choice value holding a removed option SHALL be dropped (the field is left without a value). Computed field values SHALL NOT be stored; they are recomputed for the clone. The clones SHALL be written as one atomic record batch of `CreateRecord` members, so every clone is validated with the same rules as record creation against the same snapshot, and a failure of any member SHALL reject the whole command and create no record. The source records MUST NOT be modified. An empty id list, a source id that is not an active record of the collection, or a source id given twice SHALL be rejected before any write.

#### Scenario: Clone three records
- **WHEN** the command clones three active records of "expenses"
- **THEN** three new records exist with fresh ids and the sources' values, the root document gains exactly one new change, and subscribers receive one `DataChanged` event for `Records` in "expenses"

#### Scenario: Dates copied as-is
- **WHEN** a record dated 2026-09-27 is cloned on 2026-10-08
- **THEN** the clone's date is 2026-09-27 and its creation time is the clone's own creation time

#### Scenario: Removed option dropped
- **WHEN** an optional Choice field holds the removed option "option 3" and the record is cloned
- **THEN** the clone has no value for that field and every other value is copied

#### Scenario: Incomplete source rejects the clone
- **WHEN** one of the selected sources lacks a value for a required field without a default, or its only value for a required Choice field is a removed option
- **THEN** the command fails with the typed validation error identifying that member, and no record is created

#### Scenario: Sources unchanged
- **WHEN** a record is cloned
- **THEN** the source record's field registers and stamps are unchanged
