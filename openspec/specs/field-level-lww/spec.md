## Purpose

TBD: Define deterministic field-level last-writer-wins resolution using durable hybrid logical clocks.

## Requirements

### Requirement: Deterministic HLC stamp
Every mutable synchronized application register SHALL carry a valid HLC stamp containing physical epoch milliseconds, a logical counter, and a durable node identifier, ordered lexicographically by those components.

#### Scenario: Equal time and counter
- **WHEN** two stamps have equal physical time and logical counter but different node identifiers
- **THEN** every device selects the value associated with the same greatest node identifier

### Requirement: Monotonic local HLC
The application owner SHALL own the mutable HLC, observe synchronized stamps, and generate a strictly later local stamp even when wall time is unchanged or moves backward. Counter or representation overflow MUST return a typed error.

#### Scenario: Wall clock moves backward
- **WHEN** the last observed physical time is greater than the current wall time
- **THEN** the next local stamp retains the greater physical component and increments its logical counter

#### Scenario: Observe remote future stamp
- **WHEN** a device observes a valid remote stamp ahead of its local clock
- **THEN** its next write is ordered after the observed stamp

### Requirement: Atomic register encoding
Each logical LWW value SHALL encode its payload and HLC stamp in one replaceable Automerge register object, and decoding MUST enumerate all conflicting register objects rather than trusting Automerge's default winner.

#### Scenario: Concurrent register objects
- **WHEN** two devices replace the same logical field while offline
- **THEN** decoding reads both candidates, validates each payload/stamp association, and selects the greatest HLC stamp

### Requirement: Field-level conflict resolution
Records SHALL store independently replaceable registers under stable field IDs so concurrent different-field writes compose and concurrent same-field writes resolve by HLC.

#### Scenario: Concurrent different fields
- **WHEN** Device A changes intensity and Device B changes notes on the same record while disconnected
- **THEN** synchronization preserves both changes

#### Scenario: Concurrent same field
- **WHEN** both devices change intensity while disconnected
- **THEN** both projections converge on the value with the greatest HLC stamp

### Requirement: Restart-safe HLC identity
Every application construction path SHALL provide a durable HLC node identity, production networked paths SHALL bind it to permanent device identity, and deterministic tests SHALL be able to inject identities and wall time.

#### Scenario: Restart after write
- **WHEN** a device restarts after emitting stamps
- **THEN** it observes authoritative stamps and cannot emit a new stamp ordered before its prior writes

### Requirement: Project resolved metadata
The read model SHALL store the winning field value together with its HLC components so tests and diagnostics can demonstrate which synchronized candidate was selected.

#### Scenario: Projection after conflict
- **WHEN** same-field concurrent values synchronize
- **THEN** SQLite contains the deterministic winning value and corresponding stamp on both devices

### Requirement: HLC semantic boundary
The application SHALL document that HLC provides causal monotonicity and deterministic total ordering but cannot establish perfect real-world chronology between disconnected devices with skewed clocks.

#### Scenario: Offline clock skew
- **WHEN** concurrent offline writes have different physical clock readings and no causal relationship
- **THEN** the defined HLC ordering determines the winner consistently without claiming knowledge of actual human edit order

### Requirement: Per-option membership registers for Choices
A Choices (EnumSet) record value SHALL be stored as one LWW register per option under the record's values, keyed by the field id and the option id, whose payload states whether the option is in the set. Each register SHALL carry its own HLC stamp and SHALL be decoded by enumerating all conflicting candidates and selecting the greatest stamp, as for any register. Writing a set SHALL write a register only for options whose membership changes, all under the command's stamp. The set SHALL be the options whose winning register says present. A record that still holds a single-value register for the field from before a Choice → Choices conversion SHALL read that register as membership of its option at its stamp (a Null register as no member), combined with the per-option registers by greatest stamp per option.

#### Scenario: Concurrent different options compose
- **WHEN** a record holds {"food"}, Device A adds "work" and Device B adds "urgent" while disconnected, then they sync
- **THEN** both devices read {"food", "work", "urgent"}

#### Scenario: Concurrent same option resolves by HLC
- **WHEN** a record holds {"food"}, Device A removes "food", and Device B removes "food" and then adds it back with a stamp greater than A's, both offline
- **THEN** after sync every device reads {"food"}, because B's register for "food" has the greater stamp

#### Scenario: Concurrent add and remove of different options
- **WHEN** Device A removes "food" and Device B adds "work" from {"food"} while disconnected
- **THEN** after sync every device reads {"work"}

#### Scenario: Legacy Choice value after conversion
- **WHEN** a record holds the single-value register "food" from before the field became Choices, and a later write adds "work"
- **THEN** the record reads {"food", "work"}
