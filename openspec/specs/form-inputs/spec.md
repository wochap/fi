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
Feature code SHALL build text, integer, decimal, search, select, slider, and Date / DateTime / time picker inputs only through the shared inputs (`FiTextInput`, `FiSelect`, `FiPickerInput`, `FiSlider`). Every shared input of a given size and screen class except `FiSlider` SHALL render an input box of the same height, whatever its kind, label, value, prefix, or suffix. Switches, checkboxes, and buttons are not inputs under this requirement. `FiSlider` is a composite control: it SHALL take the height its track and its label row need, SHALL keep the same label, required-marker, helper, and error handling as the other shared inputs, and is exempt from the equal-height rule only.

A `FiSlider` SHALL take integer minimum and maximum bounds, an optional positive integer step that defaults to 1 and divides the distance between the bounds exactly, and an optional integer value. It SHALL move only between values of the form `minimum + k * step` inside the bounds, SHALL show the current value as text beside the track, and SHALL always show the track. Below the track it SHALL show one label row: one label per step position, from the minimum to the maximum, each centred under its position, when every label fits in the track width without overlapping; otherwise the row SHALL show only the minimum under the leading end and the maximum under the trailing end. The bounds are therefore always readable, and no label is ever shown twice. Error lines and helper text SHALL render below the label row. When the value is absent it SHALL show the track with no thumb and a placeholder in place of the value label, and the first tap or drag on the track SHALL set the value to the nearest step position. When clearing is allowed, a set value SHALL offer a way to return to unset. It SHALL report only integers inside the bounds that lie on a step position and MUST NOT expose a floating-point value to feature code.

#### Scenario: New field panel aligns
- **WHEN** the schema sheet's "New field" panel shows the Name text input beside the Type select
- **THEN** their input boxes have the same height and their tops align

#### Scenario: Computed-field editor aligns
- **WHEN** the computed-field editor shows the Name input and an expression node's select and Number inputs
- **THEN** Name has the normal height, and the node's select and Number inputs share the small height

#### Scenario: Picker input with an action
- **WHEN** a Date input shows a "Today" action and a clear icon in its suffix
- **THEN** its box height equals a plain text input of the same size

#### Scenario: Slider aligns with a text input
- **WHEN** a normal `FiSlider` is rendered beside a normal `FiTextInput` on the same screen
- **THEN** their labels and track tops align with the text input's box top, and the slider extends below it by its label row

#### Scenario: Full label row when every step fits
- **WHEN** a `FiSlider` with bounds 0 and 100 and step 10 is rendered wide enough for eleven labels
- **THEN** one row below the track shows 0, 10, 20 ... 100 centred under their step positions, and no other bound label is shown

#### Scenario: Only the bounds when steps would overlap
- **WHEN** a `FiSlider` with bounds 0 and 100 and step 1 is rendered at a width where 101 labels cannot fit
- **THEN** the row below the track shows only 0 under the leading end and 100 under the trailing end

#### Scenario: Bounds shown while unset
- **WHEN** a `FiSlider` with bounds 1 and 5 is rendered with no value
- **THEN** the label row is shown under the track with 1 at the leading end and 5 at the trailing end, whether as part of the full row or on their own

#### Scenario: Errors render under the label row
- **WHEN** a `FiSlider` receives an error line
- **THEN** the error appears below the label row and the track position does not move

#### Scenario: Slider reports whole numbers only
- **WHEN** a `FiSlider` with bounds 1 and 5 is dragged to a position between 3 and 4
- **THEN** the thumb snaps to 3 or 4, the value label shows that integer, and feature code receives that integer

#### Scenario: Slider moves in its step
- **WHEN** a `FiSlider` with bounds 0 and 100 and step 10 is dragged to a position between 30 and 40
- **THEN** the thumb snaps to 30 or 40, the value label shows that integer, and feature code receives that integer

#### Scenario: Slider starts unset
- **WHEN** a `FiSlider` is rendered with no value
- **THEN** it shows the track with no thumb and a placeholder instead of a value label, offers no "Set" action, and reports no value until the user touches the track

#### Scenario: Touching an unset track sets the value
- **WHEN** the user taps an unset `FiSlider` with bounds 1 and 5 near the middle of the track
- **THEN** the thumb appears at 3, the value label shows 3, and feature code receives 3

#### Scenario: Optional slider clears back to unset
- **WHEN** a `FiSlider` that allows clearing holds a value and the user taps its clear icon
- **THEN** the track shows no thumb again and feature code receives a null value

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
