# Redesign backlog

Screens in `design/project/Fi Redesign.dc.html` that differ from the built app. Each entry names
the mock anchor id and what the app must change to match it. Take an area on with its own
OpenSpec change, and remove its section here once that change is archived.

## Dashboard (collection-dashboard, widget-states)

- The grid has 4 columns on desktop; widget sizes S, M, L and Full span 1, 2, 3 and 4 columns. Mobile is one column.
- Each widget has a ⋮ menu.
- Reorder mode shows a drag handle, ↑/↓ and ✕ on each widget, with a Done button.
- Every widget type has an empty state and an error state with "Edit widget".

## Add / edit widget (widget-editor)

- Widget type is a set of four icon tiles, not a dropdown.
- "Use a saved query" is a segmented control, not a switch.
- Fields are grouped under Data and Presentation: group by date with Day/Week/Month, output scale, rounding, filter chips, and X/Y axes for scatter plots.
- Desktop: the preview sits in a right-hand column. Mobile: the preview sits in the flow and does not overlap the form.

## Queries (queries)

- Queries panel rows show a result-type tag. "Add record-count query" becomes "Add query".
- Edit query adds a Field selector.
- The filter is a field / operator / value row.
- A live "Result now" line shows the current value.
- The subtitle says how many widgets use the query.
- No divider line.

## Computed field (computed-field-editor)

- The formula preview includes function tokens.
- Each term has a Field / Number / Function choice, a drag handle and ✕, instead of the ⇅ and ⊕ icons.
- "Add term" and "Add function" are buttons.
- The result line has a check icon and an example value.

## Collection menu and outcomes (collections, collections-outcomes)

- "Duplicate" becomes "Clone", and "Import JSON" is added to the per-collection menu.
- Menu items are grouped under Export and Import.
- Rename happens inline, with Enter/Esc hints.
- Results show as toasts: file written, records imported, or the abort reason naming the row and column.

## Collections import and export (collections-import-export)

- The header "Import and export" button sits between the sort control and "New collection".
- "Export selected…" opens a checklist; the button reads "Export 2 collections", or "Export 2" on mobile.
- Toast examples in the mock ("fi-collections-2026-10-05.json", "“pains” already exists with different fields.") are illustrative, not required copy.
- Mobile: the menu opens from a header icon button as an action sheet.

## Selection mode (collection-selection)

- The Edit button becomes "Edit field". It opens a field picker with a value control, then a "Set … on N records?" confirm.
- The action bar puts the count first, then "in <collection>" on desktop.
- Mobile: the actions are icon buttons: Select all, Edit field, Delete.
- In the Delete confirm, Delete is the secondary button and "Keep records" the primary one.
- Selected rows and cards get the accent tint, a left accent edge and a checked box.
- The dashboard dims while selecting.
- Result toasts read "Set Type on 2 records" and "Deleted 2 records".

## Schema sheet (schema-sheet)

- Each row ends with a chevron.
- Slider summaries include the control, e.g. "Integer · 0–10 · slider" (the app shows "Integer · 0–10").
- Mobile: "Add field" is a dashed full-width button.
- Desktop: a delete icon appears on row hover. Deleting asks "Delete field “End at”?" and says how many records lose a value. The app has no delete confirm.
- Mobile: no drag handles; reordering is by long-press.

## Help popup (help-popup)

- Desktop: a popover with "Got it". Mobile: a bottom sheet.

## Onboarding and startup errors (onboarding-first-run, onboarding-joining, onboarding-dataset-mismatch, startup-errors)

- First run: while pairing is open, the locked Create card explains why and offers "Stop pairing".
- Joining: step-by-step progress, with "Joining the other device" when no name is known.
- Different dataset: offers Reset or Back, and no Retry.
- Startup errors: keyring locked (names GNOME Keyring), a ports-in-use banner over the working app, and a fatal error that offers Reset.

## Devices page (devices)

- Section order is Trusted devices, This device, then Connections. The app shows Connections first.
- This device has a label under the name: "Name other devices see when pairing".
- "Copy ID" turns into an inline "ID copied" message in place of the button.
- Every state tag has an icon, and Synced uses the accent tint.
- The ⋮ menu on a revoked row shows Rename and Delete…, with no Revoke.
- "Pair device" is hidden while the list is empty, because the empty card has "Start pairing".
- Mobile: the whole device row opens Details, with a chevron in place of the "Details" link.

## Pairing, code confirmation, confirm dialogs (devices-pairing, devices-code-confirm, devices-confirm-dialogs)

- Pairing shows a countdown ring with nearby devices and Stop.
- Code confirmation shows the full device ID, selectable and copyable.
- Destructive dialogs put the destructive action as a secondary button on the left.
- Reset has an "I understand" checkbox.

## Connections (devices-connections)

- Adds the line "Discovery is off — pairing still works."
- Shows a Paused state in the header, the sidebar and on peer rows.
- Mobile: these rows have no icon tiles.

## Device details (devices-details)

- Adds "Connect by address…".
- Desktop: Copy log stays next to Reconnect.

## Settings About (settings-about)

- Lists every address labelled LAN or Tailnet, each with its own copy button and an inline "Address copied" message.
- Addresses do not wrap mid-number on mobile.
- Includes the "Not on a local network or tailnet" state.

## Settings Microphone (settings-microphone)

- "Android settings" is a secondary button, not a link.
- Each state (Allowed / Not allowed yet / Off) has an icon and a one-line explanation.
