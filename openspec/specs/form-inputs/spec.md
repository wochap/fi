## Purpose

TBD: Define the shared Flutter input widgets (`FiTextInput`, `FiSelect`, `FiPickerInput`), their two size tokens, fixed box height, and built-in required-marker and error-line handling.

## Requirements

### Requirement: Input size tokens
Flutter SHALL define exactly two input sizes. Small SHALL be 32 logical pixels tall on screens at least 720px wide and 40px on narrower screens. Normal SHALL be 40px on screens at least 720px wide and 48px on narrower screens. Form fields SHALL use normal; inline builder rows (expression builder nodes, query builder conditions) SHALL use small.

#### Scenario: Desktop form field
- **WHEN** a text input and a select of size normal are rendered on a 1280px-wide screen
- **THEN** both input boxes are 40px tall

#### Scenario: Phone form field
- **WHEN** the same inputs are rendered on a 390px-wide screen
- **THEN** both input boxes are 48px tall

#### Scenario: Inline builder row
- **WHEN** the expression builder shows a field picker beside a Number constant on a 1280px-wide screen
- **THEN** both are 32px tall

### Requirement: Shared input widgets
Feature code SHALL build text, integer, decimal, search, select, and Date / DateTime / time picker inputs only through the shared inputs (`FiTextInput`, `FiSelect`, `FiPickerInput`). Every shared input of a given size and screen class SHALL render an input box of the same height, whatever its kind, label, value, prefix, or suffix. Switches, checkboxes, and buttons are not inputs under this requirement.

#### Scenario: New field panel aligns
- **WHEN** the schema sheet's "New field" panel shows the Name text input beside the Type select
- **THEN** their input boxes have the same height and their tops align

#### Scenario: Computed-field editor aligns
- **WHEN** the computed-field editor shows the Name input and an expression node's select and Number inputs
- **THEN** Name has the normal height, and the node's select and Number inputs share the small height

#### Scenario: Picker input with an action
- **WHEN** a Date input shows a "Today" action and a clear icon in its suffix
- **THEN** its box height equals a plain text input of the same size

### Requirement: Fixed box, growing messages
A shared input's box height SHALL be fixed by its size, independent of content padding, label, or font metrics. Error lines SHALL render below the box and SHALL add height below it without changing the box. A multiline text input SHALL fix the height of its first line to the size's box height and grow by whole lines up to its maximum line count.

#### Scenario: Error does not resize the box
- **WHEN** a normal text input beside a normal select gains a two-line error
- **THEN** both boxes keep the same height and top alignment, and the two error lines appear under the text input

#### Scenario: Multiline grows from the base height
- **WHEN** a multiline Text field is empty and the user then enters three lines
- **THEN** it starts at the normal height and grows to fit three lines

### Requirement: Required marker and error lines applied once
The shared inputs SHALL accept a required flag and a list of error lines and SHALL apply the existing required-marker and error rules themselves: the `*` marker via `requiredLabel`, and one line per issue via `errorTextOf` / `errorLinesOf`. Feature code MUST NOT rebuild this wiring on an `InputDecoration`.

#### Scenario: Required select
- **WHEN** a `FiSelect` is created with required set and no errors
- **THEN** its label ends with the accent `*` and reads "<label>, required" to screen readers

#### Scenario: Several issues on one input
- **WHEN** a `FiTextInput` receives two error lines
- **THEN** it shows both lines under the box, in order, in the error color
