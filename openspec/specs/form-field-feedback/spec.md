## Purpose

TBD: Define how Flutter forms place Rust validation issues under fields or in a form-level slot, when validation runs, and how required fields are marked.

## Requirements

### Requirement: Errors placed under their field
When a validation issue names exactly one field, Flutter SHALL show its message directly below that field's input. The message text and its warning icon SHALL use the theme's red error color, the same color as the form-level slot, never a near-white or accent tone. When one field has several issues, each issue SHALL be shown on its own line below that input, all of them, with no bullets or list markers.

#### Scenario: One issue on one field
- **WHEN** the user saves a record whose Title is longer than the allowed 40 characters
- **THEN** "Must be 1–40 characters" appears below the Title input and nowhere else

#### Scenario: Message is red
- **WHEN** a field shows a validation issue
- **THEN** its message text and warning icon are drawn in the theme's error color (`Nocturne.error`)

#### Scenario: Several issues on one field
- **WHEN** a field has three issues
- **THEN** three lines appear below that input, one per issue, in the order Rust returned them

#### Scenario: Issues on several fields
- **WHEN** Title and Intensity each have one issue
- **THEN** each message appears below its own input

### Requirement: Form-level errors above the actions
An issue that names no field or more than one field SHALL be shown in the form-level slot directly above the Cancel and primary buttons, one line per issue. Failures that are not validation issues (for example persistence failures) SHALL use the same slot.

When a save attempt leaves one or more fields with errors, the record editor SHALL scroll the first field with an error, in form order, into view and focus it, without further user action. This SHALL happen only in response to pressing the primary action, not on the re-validation that runs while the user edits.

When a save attempt leaves one or more fields with errors, the slot SHALL also show a summary pinned above the footer that stays visible while the form scrolls, reading "Couldn't save. N field(s) need attention." with a "Show" action that scrolls to the first field with an error, in form order, and focuses it. The summary SHALL disappear once no field has an error. Field errors SHALL be shown with an accent border on the control, a warning icon and the message.

#### Scenario: Cross-field issue
- **WHEN** Rust returns an issue naming both Start and End
- **THEN** its message appears once in the form-level slot above the buttons, not under either input

#### Scenario: Save jumps to the first error
- **WHEN** the user scrolls to the bottom of a long record form and presses Save while a field near the top is missing
- **THEN** the form scrolls that field into view and focuses it

#### Scenario: Editing does not move the form
- **WHEN** after a failed save the user edits another field and the debounced re-validation still reports an error on an earlier field
- **THEN** the scroll position and focus stay where the user left them

#### Scenario: Summary jumps to the first error
- **WHEN** the user saves a form in which "text multiline" is missing and "date" is out of range
- **THEN** the pinned summary reads "Couldn't save. 2 fields need attention.", and pressing Show scrolls to "text multiline" and focuses it

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

### Requirement: Date bounds read as dates
When a Date or Date & time value is outside its field's range, the error under the field SHALL name the bound as a date (Date) or date and time (Date & time) in the same text format the input uses, never as a raw number. A minimum alone SHALL read "Must be on or after <bound>", a maximum alone "Must be on or before <bound>", and both "Must be between <min> and <max>". Other bounded types keep "Must be at least", "Must be at most" and "Must be between". The text SHALL be shown in the active language.

#### Scenario: Date before the minimum
- **WHEN** a Date field has the minimum 2026-01-01 and the user saves the value 2025-12-30
- **THEN** "Must be on or after 2026-01-01" appears under the field

#### Scenario: Date & time after the maximum
- **WHEN** a Date & time field has only a maximum of 2026-12-31 18:00 and the user saves a later value
- **THEN** "Must be on or before 2026-12-31 18:00" appears under the field

#### Scenario: Integer keeps its wording
- **WHEN** an Integer field with the minimum 5 is saved with 2
- **THEN** "Must be at least 5" appears under the field

#### Scenario: Spanish
- **WHEN** the interface is in Spanish and a Date field with the minimum 2026-01-01 is saved with 2025-12-30
- **THEN** the error reads "Debe ser el 2026-01-01 o posterior"
