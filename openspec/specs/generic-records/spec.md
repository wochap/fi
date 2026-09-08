## Purpose

TBD: Define generic typed records, authoritative validation, field-granular mutation, synchronization, diagnostics, and reads.

## Requirements

### Requirement: Generic typed record representation
Records SHALL use canonical UUIDv7 `RecordId` and `CollectionSchemaId` values, a map from stable `FieldId` to strongly typed `FieldValue`, and logical deletion metadata; the application MUST NOT generate a Rust struct or physical SQLite table per user schema.

#### Scenario: Create records for unrelated schemas
- **WHEN** the user creates Headache and Money Movement records
- **THEN** both use the same generic record command, authoritative representation, projection, and query path

### Requirement: Rust-authoritative record validation
Before authoritative mutation, Rust SHALL verify that the collection and field are active, value types match definitions, required fields are present, numeric ranges hold, enum options are active members, defaults are valid, and FixedDecimal representations use the field's scale.

#### Scenario: Reject wrong value type
- **WHEN** Flutter supplies Text for an Integer field
- **THEN** Rust returns a typed field validation error and commits no authoritative or projected change

#### Scenario: Reject missing required value
- **WHEN** a create command omits a required field without a valid default
- **THEN** Rust rejects the complete record creation atomically

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
Structurally valid values made semantically inconsistent by concurrent schema evolution SHALL be retained and projected with typed diagnostics rather than dropped or allowed to block unrelated collections.

#### Scenario: Concurrent required field and record creation
- **WHEN** one offline device makes a field required while another creates a record without it and both states merge
- **THEN** the record remains recoverable, is marked invalid, and can be repaired through typed editing

### Requirement: Generic record read APIs
The application SHALL provide list and get queries backed by SQLite, exclude logically deleted data by default, use deterministic ordering, and return owned typed views without opening Automerge transactions.

#### Scenario: Rebuild preserves record view
- **WHEN** the read model is deleted and rebuilt from Automerge
- **THEN** record IDs, field values, validation status, and default ordering match the pre-deletion query result
