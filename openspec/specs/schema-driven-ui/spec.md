## Purpose

TBD: Define collection navigation, schema editing, registry-driven field controls, generic forms, and projection-driven refresh.

## Requirements

### Requirement: Collection list and navigation
The Flutter application SHALL show active user-defined collections and open a generic collection screen containing its record list, add action, and schema/settings access.

#### Scenario: Open Headache collection
- **WHEN** the user selects the Headache collection
- **THEN** the screen is constructed from its synchronized schema without a Headache-specific page

### Requirement: Confirmed collection deletion
Deleting a collection from the collection list SHALL require confirmation in a dialog before any delete command is sent. The dialog SHALL name the collection and state what is deleted with it, including the counts of its active records, widgets and saved queries when they are available, omitting zero counts. Cancelling or dismissing the dialog SHALL send no command.

#### Scenario: Confirm with counts
- **WHEN** the user chooses Delete on the "Gym" collection, which has 142 records, 3 widgets and 2 saved queries
- **THEN** a dialog titled "Delete "Gym"?" states that 142 records, 3 widgets and 2 saved queries are deleted with it, with Cancel and Delete actions

#### Scenario: Zero counts omitted
- **WHEN** the collection has 5 records, no widgets and no saved queries
- **THEN** the dialog mentions only the 5 records

#### Scenario: Empty collection
- **WHEN** the collection has no records, widgets or saved queries
- **THEN** the dialog states that the collection is empty

#### Scenario: Counts unavailable
- **WHEN** the counts are still loading or failed to load
- **THEN** the dialog states generically that its records, widgets and saved queries are deleted with it, and Delete remains usable

#### Scenario: Cancel
- **WHEN** the user presses Cancel or dismisses the dialog
- **THEN** no delete command is sent and the collection remains listed

#### Scenario: Confirm
- **WHEN** the user presses Delete in the dialog
- **THEN** Flutter sends the collection delete command and the collection leaves the list after the projection refreshes

### Requirement: Functional schema editor
Flutter SHALL provide create, rename, logical-delete, add-field, edit-field, remove-field, and reorder workflows for supported schema metadata, while Rust remains the authoritative validator. Enum option maintenance SHALL be part of the field editor rather than a separate workflow. When the field editor has Required on, no default, and the collection contains active records lacking the field, the editor SHALL show an inline warning stating how many records will become invalid, and the save action SHALL open a confirmation dialog stating that count before the schema command is submitted. The count SHALL be derived from the projected record list already loaded for the collection.

Schema metadata that holds a value of the field's own type — the default and the minimum and maximum bounds — SHALL be edited with the same typed control the record editor uses for that type, never as the raw stored integer, and each such control SHALL offer an explicit unset state because the slot is optional whatever the field requires of records. Changing the field type or the decimal scale SHALL clear those slots rather than reinterpret them.

Every field kind SHALL be shown to the user by a human label — Text, Integer, Decimal, Boolean, Date, Date & time, Duration, Choice — in the type selector, in the field list, and in any other place a kind is named. Generated identifiers such as `enum_` or `fixedDecimal` MUST NOT appear in the UI.

When the kind is Choice, the field editor SHALL show an inline options section listing the option labels in order with add, rename, remove, and drag reorder. Edits to options SHALL be held in the editor and committed on Save together with the field, for a new field and for an existing one alike; Cancel SHALL discard them. The default selector for a Choice field SHALL offer the options currently held in the editor, including ones not yet saved.

On Save the editor SHALL submit the field definition, then the option changes as individual option commands (create, rename or reorder, remove), then, when the chosen default is an option created by this save, a second field update carrying the option ID returned for it. Options left unchanged SHALL NOT be resubmitted.

#### Scenario: Rust rejects schema edit
- **WHEN** a submitted field definition violates a core validation rule
- **THEN** the editor remains open and displays the typed field-safe error without local authoritative insertion

#### Scenario: Required without default over existing records
- **WHEN** the user turns Required on for a field with an empty default while the collection has records lacking that field
- **THEN** an inline warning appears naming the number of records that will become invalid, and it disappears when a default is entered, Required is turned off, or no record lacks the field

#### Scenario: Confirm before making records invalid
- **WHEN** the user taps Save while the inline warning is showing
- **THEN** a confirmation dialog states the number of records that will be marked invalid; confirming submits the schema command and cancelling returns to the editor with values intact

#### Scenario: Default and bounds are typed, not raw
- **WHEN** the user edits the default, minimum, or maximum of a Date, DateTime, or FixedDecimal field
- **THEN** the control is the typed editor for that field — a date picker for a Date, an exact decimal box stating the scale for a FixedDecimal — and the value submitted is the stored integer the bound is compared as, with no epoch number or scaled integer typed by hand

#### Scenario: An optional slot can be left unset
- **WHEN** the field type is Boolean or Choice, or a date default has already been picked
- **THEN** the control offers an explicit unset choice, so a boolean default reads None, True, or False, a Choice default is chosen by option label with a None entry, and a picked date can be cleared

#### Scenario: Retyping a field drops metadata typed for the old type
- **WHEN** the user changes the field type, or the decimal scale, after entering a default or a bound
- **THEN** those slots are cleared, so no value is submitted meaning something other than what was typed

#### Scenario: No confirmation when nothing becomes invalid
- **WHEN** the user saves a required field with a default, or a required field in a collection with no records lacking it
- **THEN** the schema command is submitted without a confirmation dialog

#### Scenario: Kind labels are human
- **WHEN** the user opens the type selector or reads the field list
- **THEN** kinds read Text, Integer, Decimal, Boolean, Date, Date & time, Duration, and Choice, and a Choice row lists its option labels in order

#### Scenario: Create a Choice field with options and a default in one save
- **WHEN** the user picks Choice, adds options "Low", "Medium", "High", chooses "Medium" as the default, and taps Save
- **THEN** the field is created, three option commands follow with orders 0, 1, 2, and a final field update sets the default to the ID returned for "Medium"; the field list then shows "Choice · Low, Medium, High"

#### Scenario: Edit options of an existing Choice field
- **WHEN** the user renames "Medium" to "Mid", drags "High" above "Low", removes "Low", and taps Save
- **THEN** exactly three option commands are submitted — a rename for "Mid", a reorder for "High", and a remove for "Low" — and no command is sent for an option that did not change

#### Scenario: Cancel discards option edits
- **WHEN** the user adds or removes options and taps Cancel
- **THEN** no field or option command is submitted and the stored options are unchanged

#### Scenario: Removing the default option clears the default
- **WHEN** the user removes the option currently chosen as the default
- **THEN** the default selector returns to None before Save

#### Scenario: Option write rejected after the field saved
- **WHEN** Rust rejects one option command after the field definition was accepted
- **THEN** the editor stays open with the typed error and the user's option edits intact, and a later Save resubmits only the options that still differ from the stored ones

#### Scenario: Single entry point for options
- **WHEN** the user looks for a way to edit a Choice field's options
- **THEN** the only path is opening the field in the field editor; there is no separate options dialog or icon on the field row

### Requirement: Registry-driven field rendering
A Flutter field renderer registry SHALL map supported field kinds to editor and display components, and generic forms MUST NOT use domain-specific Headache or Money implementations.

#### Scenario: Render supported controls
- **WHEN** a schema contains Text, Integer, FixedDecimal, Boolean, Date, DateTime, Duration, and Enum fields
- **THEN** the generic form renders the registered text, numeric, decimal, switch, picker, duration, and selection controls

#### Scenario: Unsupported future field type
- **WHEN** a device reads a field type it cannot render
- **THEN** it shows a non-destructive unsupported-field placeholder and preserves the definition

### Requirement: Generic record CRUD experience
The generated collection experience SHALL create, edit, view, logically delete, and list records using stable field IDs and typed values obtained through the bridge. Records projected as invalid SHALL be visibly marked in the list with an indicator and their diagnostics, and opening such a record for editing SHALL present the missing required field as needing a value.

#### Scenario: Create Headache record
- **WHEN** the user completes a schema-generated Headache form
- **THEN** Flutter submits a generic typed record command and reloads the projected record after success

#### Scenario: Edit one field
- **WHEN** the user changes one field in an existing record
- **THEN** Flutter submits field-specific updates rather than replacing the record

#### Scenario: Invalid record in list
- **WHEN** the record list contains a record with `valid = false` and a missing-required diagnostic
- **THEN** the row shows an invalid indicator and the diagnostic text, and opening it highlights the missing field

### Requirement: Exact FixedDecimal editor
The FixedDecimal editor SHALL accept signed decimal text appropriate to the field scale and serialize an exact scaled integer without using binary floating-point as authoritative state.

#### Scenario: Enter Money amount
- **WHEN** the user enters `-23.50` in a scale-two field
- **THEN** the form submits representation `-2350` and displays the projected value as `-23.50`

### Requirement: Sensible record list defaults
The collection screen SHALL select deterministic generic primary/secondary display and ordering defaults from active schema fields, with stable-ID tie breaking when metadata is equal.

#### Scenario: No explicit list configuration
- **WHEN** a new schema has records but no chosen display fields
- **THEN** the UI lists them predictably using active field order and record ID fallback

### Requirement: Reactive projection refresh
Collection and record controllers SHALL react to typed data/projection events by rereading SQLite-backed queries, and stream lag SHALL recover through a complete refresh.

#### Scenario: Remote record arrives
- **WHEN** synchronization advances the projection for the visible collection
- **THEN** its generic record list refreshes without reading Automerge directly

### Requirement: Multi-select record actions
The generic collection screen SHALL offer a selection mode in which the user selects multiple records, sees the selected count, and applies a batch delete or a batch edit that sets one active field to one typed value on every selected record. Both batch actions SHALL require confirmation in a dialog that states the number of affected records, SHALL submit a single batch command through the bridge, and SHALL report the affected count after success. Single-record delete from the list SHALL remain immediate with no confirmation. Selection SHALL be cleared after a batch completes and SHALL drop records that disappear from the projected list.

#### Scenario: Enter selection and batch delete
- **WHEN** the user long-presses a record, selects two more, and taps Delete
- **THEN** a dialog reads "Delete 3 records?", confirming submits one batch delete, the list refreshes without those records, and feedback shows "3 records deleted"

#### Scenario: Batch edit one field
- **WHEN** the user selects records, chooses the `category` field, enters a value with that field's registered editor, and confirms "Set category on 4 records?"
- **THEN** Flutter submits one batch field-set command and the four records show the new value after refresh

#### Scenario: Cancel keeps selection
- **WHEN** the user dismisses the confirmation dialog
- **THEN** no command is sent and the selection is unchanged

#### Scenario: Rust rejects the batch
- **WHEN** the batch is rejected because a selected record was deleted remotely or the value violates the field definition
- **THEN** the screen shows the typed error, no record changes, and the selection is pruned to records still present

#### Scenario: Single delete unchanged
- **WHEN** the user taps the delete icon on one record outside selection mode
- **THEN** the record is deleted immediately with no confirmation dialog

### Requirement: Structured computed-field editor
Flutter SHALL provide a computed-field editor, reachable from the collection's computed-field list for both creating a new field and editing an existing one, that collects a name and a structured expression through a builder limited to source-field references, typed numeric constants, addition, subtraction, multiplication, division with an output scale and rounding policy, and absolute value. The editor SHALL obtain the output type and nullability from Rust inference on every expression change and display them; the user MUST NOT be asked to choose a declared type. When Rust rejects the expression the editor SHALL show the typed error at the offending node and keep the save action disabled. Saving an existing field SHALL issue an in-place update for its stable ID.

#### Scenario: Build a product of two decimals
- **WHEN** the user names a field, selects `amount`, chooses `*`, selects `rate`, and both are FixedDecimal
- **THEN** the editor shows "FixedDecimal, scale (sum of the two scales), may be empty if either source is optional" and enables Save

#### Scenario: Incompatible scales are explained at the node
- **WHEN** the user adds a scale-two decimal field to a scale-three decimal field
- **THEN** the editor marks the `+` node with the Rust error, keeps Save disabled, and offers no local guess at a result type

#### Scenario: Division collects its policy
- **WHEN** the user chooses `/`
- **THEN** the editor requires an output scale and a rounding choice (reject inexact or round half to even) before the expression is submitted for inference

#### Scenario: Edit an existing computed field
- **WHEN** the user taps an existing computed field in the list
- **THEN** the editor opens pre-filled with its name and expression tree, and saving submits an update for the same ID rather than creating a new field

#### Scenario: Definition from an unsupported expression version
- **WHEN** an existing computed field carries an expression the current client cannot decode
- **THEN** the list shows it as not editable with its diagnostic and the editor does not open for it

### Requirement: Computed-field explainer
The computed-field section and editor SHALL include an on-demand explainer, opened from a "?" affordance, that states in plain language that a computed field derives a value from the record's own fields on this device and is never synchronised as data, and that summarises the numeric rules the builder enforces.

#### Scenario: Open the explainer
- **WHEN** the user taps the "?" next to "Computed fields"
- **THEN** a dismissible popup shows the explanation and the numeric rules without leaving the dialog

### Requirement: Date and DateTime quick fill
The registered Date editor SHALL offer a "Today" action and the registered DateTime editor SHALL offer a "Now" action wherever a record value is entered: the new-record form, the edit-record form, and the batch field editor. "Today" SHALL fill the device's local calendar day. "Now" SHALL fill the current instant truncated to the minute. Either action SHALL update the input text and emit the typed value exactly as a picker selection would, so validation timing and draft validation behave the same. The actions MUST NOT appear in schema metadata slots (field default, minimum, maximum), where they would freeze the moment the schema was edited.

#### Scenario: Today on a new record
- **WHEN** the device's local date is 2026-09-24 at 23:30 in UTC-5 and the user taps "Today" on a Date field in the new-record form
- **THEN** the input shows 2026-09-24 and the submitted value is the day count of 2026-09-24, not 2026-09-25

#### Scenario: Now on a DateTime field
- **WHEN** the user taps "Now" on a DateTime field at local 14:05:37
- **THEN** the input shows today's date with 14:05, and the submitted value is that local minute converted to UTC epoch milliseconds with zero seconds

#### Scenario: Not offered for a default
- **WHEN** the user edits the default, minimum, or maximum of a Date or DateTime field in the schema editor
- **THEN** no "Today" or "Now" action is shown and the picker remains the only way to choose a value

#### Scenario: Replacing an existing value
- **WHEN** a record already has a DateTime value and the user taps "Now" while editing it
- **THEN** the input shows the new time and saving submits a field update for that field only

### Requirement: Local DateTime editor text
The DateTime editor SHALL show its current value as local time in the sortable form `yyyy-MM-dd HH:mm`, both when opened with an existing value and after a picker or "Now" selection.

#### Scenario: Opening an existing value
- **WHEN** a record stores the instant 2026-09-25 04:00 UTC and the device is in UTC-5
- **THEN** the editor shows `2026-09-24 23:00`

### Requirement: Inline collection title rename
The collection screen SHALL let the user rename the collection by editing its title in place. A double tap (or double click) on the title SHALL replace it with a text input holding the current name, focused, with the whole name selected. Pressing Enter or moving focus away from the input SHALL submit the edit; pressing Escape SHALL cancel it and restore the title.

On submit the text SHALL be trimmed of leading and trailing whitespace. When the trimmed text is empty, or equal to the current name, the edit SHALL be treated as a cancel: no rename command is sent and no error is shown. Otherwise the existing rename command SHALL be sent with the trimmed name, and the title SHALL show the new name once the projection refreshes.

When the rename command is rejected, the title SHALL return to the previous name and the error SHALL be reported to the user without keeping the input open.

The Rename action on the collection list card menu SHALL remain available.

#### Scenario: Double tap enters edit mode
- **WHEN** the user double taps the title "Headaches" on the collection screen
- **THEN** the title is replaced by a focused text input containing "Headaches" with the text selected, on both the wide and the narrow header layouts

#### Scenario: Enter saves the trimmed name
- **WHEN** the user replaces the text with "  Migraines " and presses Enter
- **THEN** a rename command is sent with "Migraines", the input closes, and the title shows "Migraines"

#### Scenario: Losing focus saves
- **WHEN** the user changes the text to "Migraines" and focus moves away from the input
- **THEN** the rename command is sent with "Migraines" and the input closes

#### Scenario: Escape cancels
- **WHEN** the user changes the text and presses Escape
- **THEN** no rename command is sent and the title shows the previous name

#### Scenario: Empty name cancels silently
- **WHEN** the user clears the text, or leaves only whitespace, and presses Enter or moves focus away
- **THEN** no rename command is sent, no error is shown, and the title shows the previous name

#### Scenario: Unchanged name cancels silently
- **WHEN** the user submits the current name unchanged, with or without surrounding whitespace
- **THEN** no rename command is sent and the input closes

#### Scenario: Rejected rename restores the title
- **WHEN** the rename command fails
- **THEN** the input closes, the title shows the previous name, and the failure is reported in a snackbar

#### Scenario: List menu rename still works
- **WHEN** the user chooses Rename from a collection card menu on the collection list
- **THEN** the existing Rename dialog opens as before

### Requirement: Slider presentation for bounded Integer fields
The field editor SHALL show a "Show as slider" switch only when the kind is Integer. The switch SHALL be enabled only while both the minimum and the maximum are filled, and SHALL turn off when either bound is cleared or the field type changes. The record editor SHALL render an Integer field whose slider flag is set as the shared slider input with those bounds, and SHALL render it as the plain integer input when the flag is unset. Record lists SHALL display the value as a plain number regardless of the flag.

#### Scenario: Switch appears for Integer with bounds
- **WHEN** the user picks Integer and fills minimum 1 and maximum 5
- **THEN** the "Show as slider" switch is shown and enabled

#### Scenario: Switch disabled without bounds
- **WHEN** the kind is Integer and the maximum is empty
- **THEN** the switch is shown but disabled, and it reads as off

#### Scenario: Clearing a bound turns the slider off
- **WHEN** the slider switch is on and the user clears the minimum
- **THEN** the switch turns off and becomes disabled, and saving submits the field without the slider flag

#### Scenario: Retyping clears the slider
- **WHEN** the slider switch is on and the user changes the kind to Decimal
- **THEN** the switch disappears and the saved definition carries no slider flag

#### Scenario: Record editor renders the slider
- **WHEN** the user opens the record editor for a collection with an Integer field flagged as slider with bounds 1 and 5
- **THEN** that field is a slider with whole steps from 1 to 5 and a visible current value

#### Scenario: Optional slider field left unset
- **WHEN** an optional slider field is left in its unset state and the record is saved
- **THEN** the submitted value for that field is null

#### Scenario: Required slider field unset
- **WHEN** a required slider field is left unset and the user saves
- **THEN** the editor shows the typed missing-value error from Rust under the slider, as it does for other inputs

#### Scenario: Slider value in the list
- **WHEN** a record with slider value 3 is shown in the record list
- **THEN** the cell reads 3

### Requirement: Duplicate collection action
The collection list card menu SHALL offer a Duplicate action next to Rename and Delete. Choosing it SHALL open a dialog with a Name input prefilled with the source name followed by " (copy)". Save SHALL submit the clone command with the trimmed name; Cancel or dismissing the dialog SHALL send no command. A typed name error from Rust SHALL be shown inline on the Name input and the dialog SHALL stay open. On success the dialog SHALL close and the new collection SHALL appear in the list after the projection refreshes, without navigating into it.

#### Scenario: Duplicate with default name
- **WHEN** the user chooses Duplicate on "Headache" and presses Save without editing
- **THEN** a new collection "Headache (copy)" appears in the list with the same fields, queries and widgets and no records

#### Scenario: Duplicate with custom name
- **WHEN** the user replaces the prefilled name with "Migraine" and presses Save
- **THEN** the new collection is named "Migraine"

#### Scenario: Cancel
- **WHEN** the user presses Cancel or dismisses the dialog
- **THEN** no clone command is sent and the list is unchanged

#### Scenario: Rust rejects the name
- **WHEN** the user clears the name and presses Save
- **THEN** the dialog stays open and shows the typed name error under the Name input
