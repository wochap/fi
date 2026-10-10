## Purpose

TBD: Define the Flutter collection-views UI: chip row, view line, modified state and saving, edit-view editor, view management and reordering, per-device view state, and broken and empty states.

## Requirements

### Requirement: View chip row
The collection screen SHALL show a view chip row between the dashboard and the records, on every width (mock collection-records, Views block).
- It SHALL list All first, then the saved views in their order, then a "+ View" button.
- Each view chip SHALL read "<name> · <count>". A broken view's chip SHALL show a warning glyph in place of the count.
- The selected chip SHALL be accent-filled. The row SHALL scroll sideways when it does not fit and SHALL keep the selected chip in view.
- Tapping a chip SHALL select that view.
- While counts are being recomputed after a change, each chip SHALL keep showing its previous count until the new one arrives; chips SHALL NOT blank or show a placeholder.
- The row SHALL be exposed to assistive technology as a tab list. Each view chip SHALL be a tab whose label includes its name, its count or "broken", its selected state and, when it has unsaved changes, "modified". "+ View" SHALL be exposed as a button, not a tab.
- The dashboard above SHALL NOT follow the selected view.

#### Scenario: Chips with counts
- **WHEN** "pains" has 47 records and the saved views "Headaches" (31) and "Stomach" (9)
- **THEN** the row reads "All · 47", "Headaches · 31", "Stomach · 9", "+ View", with All selected on a first visit

#### Scenario: Selecting a view
- **WHEN** the user taps "Headaches"
- **THEN** the list shows only its 31 records in its order, the chip becomes selected, and the dashboard tiles are unchanged

#### Scenario: Counts stay while recomputing
- **WHEN** a record is added and the counts are being recomputed
- **THEN** every chip keeps its previous count until the new counts arrive, then shows the new values

### Requirement: View line
Under the chip row a view line SHALL summarise the selected view:
- "Sort:" with the primary sort key and its direction word, followed by "then <field>" for each further key;
- "Filter:" with the conditions joined by " · ", when the view filters.

Direction words SHALL follow the key's type:
- newest / oldest for creation time, Date and DateTime;
- A→Z / Z→A for Text;
- high / low for Integer, FixedDecimal and Duration;
- option order / reverse for single Choice;
- yes first / no first for Boolean.

A ⇅ button SHALL flip the primary sort direction in one tap. Tapping anywhere else on the line SHALL open the edit-view editor for the selected view. The view line SHALL replace the former "Newest first" label on every width. The line SHALL show the effective sort of a degraded view.

#### Scenario: Headaches line
- **WHEN** "Headaches" sorts by start at descending and filters type is headache
- **THEN** the line reads "Sort: start at · newest" and "Filter: type is headache", with ⇅

#### Scenario: Flip with ⇅
- **WHEN** the user taps ⇅ on "Headaches"
- **THEN** the list reorders oldest first, the line reads "start at · oldest", and the view becomes modified

### Requirement: Modified views and saving
A change to the selected view's filter or sort that has not been saved SHALL make the view modified. Changes made through ⇅ or the edit-view editor all count.
- A modified saved view's chip SHALL show a dot. The view line SHALL offer Save, "Save as new view" and Reset.
- A modified All SHALL offer only "Save as new view" and Reset.
- Save SHALL replace the saved view's body. "Save as new view" SHALL open the edit-view editor in create mode with the changed body and an empty Name. Reset SHALL discard the changes.
- A change that makes the body equal to the saved body again SHALL clear the modified state.
- The modified state SHALL be announced to assistive technology when it starts.

#### Scenario: Save a flipped sort
- **WHEN** "Headaches" is modified by flipping its sort and the user presses Save
- **THEN** the view's body is replaced on every synchronized device and the chip's dot disappears

#### Scenario: All offers no Save
- **WHEN** the user flips All's sort
- **THEN** All shows the dot and the line offers only "Save as new view" and Reset

#### Scenario: Reset
- **WHEN** the user presses Reset on a modified view
- **THEN** the list returns to the saved body and the dot disappears

### Requirement: Edit-view editor
"+ View", "Save as new view", Edit from a chip menu and a tap on the view line SHALL open the edit-view editor. On phones it SHALL be a bottom sheet and at 720px and wider a popover anchored to the chip row. It SHALL hold these sections, in order:
- **Name**: hidden when editing All.
- **Filter · all must match**: condition rows in the query builder's filter style. Each row is field · operator · value, with "Add filter", and the rows are combined with AND. Single and multi-option Choices fields SHALL offer "is any of", "is none of", "is empty" and "is not empty"; "is empty" and "is not empty" take no options. Other fields SHALL offer the query builder's operators for their type.
- **Sort**: Created or any field except multi-option Choices, each with type-worded directions, plus "Then by" for up to three keys in total.

The footer SHALL hold Cancel and Save. Save SHALL create the view, or update the body and name of the one being edited, and select it.

Name checks made by the app before sending:
- An empty name SHALL make Save unavailable.
- A name equal, ignoring case and surrounding spaces, to the localized name of All ("All", or "Todos" in Spanish) SHALL show the inline error "“All” is reserved" (localized) and make Save unavailable.
- A name equal, ignoring case and surrounding spaces, to another saved view of the collection SHALL show the inline warning "Another view is already called <name>", and Save SHALL stay available.

A typed validation error from Rust SHALL be shown inline, in the active language, on the section it names, and the editor SHALL stay open. Cancel or dismissing SHALL change nothing.

#### Scenario: Create Headaches
- **WHEN** the user taps "+ View", names it "Headaches", adds "type is any of headache", sorts by start at newest and saves
- **THEN** a chip "Headaches · 31" appears after the existing views, is selected, and the list shows its 31 records

#### Scenario: Multi-option Choices not offered for sort
- **WHEN** the Sort picker is opened on a collection with a "tags" field
- **THEN** "tags" is not in the list, and it is still offered in Filter

#### Scenario: Duplicate name warns
- **WHEN** the user names a new view "headaches" while "Headaches" exists
- **THEN** the Name input shows "Another view is already called headaches", Save stays available, and saving creates a second view

#### Scenario: Reserved name
- **WHEN** the user names a view "todos" with the interface in Spanish
- **THEN** the Name input shows the Spanish reserved-name error and Save is unavailable

### Requirement: Managing views
A long press on a view chip below 720px, or a secondary click on it at 720px and wider, SHALL open a menu. A long press SHALL NOT start dragging the chip.
- For a saved view the menu SHALL hold Rename, Edit, "Reorder views…" and "Delete…". For All it SHALL hold only "Reorder views…". "+ View" SHALL have no menu.
- Rename SHALL edit the name only, with the same name checks as the edit-view editor.
- Edit SHALL open the edit-view editor for that view.
- "Delete…" SHALL ask "Delete view “<name>”?" with "Records aren't affected.", "Delete" and "Keep view". Confirming SHALL delete the view and select All if it was selected; "Keep view" or dismissing SHALL change nothing.
- "Reorder views…" SHALL open a sheet below 720px or a dialog at 720px and wider with a vertical list of the collection's views:
  - All first, fixed, with no drag handle and the muted note "Always first";
  - each saved view with its name, its count (or the warning glyph when broken) and the drag handle (six-dot grip) used by the Choices options editor; dragging the handle reorders, and only the handle starts a drag;
  - the list's built-in move actions SHALL be exposed to assistive technology and the keyboard as the non-drag way to reorder;
  - a Done button in the footer closes it.
  Each completed move SHALL save the new order, which synchronizes to other devices.

#### Scenario: Delete a selected view
- **WHEN** "Headaches" is selected and the user deletes it and confirms
- **THEN** the chip disappears, All is selected, and every record is still present

#### Scenario: Reorder through the sheet
- **WHEN** the user opens "Reorder views…", drags "Stomach" above "Headaches" by its handle and taps Done
- **THEN** the chips read All, Stomach, Headaches on this and every synchronized device

#### Scenario: All's menu
- **WHEN** the user long-presses the All chip
- **THEN** the menu offers only "Reorder views…"

#### Scenario: Reorder without dragging
- **WHEN** a screen-reader user activates the move-up action on "Stomach" in the reorder list
- **THEN** "Stomach" moves one place up and the new order is saved

### Requirement: View state is remembered per device
For each collection, the device SHALL remember the selected view and the unsaved changes to it, and restore both on re-entering the collection and after an app restart. The state SHALL be kept in device-local UI preferences and never synchronized. A first visit SHALL select All with no changes.
- When the remembered view no longer exists, All SHALL be selected and the remembered changes discarded.
- When the remembered view's saved body changes on another device while this device holds unsaved changes, the unsaved changes SHALL be kept. The modified state SHALL compare them with the new saved body.
- When the unsaved changes become broken, for example because a field they use was deleted on another device, they SHALL be discarded, the list SHALL show the saved view (or All when the saved view is broken too), and a notice SHALL read "Your unsaved changes used a field that was deleted, so they were discarded." with OK.
- Remembered state for collections that no longer exist SHALL be removed after the collection list is loaded.

#### Scenario: Back to the collection
- **WHEN** the user selects "Headaches", flips its sort, leaves "pains", restarts the app and opens "pains" again
- **THEN** "Headaches" is selected with the flipped sort and its modified dot

#### Scenario: Remembered view deleted elsewhere
- **WHEN** another device deletes the view this device last used in "pains"
- **THEN** opening "pains" selects All

#### Scenario: Unsaved changes use a deleted field
- **WHEN** this device holds an unsaved filter on "level" for "Headaches" and another device deletes "level"
- **THEN** the unsaved changes are discarded, the list shows the saved "Headaches", and the discarded-changes notice is shown with OK

### Requirement: Record list refresh follows data changes
The collection screen SHALL keep the full list of the collection's active records separately from the view-ordered list it shows, so state that concerns records the view hides (such as clone badges and incomplete counts) is not lost when the view changes. Bursts of data-changed notifications, including those from synchronization, SHALL be coalesced so the views listing and the view execution run once per burst rather than once per notification. A refresh SHALL keep the scroll position and SHALL NOT show a loading state when records are already shown.

#### Scenario: Sync burst
- **WHEN** synchronization delivers twenty record changes within half a second
- **THEN** the views listing and the selected view's execution each run once for the burst, and the list keeps its scroll position

### Requirement: Batch actions follow the view
Selection mode inside a view SHALL act only on records the view shows. Select all SHALL read "Select all N", with N the view's count, and SHALL select every record the view shows. Batch Edit field, Clone and Delete SHALL act on the selection only. Records that a view change hides SHALL be dropped from the selection.

#### Scenario: Select all in a view
- **WHEN** "Headaches" (31 of 47) is selected and the user enters selection mode
- **THEN** the action reads "Select all 31" and pressing it selects 31 records

### Requirement: Broken and empty views on screen
- **Broken:** when the selected view is broken, a notice SHALL read "This view uses a field that was deleted" with an "Edit view" action, and the list SHALL show All's records in All's order.
- **Empty:** when the selected view keeps no record but the collection has records, the list area SHALL read "No records match <view>." with "Edit view" and "Show all"; Show all SHALL select All.

#### Scenario: Broken view selected
- **WHEN** the user selects a view whose filter field was deleted
- **THEN** the chip shows a warning glyph, the notice offers "Edit view", and the list shows every record newest first

#### Scenario: Empty view
- **WHEN** "Stomach" keeps no record
- **THEN** the list reads "No records match Stomach." with "Edit view" and "Show all"

### Requirement: View copy in both languages
Every string of the views UI SHALL exist in English and Spanish with the same keys. This covers chips, view line, direction words, modified actions, editor sections and operators, name warnings and errors, menus, the reorder sheet, the delete dialog, the discarded-changes notice, and the broken and empty states. "Select all N" SHALL be a plural message ("Seleccionar los N" in Spanish). Layouts SHALL fit Spanish text about 30% longer without clipping at 360px.

#### Scenario: Spanish select all
- **WHEN** the app language is Spanish and "Headaches" shows 31 records in selection mode
- **THEN** the action reads "Seleccionar los 31"

### Requirement: Grouping in the editor and the view line
The edit-view editor SHALL add a **Group by** section after Sort, offering None, any single-choice field, any yes/no field, or any Date or DateTime field with Day, Week or Month. Multi-option Choices fields SHALL NOT be offered. A grouping change SHALL make the view modified like any other change. When the selected view groups, the view line SHALL add "Group:" with the field and, for dates, the period.

#### Scenario: Group line
- **WHEN** "Headaches" groups by start at by Month
- **THEN** the view line adds "Group: start at · month"

#### Scenario: Multi-option Choices not offered for grouping
- **WHEN** the Group by picker is opened on a collection with a "tags" field
- **THEN** "tags" is not in the list

### Requirement: Grouped record list
When the selected view groups, the records SHALL be shown under section headers in group order. Each header reads the group label and its count, for example "October 2026 · 6". Group labels SHALL be:
- Day: the localized date;
- Week: "Week of <localized Monday date>";
- Month: the localized month and year;
- single Choice: the option label;
- Boolean: Yes or No;
- no value: "No <field>".

Each header SHALL collapse and expand its group on tap, and SHALL be exposed as an expandable control with its expanded state. Collapsed groups SHALL be remembered for the selected view until the app closes. Select all SHALL include records in collapsed groups. At 720px and wider the grouped rows SHALL stay in the record table under full-width header rows that do not scroll sideways with the columns.

#### Scenario: Collapse September
- **WHEN** "Headaches" is grouped by month and the user taps "September 2026 · 14"
- **THEN** its 14 records are hidden, the header stays with its count, and October's records stay visible

#### Scenario: Select all includes collapsed groups
- **WHEN** September is collapsed in "Headaches" and the user presses "Select all 31"
- **THEN** 31 records are selected, including September's 14

### Requirement: Sortable table headers
At 720px and wider each record-table column header SHALL be a sort control.
- Clicking the header of the primary sort key SHALL flip its direction.
- Clicking any other orderable column SHALL make that field the only sort key, with its default direction: newest first for Date and DateTime, A→Z for Text, high first for numbers and Duration, option order for single Choice, yes first for Boolean.
- Multi-option Choices headers SHALL NOT be sort controls.
- The headers of sort keys SHALL show ↑ or ↓, and keys after the first SHALL also show their position.
- A header click SHALL modify the selected view like any other change.
- Sortable headers SHALL be exposed with their sort state.

#### Scenario: Header click
- **WHEN** All is selected and the user clicks the "level" header
- **THEN** the table sorts by level high first, the header shows ↓, and All shows the modified dot

### Requirement: Incomplete records hidden by the view
The incomplete-records status line SHALL count only the incomplete records the selected view shows. When the view hides incomplete records, a muted second line SHALL read "N more in other views · Show", with N the number hidden, computed from the collection's full record list. When the view shows none but hides some, the status line SHALL show only that second line. Show SHALL select All.

#### Scenario: Incomplete hidden
- **WHEN** "pains" has 3 incomplete records and "Headaches" shows 1 of them
- **THEN** the status line reads "1 record is missing a required field" with its finish prompt, and "2 more in other views · Show"

### Requirement: Clones hidden by the view
A clone made while a view is selected can create records the view hides, for example a record saved from the Clone editor after its values were changed, or a copy the filter no longer matches. The feedback SHALL then read "Cloned · hidden by <view>" for one record, or "Cloned N records · hidden by <view>" when every created record is hidden, or "Cloned N records · M hidden by <view>" when only some are. It SHALL carry Show and Undo. Show SHALL select All. Undo SHALL delete exactly the created records, as for a batch clone, including a record saved from the Clone editor. When the view hides no created record, the ordinary clone feedback applies. The clone badge SHALL survive the view hiding the record, because badges are kept against the collection's full record list.

#### Scenario: Clone hidden by filter
- **WHEN** "Headaches" is selected, the user opens Clone from a record's editor, changes type to stomach and saves
- **THEN** the feedback reads "Cloned · hidden by Headaches" with Show and Undo, and Show selects All with the new record badged

#### Scenario: Undo a hidden clone
- **WHEN** the user presses Undo on "Cloned · hidden by Headaches"
- **THEN** the record saved from the Clone editor is deleted and no other record changes

### Requirement: New records hidden by the view
When the user saves a new record (not a clone) that the selected view hides, the feedback SHALL read "Saved · hidden by <view>" with a Show action and no Undo. Show SHALL select All. A new record the view shows SHALL get no extra feedback.

#### Scenario: New stomach record in Headaches
- **WHEN** "Headaches" is selected and the user creates a record with type stomach
- **THEN** the feedback reads "Saved · hidden by Headaches" with Show, and Show selects All with the new record listed

### Requirement: Views extras copy in both languages
Every string added by grouping, sortable headers, hidden-record feedback and the export outcome SHALL exist in English and Spanish with the same keys, and SHALL fit Spanish text about 30% longer without clipping at 360px.

#### Scenario: Spanish hidden incomplete line
- **WHEN** the app language is Spanish and the view hides 2 incomplete records
- **THEN** the second status line is shown in Spanish with the count 2 and a Show action
