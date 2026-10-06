## Purpose

TBD: Define collection navigation, schema editing, registry-driven field controls, generic forms, and projection-driven refresh.

## Requirements

### Requirement: Collection list and navigation
The Flutter application SHALL show active user-defined collections and open a generic collection screen containing its record list, add action, and schema/settings access.

Each collection in the list SHALL show its name and, on one subtitle line under the name on every width, its active record count, its active field count, and when it was last edited as a lowercase status time ("6 records · 3 fields · edited 2 h ago"), using the same status-time wording as device rows; a collection with no last-edited time ends the line after the field count. When one or more of its records are incomplete (projected invalid), the row SHALL also show an outline tag with a warning icon reading "N incomplete" beside the name on every width. On screens narrower than 720px the row SHALL be at least 64px tall.

The list header SHALL offer a sort control with two orders, "Last edited" (most recent first, the default) and "Name" (A–Z, case-insensitive), with ties broken by collection id. The chosen order SHALL be remembered on this device across restarts. The header SHALL offer the whole-dataset import/export menu between the sort control and "New collection": at 720px and wider as a labelled "Import and export" button, below 720px as an icon button that opens an action sheet. The menu SHALL hold "Import JSON…", "Export all" and "Export selected…". The header SHALL offer "New collection" ("New" below 720px).

Each row SHALL offer a menu with, in this order: Rename, Clone, a divider, an "Export" group with Export CSV and Export JSON, an "Import" group with Import CSV…, a divider, and Delete…. On screens at least 720px wide it SHALL be a popup menu and Rename SHALL show the F2 shortcut; pressing F2 while a collection row has focus SHALL start renaming it. Below 720px the menu SHALL open as an action sheet headed by the collection's icon, name, and "N records · N fields", with the same groups.

The collection screen header SHALL show a back action, the collection title, and "N records · N fields". At 720px and wider it SHALL offer Schema, Queries and Select as buttons, then a ⋮ button, then New record. The ⋮ menu SHALL hold Queries and Select records, a divider, Export CSV, Export JSON and Import CSV…, a divider, and Rename, Clone and Delete…; Rename SHALL start the inline title rename, and the other actions SHALL behave as the same actions on the list row. Below 720px the header SHALL offer Schema as an icon button and a ⋮ menu holding Queries, Select records and Collection actions… (which opens the same actions as the list row menu), and New record SHALL be the floating "Record" button. A long press on a record card SHALL also start selection.

#### Scenario: Open Headache collection
- **WHEN** the user selects the Headache collection
- **THEN** the screen is constructed from its synchronized schema without a Headache-specific page

#### Scenario: Row shows size and recency
- **WHEN** the collection "test" has 6 active records, 3 active fields and was last edited two hours ago
- **THEN** its row shows "test" and the subtitle "6 records · 3 fields · edited 2 h ago", and no incomplete tag, on both a 1240px-wide and a 390px-wide screen

#### Scenario: Row flags incomplete records
- **WHEN** the collection "tst" has one record projected invalid for a missing required field
- **THEN** its row shows an outline "1 incomplete" tag with a warning icon beside the name, and its subtitle still reads "1 record · 9 fields · edited just now"

#### Scenario: Sort by name is remembered
- **WHEN** the user switches the sort to Name and restarts the app
- **THEN** the list is ordered A–Z by name and the sort control reads "Name"

#### Scenario: Grouped row menu
- **WHEN** the user opens a row's menu on a 1240px-wide screen
- **THEN** it lists Rename (with F2) and Clone, then under "Export" Export CSV and Export JSON, then under "Import" Import CSV…, then Delete…, separated by dividers

#### Scenario: Action sheet on a phone
- **WHEN** the user taps a row's ⋮ on a 390px-wide screen
- **THEN** an action sheet opens headed by the collection name and "N records · N fields", with the same actions in the same groups

#### Scenario: Whole-dataset transfer stays reachable
- **WHEN** the collections list is shown on a 1240px-wide screen
- **THEN** a labelled "Import and export" button sits between the sort control and "New collection" and opens "Import JSON…", "Export all" and "Export selected…"

#### Scenario: Whole-dataset transfer on a phone
- **WHEN** the collections list is shown on a 390px-wide screen
- **THEN** an import/export icon button beside the sort control opens an action sheet with "Import JSON…", "Export all" and "Export selected…"

#### Scenario: Desktop collection menu
- **WHEN** a collection is opened on a 1240px-wide screen and the user presses the header ⋮
- **THEN** the menu lists Queries, Select records, Export CSV, Export JSON, Import CSV…, Rename, Clone and Delete…, and choosing Rename turns the title into its inline editor

#### Scenario: Mobile collection header
- **WHEN** a collection is opened on a 390px-wide screen
- **THEN** the top bar shows back, the title, "N records · N fields", a Schema icon button and a ⋮ menu with Queries, Select records and Collection actions…, and a floating "Record" button starts a new record

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
Flutter SHALL provide create, rename, logical-delete, add-field, edit-field, remove-field, and reorder workflows for supported schema metadata, while Rust remains the authoritative validator. Enum option maintenance SHALL be part of the field editor rather than a separate workflow. When the field editor has Required on, no default, and the collection contains active records lacking the field, the editor SHALL show an inline warning reading "<N> records have no value for this field and will be marked incomplete.", and the save action SHALL open a confirmation titled "Make “<field>” required?" with the body "<N> records have no value and will be marked incomplete.", a secondary "Make required" action on the left and a primary "Keep optional" action on the right, before the schema command is submitted. The count SHALL be derived from the projected record list already loaded for the collection.

Removing a field SHALL always ask first, from every entry point: the delete icon on a desktop schema row, the delete action of the desktop inline panel, and Delete field in the phone field screen's ⋮ menu. The confirmation SHALL be titled "Delete field “<field>”?" with the body "Removes the field from the schema. <N> records lose their value for it.", where N is the number of loaded active records holding a value for the field, or "Removes the field from the schema." alone when no record holds one. It SHALL offer a secondary "Delete field" action on the left and a primary "Keep field" action on the right. Confirming SHALL submit the logical field removal; keeping SHALL leave the schema unchanged and the editor or sheet as it was.

Schema metadata that holds a value of the field's own type — the default and the minimum and maximum bounds — SHALL be edited with the same typed control the record editor uses for that type, never as the raw stored integer, and each such control SHALL offer an explicit unset state because the slot is optional whatever the field requires of records. Changing the field type or the decimal scale SHALL clear those slots rather than reinterpret them.

Every field kind SHALL be shown to the user by a human label — Text, Integer, Decimal, Boolean, Date, Date & time, Duration, Choice — in the type selector, in the field list, and in any other place a kind is named. Generated identifiers such as `enum_` or `fixedDecimal` MUST NOT appear in the UI.

When the kind is Choice, the field editor SHALL show an inline options section listing the option labels in order with add, rename, remove, and drag reorder. Edits to options SHALL be held in the editor and committed on Save together with the field, for a new field and for an existing one alike; Cancel SHALL discard them. The default selector for a Choice field SHALL offer the options currently held in the editor, including ones not yet saved.

On Save the editor SHALL submit the field definition, then the option changes as individual option commands (create, rename or reorder, remove), then, when the chosen default is an option created by this save, a second field update carrying the option ID returned for it. Options left unchanged SHALL NOT be resubmitted.

At 720px and wider the schema editor SHALL be the side sheet headed by "<collection> · N fields" and "Collection schema". It SHALL list fields as rows with a drag handle, the field-type icon in a tile, the name with the required mark, a short summary (for example "Integer · 5–30", "Integer · 0–10 · slider" for an Integer shown as a slider, "Text · multiline", "Choice · stomachache, headache"), and a trailing chevron; hovering a row SHALL reveal a delete icon before the chevron. Below the rows a dashed secondary "Add field" button SHALL open the "New field" inline panel; editing an existing field SHALL open as an inline panel in the sheet. The footer SHALL read "Drag to reorder · click a field to edit" with Done. Below 720px the schema editor SHALL be a sheet of rows at least 52px tall, each with the field-type icon in a tile and ending in a chevron, followed by a dashed "Add field" button and a footer reading "Long-press to reorder" with Done. Tapping a row SHALL push a field screen titled with the field name and "Field in <collection>", with a back action, a ⋮ menu holding Delete field, and a "Save field" footer. "Add field" SHALL push the same screen titled "New field" with an "Add field" footer.

The field editor SHALL present the type as a grid of eight tiles in two rows of four, each with the type icon and human label. The type SHALL be fixed once the field exists, and the other tiles SHALL be shown disabled. Below the type the editor SHALL show option chips for the chosen type: Required for every type; Multiline and Length limits for Text; Range for Integer, Decimal and Duration; Show as slider for Integer; Date range for Date and Date & time; Default value for every type. Each chip SHALL have its `?` help button directly beside it in the chip row, whether the chip is on or off. A chip that is on SHALL show a check and open its settings block under the chips, headed by the chip's name with a ✕ that turns the chip off and clears its settings. Length limits SHALL show Min characters and Max characters side by side. Range and Date range SHALL show their two bounds side by side, labelled Earliest and Latest for dates. A Choice field SHALL always show its options section.

The editor SHALL check the default against the other settings while the user types: a Text default outside the length limits SHALL show a counter such as "2 / 4–8" and the line "Default must be 4–8 characters." under it, a default outside the range SHALL show the range it must fall in, and the save action SHALL be disabled while such a line is shown.

For a Date field the Default value block SHALL offer "Day of creation" or "Fixed date". "Day of creation" SHALL take a +/− sign and a whole number of days and SHALL show the date it resolves to today (for example "→ Oct 5, 2026").

Each option row SHALL have a drag handle, the label as an editable input, and a delete action. Deleting an option that active records use SHALL first ask for confirmation titled "Delete option “<label>”?" with the body "<N> records use it and keep it. It can't be picked for new records.", a secondary "Delete option" action on the left and a primary "Keep option" action on the right. Under the options the editor SHALL note that records using a deleted option keep it, shown as "<label> (deleted)", and that it can't be picked for new records.

#### Scenario: Rust rejects schema edit
- **WHEN** a submitted field definition violates a core validation rule
- **THEN** the editor remains open and displays the typed field-safe error without local authoritative insertion

#### Scenario: Required without default over existing records
- **WHEN** the user turns Required on for a field with an empty default while the collection has records lacking that field
- **THEN** an inline warning appears naming the number of records that will become invalid, and it disappears when a default is entered, Required is turned off, or no record lacks the field

#### Scenario: Confirm before making records invalid
- **WHEN** the user taps Save while the inline warning is showing
- **THEN** a confirmation titled "Make “code” required?" states "2 records have no value and will be marked incomplete."; "Make required" submits the schema command and "Keep optional" returns to the editor with values intact

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
- **THEN** kinds read Text, Integer, Decimal, Boolean, Date, Date & time, Duration, and Choice, and a Choice row summarizes its options

#### Scenario: Type grid and chips for a Date field
- **WHEN** the user adds a field named "due" and picks the Date tile
- **THEN** the chips read Required, Default value and Date range, and turning on Default value and Date range opens a block for each with a ✕

#### Scenario: Relative date default preview
- **WHEN** today is 2026-09-28 and the user sets the Date default to Day of creation + 7 days
- **THEN** the block shows "→ Oct 5, 2026" and saving submits a relative default of 7 days, not a fixed date

#### Scenario: Default checked against length limits
- **WHEN** a Text field has length limits 4 and 8 and the user types the default "AB"
- **THEN** the default shows "2 / 4–8" and "Default must be 4–8 characters.", and the save action is disabled until the default fits

#### Scenario: Type fixed for an existing field
- **WHEN** the user opens an existing Date field
- **THEN** the Date tile is selected and the other seven tiles are disabled

#### Scenario: Field screen on a phone
- **WHEN** the user taps the "due" row in the schema sheet on a 390px-wide screen
- **THEN** a pushed screen titled "due" and "Field in tst" shows the type grid, chips and blocks, a ⋮ with Delete field, and a "Save field" footer

#### Scenario: Deleting a used option asks first
- **WHEN** the user deletes the option "option 3" that two active records use
- **THEN** a confirmation titled "Delete option “option 3”?" states "2 records use it and keep it. It can't be picked for new records.", and "Delete option" removes it from the options list

#### Scenario: Create a Choice field with options and a default in one save
- **WHEN** the user picks Choice, adds options "Low", "Medium", "High", chooses "Medium" as the default, and taps Save
- **THEN** the field is created, three option commands follow with orders 0, 1, 2, and a final field update sets the default to the ID returned for "Medium"; the field list then shows "Choice · Low, Medium, High"

#### Scenario: Edit options of an existing Choice field
- **WHEN** the user renames "Medium" to "Mid", drags "High" above "Low", removes "Low" (confirming if records use it), and taps Save
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

#### Scenario: Deleting a field asks first
- **WHEN** the user hovers the "End at" row in the desktop schema sheet, two loaded records hold a value for it, and the user clicks its delete icon
- **THEN** a confirmation titled "Delete field “End at”?" reads "Removes the field from the schema. 2 records lose their value for it." with "Delete field" on the left and "Keep field" on the right, and no schema command has been submitted

#### Scenario: Keeping the field
- **WHEN** the delete-field confirmation is open and the user chooses "Keep field"
- **THEN** the confirmation closes, no command is submitted, and the field is still listed

#### Scenario: Deleting a field from the phone screen
- **WHEN** the user opens the "End at" field screen on a 390px-wide screen and picks ⋮ › Delete field, then "Delete field"
- **THEN** the field is removed logically, the field screen closes, and the sheet no longer lists "End at"

#### Scenario: Deleting a field no record uses
- **WHEN** the user deletes a field for which no loaded record holds a value
- **THEN** the confirmation body reads "Removes the field from the schema."

#### Scenario: Slider summary
- **WHEN** the schema sheet lists an Integer field with bounds 0 and 10 shown as a slider
- **THEN** its summary reads "Integer · 0–10 · slider"

#### Scenario: Help beside the Required chip
- **WHEN** the user opens the field editor for a Text field
- **THEN** a `?` button sits beside each of the Required, Multiline, Length limits and Default value chips, and tapping the one beside Required opens the Required help without turning the chip on

### Requirement: Registry-driven field rendering
A Flutter field renderer registry SHALL map supported field kinds to editor and display components, and generic forms MUST NOT use domain-specific Headache or Money implementations.

The record editor SHALL lay fields out with labels beside the controls in a 140px column at 720px and wider, and with labels above the controls, one field per row, below 720px. Each kind SHALL use one control:
- Text, Integer and Decimal use the text input; a Decimal shows its scale ("2 dp") as a suffix.
- An Integer with the slider flag uses the slider.
- A required Boolean uses a switch; an optional Boolean uses a Yes / No segmented choice that can be cleared.
- A Choice with 2–4 active options uses a segmented choice. With 5–10 active options it uses a select that opens a dropdown at 720px and wider and a picker sheet titled with the field name, with a Clear action when optional, below 720px. With more than 10 active options it uses a search input that filters by substring and highlights the match, opening in place at 720px and wider and as a full-height search sheet with a back action, the option count and Clear below 720px.
- Date and Date & time use the picker input.
- Duration uses the duration input.

A Choice value that holds a deleted option SHALL read "<label> (deleted)" in the record editor and in record lists, and the deleted option SHALL NOT be offered in any Choice control for picking.

#### Scenario: Render supported controls
- **WHEN** a schema contains Text, Integer, FixedDecimal, Boolean, Date, DateTime, Duration, and Enum fields
- **THEN** the generic form renders the registered text, numeric, decimal, switch or segmented boolean, picker, duration, and choice controls

#### Scenario: Choice control follows the option count
- **WHEN** a form has Choice fields with 3, 7 and 48 active options on a 390px-wide screen
- **THEN** the first is a segmented choice, the second opens a picker sheet, and the third opens a full-height search sheet that returns to the form after a pick

#### Scenario: Deleted option on an old record
- **WHEN** a record holds the Choice option "option 3", which was later deleted
- **THEN** the editor and the record list read "option 3 (deleted)", and "option 3" is not offered in the control

#### Scenario: Unsupported future field type
- **WHEN** a device reads a field type it cannot render
- **THEN** it shows a non-destructive unsupported-field placeholder and preserves the definition

### Requirement: Generic record CRUD experience
The generated collection experience SHALL create, edit, view, logically delete, and list records using stable field IDs and typed values obtained through the bridge. Records projected as invalid are incomplete and SHALL be marked in the list without relying on color alone:

- At 720px and wider, an incomplete row SHALL show a 2px accent edge at its leading side and a warning icon in its first cell, and each cell of a missing required field SHALL show an accent "Required" tag.
- Below 720px, an incomplete card SHALL show an outline "Incomplete" tag with a warning icon, and the missing field's line SHALL show a "Needed" marker in place of a value.

When a collection has incomplete records, a status line under the records SHALL read "N record is missing a required field. Click it to finish." at 720px and wider, or "N record is missing a required field" with "Tap it to finish." below 720px, pluralized for N greater than one.

Opening an incomplete record SHALL open the record editor scrolled to the first missing required field in form order, with keyboard focus in that field. The field SHALL show the Needed marker and the line "Needed to complete this record". The editor title SHALL add "· N field needed" at 720px and wider. Saving values for every missing field SHALL remove the record's incomplete marks after the projection refreshes.

The new-record editor SHALL be titled "New record" with "in <collection>". At 720px and wider its footer SHALL show "* Required · Ctrl+Enter to save" at the leading edge and Cancel and "Save record" at the trailing edge, and Ctrl+Enter SHALL save. Below 720px it SHALL be the bottom sheet with a close ✕ in the header and a full-width "Save record" footer.

The edit-record editor SHALL be titled "Edit record" with "in <collection> · created <date>" when the record has a creation time, and its primary action SHALL read "Save changes". At 720px and wider a "Delete…" text button SHALL sit at the leading edge of the footer, apart from Cancel and "Save changes". Below 720px a ⋮ in the header SHALL hold Duplicate and "Delete record…", and the footer SHALL hold only "Save changes". Delete SHALL ask for confirmation before logically deleting the record. Duplicate SHALL close the editor and open the new-record editor prefilled with this record's current values, without saving anything until the user saves.

#### Scenario: Create Headache record
- **WHEN** the user completes a schema-generated Headache form
- **THEN** Flutter submits a generic typed record command and reloads the projected record after success

#### Scenario: Edit one field
- **WHEN** the user changes one field in an existing record
- **THEN** Flutter submits field-specific updates rather than replacing the record

#### Scenario: Delete from the edit dialog
- **WHEN** the user presses "Delete…" in the edit dialog on a 1240px-wide screen and confirms
- **THEN** the record is logically deleted and the dialog closes; cancelling the confirmation leaves the dialog open with edits intact

#### Scenario: Duplicate on a phone
- **WHEN** the user chooses Duplicate from the edit sheet's ⋮ on a 390px-wide screen
- **THEN** the new-record sheet opens holding the same values, and no record is created until the user presses "Save record"

#### Scenario: Invalid record in list
- **WHEN** the record list on a 1240px-wide screen contains a record with `valid = false` and a missing-required diagnostic for "text multiline"
- **THEN** the row has an accent leading edge and a warning icon, its "text multiline" cell shows a "Required" tag, and the status line reads "1 record is missing a required field. Click it to finish."

#### Scenario: Invalid record on a phone
- **WHEN** the same record is listed on a 390px-wide screen
- **THEN** its card shows an "Incomplete" tag and its "text multiline" line shows "Needed", and the status line above the records reads "1 record is missing a required field" with "Tap it to finish."

#### Scenario: Finishing an incomplete record
- **WHEN** the user opens that record
- **THEN** the editor opens scrolled to "text multiline" with focus in it, the field shows "Needed" and "Needed to complete this record", and after the user saves a value the row's incomplete marks are gone

### Requirement: Exact FixedDecimal editor
The FixedDecimal editor SHALL accept signed decimal text appropriate to the field scale and serialize an exact scaled integer without using binary floating-point as authoritative state.

#### Scenario: Enter Money amount
- **WHEN** the user enters `-23.50` in a scale-two field
- **THEN** the form submits representation `-2350` and displays the projected value as `-23.50`

### Requirement: Sensible record list defaults
The collection screen SHALL select deterministic generic primary/secondary display defaults from active schema fields, with stable-ID tie breaking when metadata is equal. The default order SHALL be newest first by record creation time, with the record id as the tie breaker; a record without a creation time SHALL sort after those that have one, by record id.

At 720px and wider the records SHALL be shown as a table:
- It SHALL have one column per active field in form order.
- Each column header SHALL show the field-type icon, the field name, and the required mark for required fields.
- The first column SHALL stay pinned at the leading edge while the other columns, of equal fixed width, scroll horizontally.
- A "Scroll for more columns →" hint SHALL be shown while columns are hidden past the trailing edge, and the trailing edge SHALL fade into the background.
- Empty cells SHALL read "—" at reduced opacity.
- The header row SHALL stay visible while the rows scroll vertically.

Below 720px each record SHALL be a card showing up to its first three active fields in form order, each with its type icon, name and value, followed by "+ N more fields · <creation date>" when more fields exist, or by the creation date alone. The records section SHALL read "Newest first".

#### Scenario: No explicit list configuration
- **WHEN** a new schema has records but no chosen display fields
- **THEN** the UI lists them predictably, newest first by creation time, with record ID as the tie breaker

#### Scenario: Table keeps its first column
- **WHEN** a collection with nine fields is shown on a 1240px-wide screen and the user scrolls the table sideways
- **THEN** the first column and the header row stay in place, the other columns move, and the hint "Scroll for more columns →" is shown while columns remain hidden

#### Scenario: Typed column headers
- **WHEN** the table shows an Integer field "integer slider" and a required Text field "text multiline"
- **THEN** their headers show the `hash` icon with "integer slider" and the `text-aa` icon with "text multiline" and a required mark

#### Scenario: Mobile card
- **WHEN** a record with nine fields created on 22 Sep 2026 is listed on a 390px-wide screen
- **THEN** its card shows the first three fields with type icons and ends with "+ 6 more fields · Sep 22, 2026"

### Requirement: Reactive projection refresh
Collection and record controllers SHALL react to typed data/projection events by rereading SQLite-backed queries, and stream lag SHALL recover through a complete refresh.

#### Scenario: Remote record arrives
- **WHEN** synchronization advances the projection for the visible collection
- **THEN** its generic record list refreshes without reading Automerge directly

### Requirement: Multi-select record actions
The generic collection screen SHALL offer a selection mode in which the user selects multiple records, sees the selected count, and applies a batch delete or a batch edit that sets one active field to one typed value on every selected record. In selection mode the header SHALL become an action bar showing a close action, "N selected", "in <collection>" at 720px and wider, and Select all, "Edit field" and Delete (labelled buttons at 720px and wider, icon buttons below). Selected rows and cards SHALL show the accent tint, an accent outline or leading edge, and a checked box.

"Edit field" SHALL open "Edit field on N records" with a Field select and a "New value" input that uses the field's registered record-form control, with the line "Uses the same control as the record form.", and Cancel and Continue. Continue SHALL ask "Set <field> on N records?" with "Every selected record is updated in one step.", Cancel and "Set <field>". Delete SHALL ask "Delete N records?" with "Every selected record is deleted in one step.", "Delete" as a secondary action at the leading edge and "Keep records" as the primary action. Both batch actions SHALL submit a single batch command through the bridge and SHALL report the affected count after success as "Set <field> on N records" or "Deleted N records". Single-record delete from the list SHALL remain immediate with no confirmation. Selection SHALL be cleared after a batch completes and SHALL drop records that disappear from the projected list.

#### Scenario: Enter selection and batch delete
- **WHEN** the user long-presses a record, selects two more, and taps Delete
- **THEN** a dialog reads "Delete 3 records?" with "Delete" and "Keep records", confirming with "Delete" submits one batch delete, the list refreshes without those records, and feedback shows "Deleted 3 records"

#### Scenario: Keep records
- **WHEN** the delete confirmation is open and the user presses "Keep records"
- **THEN** no command is sent and the selection is unchanged

#### Scenario: Batch edit one field
- **WHEN** the user selects 4 records, presses "Edit field", chooses the `category` field, enters a value in "New value" with that field's registered editor, presses Continue and confirms "Set category on 4 records?" with "Set category"
- **THEN** Flutter submits one batch field-set command, the four records show the new value after refresh, and feedback shows "Set category on 4 records"

#### Scenario: Cancel keeps selection
- **WHEN** the user dismisses the confirmation dialog
- **THEN** no command is sent and the selection is unchanged

#### Scenario: Rust rejects the batch
- **WHEN** the batch is rejected because a selected record was deleted remotely or the value violates the field definition
- **THEN** the screen shows the typed error, no record changes, and the selection is pruned to records still present

#### Scenario: Single delete unchanged
- **WHEN** the user taps the delete icon on one record outside selection mode
- **THEN** the record is deleted immediately with no confirmation dialog

#### Scenario: Action bar on desktop
- **WHEN** two records of "pains" are selected on a 1240px-wide screen
- **THEN** the header reads "2 selected" and "in pains" with "Select all", "Edit field" and "Delete" buttons

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
The registered Date editor SHALL offer a "Today" action and the registered DateTime editor SHALL offer a "Now" action wherever a record value is entered: the new-record form, the edit-record form, and the batch field editor. "Today" SHALL fill the device's local calendar day. "Now" SHALL fill the current instant truncated to the minute. Either action SHALL update the input text and emit the typed value exactly as a picker selection would, so validation timing and draft validation behave the same. At 720px and wider the action SHALL be a text button beside the input; below 720px it SHALL be an inline link inside the input's trailing edge. The action SHALL be hidden while the input holds a value. The actions MUST NOT appear in schema metadata slots (field default, minimum, maximum), where they would freeze the moment the schema was edited.

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
- **WHEN** a record already has a DateTime value and the user clears it, taps "Now", and saves
- **THEN** the input shows the new time and saving submits a field update for that field only

#### Scenario: Action hidden once set
- **WHEN** a Date field in the new-record form holds 2026-09-22
- **THEN** no "Today" action is shown

### Requirement: Local DateTime editor text
The DateTime editor SHALL show its current value as local time in the sortable form `yyyy-MM-dd HH:mm`, both when opened with an existing value and after a picker or "Now" selection.

#### Scenario: Opening an existing value
- **WHEN** a record stores the instant 2026-09-25 04:00 UTC and the device is in UTC-5
- **THEN** the editor shows `2026-09-24 23:00`

### Requirement: Inline collection title rename
The collection screen SHALL let the user rename the collection by editing its title in place. A double tap (or double click) on the title, or Rename in the desktop header ⋮ menu, SHALL turn it into an editable text in the same position, with the same text style, and with no border, fill, label, or padding around it, holding the current name, focused, with the whole name selected. The editable text SHALL be as wide as its content: it SHALL start at the width of the current name, SHALL grow as the user types, SHALL NOT exceed the width the header layout gives the title, and SHALL keep a small minimum width so an emptied title remains visible and tappable. Neighbouring header widgets SHALL keep their position while the title is edited. Pressing Enter or moving focus away from the editable text SHALL submit the edit; pressing Escape SHALL cancel it and restore the title.

On submit the text SHALL be trimmed of leading and trailing whitespace. When the trimmed text is empty, or equal to the current name, the edit SHALL be treated as a cancel: no rename command is sent and no error is shown. Otherwise the existing rename command SHALL be sent with the trimmed name, and the title SHALL show the new name once the projection refreshes.

When the rename command is rejected, the title SHALL return to the previous name and the error SHALL be reported to the user without keeping the editable text open.

The Rename action on the collection list card menu SHALL remain available. At 720px and wider it SHALL turn that row in place into a name input holding the current name, focused and selected, with the hint "Enter to save · Esc to cancel" inside the input and Cancel and Save buttons beside it. Enter or Save SHALL submit with the same trim and cancel rules as the title; Escape or Cancel SHALL restore the row without a command; a rejected rename SHALL keep the input open with the error under it. Below 720px Rename SHALL open the "Rename collection" sheet.

#### Scenario: Double tap enters edit mode
- **WHEN** the user double taps the title "Headaches" on the collection screen
- **THEN** the title becomes a focused editable text containing "Headaches" with the text selected, in the same position and text style as the title and with no box drawn around it, on both the wide and the narrow header layouts

#### Scenario: Editor width fits the name
- **WHEN** the user double taps the title "Headaches"
- **THEN** the editable text is no wider than the rendered title was, and the record count beside it on the wide layout stays where it was

#### Scenario: Editor grows while typing
- **WHEN** the user appends " and migraines" to the name while editing
- **THEN** the editable text widens to fit the longer text without wrapping and without moving the caret out of view

#### Scenario: Editor is capped at the header width
- **WHEN** the user types a name longer than the width the header gives the title
- **THEN** the editable text stops growing at that width and scrolls horizontally to keep the caret visible, and the header does not overflow

#### Scenario: Emptied title stays tappable
- **WHEN** the user deletes every character while editing
- **THEN** the editable text keeps a small non-zero width with the caret visible and still accepts input

#### Scenario: Enter saves the trimmed name
- **WHEN** the user replaces the text with "  Migraines " and presses Enter
- **THEN** a rename command is sent with "Migraines", the editable text closes, and the title shows "Migraines"

#### Scenario: Losing focus saves
- **WHEN** the user changes the text to "Migraines" and focus moves away from the editable text
- **THEN** the rename command is sent with "Migraines" and the editable text closes

#### Scenario: Escape cancels
- **WHEN** the user changes the text and presses Escape
- **THEN** no rename command is sent and the title shows the previous name

#### Scenario: Empty name cancels silently
- **WHEN** the user clears the text, or leaves only whitespace, and presses Enter or moves focus away
- **THEN** no rename command is sent, no error is shown, and the title shows the previous name

#### Scenario: Unchanged name cancels silently
- **WHEN** the user submits the current name unchanged, with or without surrounding whitespace
- **THEN** no rename command is sent and the editable text closes

#### Scenario: Rejected rename restores the title
- **WHEN** the rename command fails
- **THEN** the editable text closes, the title shows the previous name, and the failure is reported to the user

#### Scenario: Header menu rename
- **WHEN** the user chooses Rename from the collection screen's ⋮ menu on a 1240px-wide screen
- **THEN** the title becomes its focused editable text with the name selected

#### Scenario: List menu rename still works
- **WHEN** the user chooses Rename from a collection row's menu on a 1240px-wide screen, types "pain log" and presses Enter
- **THEN** the row showed an input with "Enter to save · Esc to cancel", Cancel and Save, a rename command is sent with "pain log", and the row returns to its normal look with the new name

#### Scenario: Escape cancels the list rename
- **WHEN** the row's rename input is open and the user presses Escape
- **THEN** no rename command is sent and the row shows the previous name

#### Scenario: List rename on a phone
- **WHEN** the user chooses Rename from a collection's action sheet on a 390px-wide screen
- **THEN** the "Rename collection" sheet opens with the name input, Cancel and Save

### Requirement: Slider presentation for bounded Integer fields
The field editor SHALL show a "Show as slider" switch only when the kind is Integer. The switch SHALL be enabled only while both the minimum and the maximum are filled, and SHALL turn off when either bound is cleared or the field type changes. While the switch is on, the field editor SHALL show a Step input that accepts a positive whole number and is empty by default, meaning step 1. Before submitting, the field editor SHALL reject a step that is not positive or that does not divide the distance between the bounds exactly, showing the issue under the Step input, and SHALL clear the step when the switch turns off. The record editor SHALL render an Integer field whose slider flag is set as the shared slider input with those bounds and that step, and SHALL render it as the plain integer input when the flag is unset. In the new-record editor, a required slider field with no default SHALL start at the minimum and SHALL report the minimum as its value. When an existing record lacks a required slider field, the editor SHALL show the unset track with the typed missing-value error from Rust under it, as it does for other inputs, and MUST NOT substitute the minimum. Record lists SHALL display the value as a plain number regardless of the flag or step.

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

#### Scenario: Step input appears with the switch
- **WHEN** the user turns the slider switch on for an Integer field with bounds 0 and 100
- **THEN** a Step input appears, empty, and saving submits the field with no explicit step

#### Scenario: Valid step is saved
- **WHEN** the slider switch is on with bounds 0 and 100 and the user enters step 10 and saves
- **THEN** the saved definition carries slider step 10

#### Scenario: Step that does not divide the range is rejected in the editor
- **WHEN** the slider switch is on with bounds 0 and 100 and the user enters step 30 and saves
- **THEN** an issue appears under the Step input stating that the step must divide the range exactly, and no schema command is submitted

#### Scenario: Turning the switch off clears the step
- **WHEN** the slider switch is on with step 10 and the user turns it off and saves
- **THEN** the saved definition carries neither the slider flag nor a step

#### Scenario: Record editor renders the slider
- **WHEN** the user opens the record editor for a collection with an Integer field flagged as slider with bounds 1 and 5
- **THEN** that field is a slider with whole steps from 1 to 5 and a visible current value

#### Scenario: Record editor honours the step
- **WHEN** the user opens the record editor for an Integer field flagged as slider with bounds 0 and 100 and step 10
- **THEN** that field is a slider whose thumb stops only at multiples of 10

#### Scenario: Required slider with no default starts at the minimum
- **WHEN** the user opens the new-record editor for a required slider field with bounds 1 and 5 and no default
- **THEN** the slider shows the thumb at 1 with value label 1, and saving without touching it stores 1

#### Scenario: Required slider field unset
- **WHEN** an existing record projected as invalid because it lacks a required slider field is opened and the user saves without touching the slider
- **THEN** the slider shows the unset track and the typed missing-value error from Rust under it, as it does for other inputs

#### Scenario: Optional slider field left unset
- **WHEN** an optional slider field with no default is left in its unset state and the record is saved
- **THEN** the submitted value for that field is null

#### Scenario: Slider value in the list
- **WHEN** a record with slider value 3 is shown in the record list
- **THEN** the cell reads 3

### Requirement: Slider fields show their scale in the record editor
The record editor SHALL render a slider field with a label row under the track: every step value when they fit, otherwise the minimum and maximum under the track ends, as the shared slider input defines. The taller slider MUST NOT change the height or alignment of the other inputs in the same form.

#### Scenario: Scale visible before any interaction
- **WHEN** the user opens the new-record editor for an optional slider field with bounds 0 and 100 and step 10 on a 1280px-wide screen
- **THEN** the field shows a row of labels 0, 10, 20 ... 100 under the track before the user touches it

#### Scenario: Narrow screen keeps only the bounds
- **WHEN** the same field is shown on a 390px-wide screen where eleven labels cannot fit
- **THEN** the row under the track shows only 0 under the leading end and 100 under the trailing end

#### Scenario: Neighbouring inputs keep their height
- **WHEN** a form shows a Text field above a slider field
- **THEN** the Text input keeps the normal box height and the slider takes the extra height below its own label

### Requirement: Clone collection action
The collection list card menu SHALL offer a Clone action next to Rename and Delete, and the collection screen's desktop ⋮ menu SHALL offer the same action. Choosing it SHALL open a dialog titled "Clone collection" with a required Name input prefilled with the source name followed by " (copy)", and Cancel and "Clone" actions. Clone SHALL submit the clone command with the trimmed name; Cancel or dismissing the dialog SHALL send no command. A typed name error from Rust SHALL be shown inline on the Name input and the dialog SHALL stay open. On success the dialog SHALL close and the new collection SHALL appear in the list after the projection refreshes, without navigating into it.

#### Scenario: Duplicate with default name
- **WHEN** the user chooses Clone on "Headache" and presses "Clone" without editing
- **THEN** a new collection "Headache (copy)" appears in the list with the same fields, queries and widgets and no records

#### Scenario: Duplicate with custom name
- **WHEN** the user replaces the prefilled name with "Migraine" and presses "Clone"
- **THEN** the new collection is named "Migraine"

#### Scenario: Cancel
- **WHEN** the user presses Cancel or dismisses the dialog
- **THEN** no clone command is sent and the list is unchanged

#### Scenario: Rust rejects the name
- **WHEN** the user clears the name and presses "Clone"
- **THEN** the dialog stays open and shows the typed name error under the Name input

### Requirement: Collection export and import actions
The collections list SHALL offer, per collection, "Export CSV" and "Export JSON" actions and an "Import CSV…" action, and SHALL offer an "Export all" action and an "Export selected…" action that produce one JSON envelope. The collections list SHALL offer an "Import JSON…" action that creates new collections. Each action SHALL open the platform file dialog, then show the outcome in the same surface, without leaving the current screen.

"Export selected…" SHALL first open "Export collections" with the line "Choose what goes in the file" and one checkable row per active collection showing its name and "N records · N fields". Its primary action SHALL read "Export N collections" ("Export N" below 720px), pluralized, and SHALL be unavailable while nothing is checked. At 720px and wider it SHALL be a dialog; below 720px a bottom sheet.

The outcome SHALL be shown as a toast with a status icon: a check for success, a warning for an abort. A success SHALL read "Exported to <file name>", "Imported N records into <collection>" for CSV, or "Imported N collections" for JSON, and SHALL hide on its own. An abort SHALL read "Import stopped at <place>: <reason> Nothing was imported.", where the place is "the header", "row N, column “<column>”", "row N", or "collection N" followed by ", item <item>" when known, and SHALL stay until the user presses "Dismiss". The reason SHALL be Rust's reason text unchanged.

#### Scenario: Export CSV from list
- **WHEN** the user chooses "Export CSV" on "pains" and confirms a location with the file name "pains.csv"
- **THEN** the CSV is written there and a toast with a check icon reads "Exported to pains.csv"

#### Scenario: CSV import success
- **WHEN** the user imports a CSV of 42 valid rows into "pains"
- **THEN** a toast reads "Imported 42 records into pains"

#### Scenario: CSV import abort shown
- **WHEN** the user imports a CSV whose row 18 has the text "eleven" in the Integer column `Level`
- **THEN** a toast with a warning icon reads "Import stopped at row 18, column “Level”: " followed by Rust's reason and " Nothing was imported.", stays until "Dismiss" is pressed, and the record list is unchanged

#### Scenario: Import JSON adds collections
- **WHEN** the user imports an envelope with two collections
- **THEN** two new collections appear in the list, existing collections are unchanged, and a toast reads "Imported 2 collections"

#### Scenario: Export selected
- **WHEN** the user chooses "Export selected…" on a 1240px-wide screen and checks "pains" and "pen"
- **THEN** the dialog shows "Choose what goes in the file", the rows show their counts, the primary reads "Export 2 collections", and pressing it opens the save dialog for one JSON file holding both

#### Scenario: Nothing checked
- **WHEN** the "Export collections" picker is open with no collection checked
- **THEN** the primary action is unavailable and nothing is exported

### Requirement: New-record editor seeds defaults
When the record editor opens for a new record, every field that declares a default SHALL open with that default as its current value, shown in the field's input exactly as a stored value would be. A Date field whose default is relative SHALL open at the device's local date plus the declared number of days. Fields without a default SHALL open empty. Defaulted fields SHALL show the Default marker until the user changes them. Editing an existing record SHALL show the stored values only and MUST NOT substitute defaults for absent fields. The stored result of saving an untouched seeded form SHALL equal the result of saving the same form before this requirement, because Rust applies the same defaults on create.

#### Scenario: Slider opens at its default
- **WHEN** the user opens the new-record editor for an optional slider field with bounds 1 and 5 and default 3
- **THEN** the slider shows the thumb at 3 with value label 3 and the clear icon available

#### Scenario: Text field opens at its default
- **WHEN** the user opens the new-record editor for a Text field with default "Home"
- **THEN** the text input reads "Home"

#### Scenario: Choice field opens at its default
- **WHEN** the user opens the new-record editor for a Choice field whose default is the option "Mild"
- **THEN** the select shows "Mild"

#### Scenario: Cleared default saves null
- **WHEN** the user opens the new-record editor for an optional slider field with default 3, taps the clear icon, and saves
- **THEN** the submitted value for that field is an explicit null, exactly as it is today when an optional field is cleared

#### Scenario: Relative date default seeds a date
- **WHEN** the device's local date is 2026-09-28 and the user opens the new-record editor for a Date field whose default is Day of creation + 7 days
- **THEN** the input reads 2026-10-05 and shows the Default marker

#### Scenario: Editing an existing record does not seed
- **WHEN** the user opens an existing record that lacks an optional field which has since gained a default
- **THEN** that field opens empty

### Requirement: System back navigation
The system back action (the Android back button or back gesture) SHALL unwind the main shell one step at a time before leaving the app. When a pushed screen, dialog or sheet is open, system back SHALL close it as it does today, including any close confirmation that screen defines, and SHALL NOT also change the shell. Otherwise system back SHALL apply the first matching step:
1. When the open collection is in selection mode, it SHALL clear the selection and leave selection mode, staying in the collection.
2. When a collection is open, it SHALL return to the collections list.
3. When the Devices or Settings destination is shown, it SHALL show the Collections destination.
4. Otherwise it SHALL leave the app as the platform does by default.

These rules SHALL apply in both the layout below 720px and the layout at 720px and wider.

#### Scenario: Back clears selection mode
- **WHEN** a collection is open with two records selected and the user presses system back
- **THEN** the selection is cleared, selection mode ends, and the collection stays open

#### Scenario: Back leaves an open collection
- **WHEN** a collection is open outside selection mode and the user presses system back
- **THEN** the collections list is shown and the app stays in the foreground

#### Scenario: Back from Devices returns to Collections
- **WHEN** the Devices destination is shown and the user presses system back
- **THEN** the Collections destination is shown and the app stays in the foreground

#### Scenario: Back from Settings returns to Collections
- **WHEN** the Settings destination is shown and the user presses system back
- **THEN** the Collections destination is shown and the app stays in the foreground

#### Scenario: Back from the collections list leaves the app
- **WHEN** the collections list is shown on the Collections destination and the user presses system back
- **THEN** the app leaves to the platform as it does by default

#### Scenario: Back unwinds step by step
- **WHEN** a collection is open in selection mode and the user presses system back three times
- **THEN** the first press clears the selection, the second shows the collections list, and the third leaves the app

#### Scenario: Pushed screens close first
- **WHEN** the record editor is open over a collection and the user presses system back
- **THEN** the record editor closes (after its close confirmation when it shows one) and the collection stays open
