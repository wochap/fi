## Purpose

TBD: Define how Flutter forms place Rust validation issues under fields or in a form-level slot, when validation runs, and how required fields are marked.

## Requirements

### Requirement: Errors placed under their field
When a validation issue names exactly one field, Flutter SHALL show its message directly below that field's input, in the error color. When one field has several issues, each issue SHALL be shown on its own line below that input, all of them, with no bullets or list markers.

#### Scenario: One issue on one field
- **WHEN** the user saves a record whose Title is longer than the allowed 40 characters
- **THEN** "Must be 1–40 characters" appears below the Title input and nowhere else

#### Scenario: Several issues on one field
- **WHEN** a field has three issues
- **THEN** three lines appear below that input, one per issue, in the order Rust returned them

#### Scenario: Issues on several fields
- **WHEN** Title and Intensity each have one issue
- **THEN** each message appears below its own input

### Requirement: Form-level errors above the actions
An issue that names no field or more than one field SHALL be shown in the form-level slot directly above the Cancel and primary buttons, one line per issue. Failures that are not validation issues (for example persistence failures) SHALL use the same slot.

#### Scenario: Cross-field issue
- **WHEN** Rust returns an issue naming both Start and End
- **THEN** its message appears once in the form-level slot above the buttons, not under either input

#### Scenario: Persistence failure
- **WHEN** saving fails because local data could not be saved
- **THEN** the safe message appears in the form-level slot and the form stays open with the user's input intact

### Requirement: Validation timing
Flutter SHALL NOT show validation errors before the user first presses the primary action on a form. After that first attempt, every change to the form SHALL re-validate (debounced) and update the shown errors, so an error disappears as soon as its cause is fixed. A record opened for editing because it is invalid SHALL start in the attempted state.

#### Scenario: Pristine form
- **WHEN** the user opens "New record" for a collection with required fields
- **THEN** no error text is shown, only the required markers

#### Scenario: Error clears while typing
- **WHEN** the user pressed Save, saw "Required" under Title, and then types into Title
- **THEN** the "Required" line disappears without pressing Save again

#### Scenario: Invalid record opened from the list
- **WHEN** the user opens a record that the list marks invalid
- **THEN** the editor immediately shows the issue under the field at fault

### Requirement: Record drafts validated by Rust
Live validation of record forms SHALL use the Rust dry-run validation query, so Flutter does not duplicate record validation rules. The primary action SHALL stay enabled while issues exist; pressing it SHALL re-validate and show the issues.

#### Scenario: Live check uses Rust
- **WHEN** the user edits an Integer field after the first save attempt
- **THEN** Flutter calls the draft validation query and renders the issues it returns

#### Scenario: Save stays enabled
- **WHEN** the widget editor has no saved query chosen
- **THEN** Save remains enabled, and pressing it shows "Choose a saved query." under the query selector

### Requirement: Required field marker
Every input whose value is required SHALL show an `*` after its label in the `accent300` color, and SHALL expose "required" to assistive technologies. A form with at least one marked input SHALL show a single "* required" legend line. A required field that has a default value SHALL NOT be marked.

#### Scenario: Required text field
- **WHEN** a schema field is required and has no default
- **THEN** its input label reads "Title *" with the asterisk in `accent300`, and a screen reader announces it as required

#### Scenario: Required with default
- **WHEN** a schema field is required and has a default value
- **THEN** its input shows no asterisk

#### Scenario: Legend
- **WHEN** a form has any required input
- **THEN** exactly one "* required" legend line appears in the form
