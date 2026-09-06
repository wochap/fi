## Purpose

TBD: Define the crash-safe filesystem storage layout, encoding, validation, replacement, and execution behavior.

## Requirements

### Requirement: Canonical filesystem repository layout
The filesystem adapter SHALL store documents beneath `automerge/` as lowercase hyphenated UUID names ending in `.automerge` and SHALL store bootstrap control at `control/bootstrap-v1.bin` beneath the configured repository directory.

#### Scenario: Canonical document path
- **WHEN** a snapshot is stored for a document ID
- **THEN** its destination is `<repo>/automerge/<canonical-uuid>.automerge`

#### Scenario: Bootstrap path
- **WHEN** a bootstrap record is stored
- **THEN** its destination is `<repo>/control/bootstrap-v1.bin`

#### Scenario: Restart round trip
- **WHEN** valid documents and a control record are durably stored and the repository is reopened
- **THEN** the adapter returns the same document IDs, snapshot bytes, and bootstrap value

### Requirement: Atomic durable replacement
Every document snapshot and control-record replacement SHALL use an exclusively created unique sibling temporary file, write all bytes, synchronize the temporary file, atomically replace the destination, and synchronize the containing directory.

#### Scenario: Failure before replacement
- **WHEN** writing or synchronizing the temporary file fails before atomic replacement
- **THEN** any previously valid destination remains byte-for-byte valid

#### Scenario: Successful replacement
- **WHEN** all replacement steps succeed
- **THEN** reopening after a crash observes the complete new value and not a partial file

#### Scenario: Directory synchronization
- **WHEN** atomic replacement succeeds on a platform supporting directory synchronization
- **THEN** the adapter invokes `sync_all()` on the containing directory before reporting durable success

#### Scenario: Exclusive temporary creation
- **WHEN** a generated temporary name already exists
- **THEN** the adapter chooses another unique name and never truncates the existing file

### Requirement: Strict document-directory validation
Startup SHALL recognize and clean or ignore only the adapter's complete stale temporary-file pattern, SHALL reject malformed names ending in `.automerge`, and SHALL report corrupt snapshots with their paths. Unrelated files SHALL be ignored only as documented.

#### Scenario: Recognizable stale temporary file
- **WHEN** startup finds a file matching the adapter's complete temporary pattern
- **THEN** it removes or ignores that file without treating it as a document

#### Scenario: Unrelated file
- **WHEN** startup finds a file that neither ends in `.automerge` nor matches the temporary pattern
- **THEN** it ignores the file according to the documented adapter policy

#### Scenario: Malformed snapshot filename
- **WHEN** startup finds a filename ending in `.automerge` whose stem is not exactly a canonical lowercase hyphenated UUID
- **THEN** opening fails with a structured error containing that path

#### Scenario: Corrupt snapshot
- **WHEN** a canonical document file cannot be strictly loaded by Automerge
- **THEN** repository opening fails with a structured error containing the document ID and path and does not overwrite the file

### Requirement: Fixed bootstrap control encoding
The bootstrap control file SHALL be exactly 24 bytes containing magic `FIBC`, big-endian `u16` version 1, a state byte (`0` Creating, `1` Joining, `2` Ready), a zero reserved byte, and 16 root `DocumentId` bytes.

#### Scenario: Control round trip
- **WHEN** any supported bootstrap record is encoded and decoded
- **THEN** its state and root ID are preserved exactly

#### Scenario: Invalid control length
- **WHEN** the control file length differs from 24 bytes
- **THEN** loading fails with a structured error containing the control path

#### Scenario: Invalid control fields
- **WHEN** magic, version, state, or reserved value is invalid
- **THEN** loading fails with a structured error containing the control path and field context

#### Scenario: Corrupt control file preservation
- **WHEN** an existing control file is invalid
- **THEN** repository opening fails without deleting or replacing it

### Requirement: Filesystem execution and permissions
The filesystem adapter SHALL execute blocking filesystem work outside Tokio executor worker threads and SHALL use restrictive file and directory permissions where the platform supports them.

#### Scenario: Blocking operation
- **WHEN** a filesystem read, write, synchronization, or directory scan is requested
- **THEN** the adapter performs the blocking work through Tokio's blocking execution facility

#### Scenario: Unix permissions
- **WHEN** repository directories, snapshots, control records, or temporary files are created on Unix
- **THEN** directories are restricted to the owning user and files are readable and writable only by the owning user
