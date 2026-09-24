## Purpose

TBD: Define the shared Flutter form surface that presents create and edit forms as a bottom sheet on phones and a dialog on wider screens, including header actions, aside panel, and form-level messages.

## Requirements

### Requirement: Adaptive form presentation
Flutter SHALL present create and edit forms through one shared form surface. When the screen width is below 720 logical pixels the surface SHALL be a bottom sheet; otherwise it SHALL be a dialog. The record editor, widget editor, collection create/rename form, batch field editor, and computed-field editor MUST use this surface.

#### Scenario: Phone opens a create form
- **WHEN** the screen is 390px wide and the user taps "Add widget"
- **THEN** the widget editor opens as a bottom sheet, not a dialog

#### Scenario: Desktop opens a create form
- **WHEN** the screen is 1280px wide and the user taps "New record"
- **THEN** the record editor opens as a dialog

#### Scenario: Collection form on a phone
- **WHEN** the screen is 390px wide and the user starts "New collection" or "Rename collection"
- **THEN** the form opens as a bottom sheet

#### Scenario: Computed-field editor on a phone
- **WHEN** the screen is 390px wide and the user opens "New computed field"
- **THEN** the editor opens as a bottom sheet with the drag handle, title, and Cancel / Save footer of the form surface, not as a full-screen dialog

#### Scenario: Computed-field editor on desktop
- **WHEN** the screen is 1280px wide and the user edits an existing computed field
- **THEN** the editor opens as a form-surface dialog with Cancel and Save right-aligned

### Requirement: Phone sheet layout
On a phone, the form surface SHALL show a drag handle, the form title with an optional context line (for example "in Gym") on the same row, a scrollable body, and a footer with Cancel (one part width) beside the primary action (two parts width). Inputs in the body SHALL take their height from the shared input size tokens (normal is 48px on a phone); the surface MUST NOT override input padding. The sheet MUST clear both the on-screen keyboard and the system navigation bar.

#### Scenario: Footer proportions
- **WHEN** a form surface is shown as a bottom sheet
- **THEN** the footer shows an outlined Cancel button and a primary button twice its width, both 48px tall

#### Scenario: Keyboard open
- **WHEN** the user focuses an input in the sheet and the keyboard opens
- **THEN** the focused input and the footer remain visible above the keyboard

#### Scenario: Phone inputs from tokens
- **WHEN** a record form with a text input and a select opens as a bottom sheet on a 390px-wide screen
- **THEN** both input boxes are 48px tall

### Requirement: Header actions
The form surface SHALL accept secondary actions for the header. On a phone these SHALL render as icon buttons with tooltips in the title row; on a dialog they SHALL render as text buttons before Cancel in the footer.

#### Scenario: Remove widget on a phone
- **WHEN** the user edits an existing widget on a phone
- **THEN** a "Remove widget" icon button appears in the sheet's title row and the footer holds only Cancel and Save

#### Scenario: Remove widget on desktop
- **WHEN** the user edits an existing widget on a 1280px-wide screen
- **THEN** a "Remove" text button appears in the dialog footer before Cancel

### Requirement: Aside panel
The form surface SHALL accept an optional aside (such as a live preview). On screens at least 820px wide the aside SHALL render as a 280px pane beside the form. On a phone the aside SHALL render pinned between the scrollable body and the footer, and it SHALL be hidden while the keyboard is open. Between 720px and 820px the aside SHALL render pinned below the body like on a phone.

#### Scenario: Widget preview on a phone
- **WHEN** the user opens "Add widget" on a 390px-wide screen and the keyboard is closed
- **THEN** a compact live preview of the tile is visible above the Cancel and Save buttons and updates as the form changes

#### Scenario: Preview yields to the keyboard
- **WHEN** the user focuses the widget title input on a phone
- **THEN** the pinned preview hides until the keyboard closes

#### Scenario: Widget preview on desktop
- **WHEN** the user opens "Add widget" on a 1280px-wide screen
- **THEN** the form and a 280px preview pane are shown side by side

### Requirement: Form-level message slot
The form surface SHALL provide one message slot rendered directly above the footer actions, in the error color, for messages that do not belong to a single input.

#### Scenario: Save fails without a field
- **WHEN** saving a form fails with an error that names no field
- **THEN** the message appears in the slot just above Cancel and the primary button, and the form stays open
