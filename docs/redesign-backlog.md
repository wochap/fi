# Redesign backlog

Screens in `design/project/Fi Redesign.dc.html` that differ from the built app. Each entry names
the mock anchor id and what the app must change to match it. Take an area on with its own
OpenSpec change, and remove its section here once that change is archived.

This list is a starting point, not a full diff: each change should still compare its mocks with
the code. Items marked **core** need a Rust or bridge change; items marked **spec** change a
requirement and need a spec delta.

Sample data: the mocks use "Fi f755167e" both as this device and as the paired peer. Treat device
names in mocks as placeholders.

## Dashboard (collection-dashboard, widget-states)

- The grid has 4 columns on desktop; widget sizes S, M, L and Full span 1, 2, 3 and 4 columns. Mobile is one column.
- Each widget has a ⋮ menu (mobile action sheet: Edit widget, Reorder, Remove…).
- Reorder mode shows a drag handle, ↑/↓ and ✕ on each widget, with a Done button.
- Every widget type has a loading skeleton, an empty state, and an error state with "Edit widget". Error copy stays the generic per-kind text ("The saved query of this widget is not valid."), not a field name.
- Unsupported widget card: "Unsupported widget" with the existing explanation, no Edit button.
- Desktop collection header ⋮ holds Queries, Select records, Export CSV, Export JSON, Import CSV…, Rename, Clone, Delete….

## Add / edit widget (widget-editor)

- Widget type is a set of four icon tiles, not a dropdown.
- "Define here / Use a saved query" is a segmented control, not a switch. With a saved query selected: a Query select plus "Edit this query" and "Save as new".
- Presets row (Daily total, Monthly total, Count per day, Latest values) above the Data group.
- Data group: Group by select (None, Day, Week, Month, Year) then Date field; bar chart with Group by None shows Category field. Output scale; Rounding is a segmented "Half to even" / "Reject inexact"; filter chips; X/Y axes for scatter plots.
- Presentation group per type: Aggregate number Unit suffix; Line chart Show points + Y-axis label; Bar chart Bar width; Scatter plot Point radius.
- "?" help beside every non-obvious control, 44×44 on mobile.
- Desktop: the preview sits in a right-hand column. Mobile: the preview sits in the flow and does not overlap the form.
- The Count bar-chart frame still shows "Field to aggregate: None"; hide that control for Count.

## Queries (queries)

- Rows show a result-type tag ("Duration", "Integer"). "Add record-count query" becomes "Add query".
- Edit query: Field selector, field / operator / value filter row ("None" hides operator and value), live "Result now" line (via executeCollectionQuery), subtitle with how many widgets use the query, no divider.
- Deleting a query used by a widget asks "Delete query “…”?" — "1 widget uses it and will show an error until you edit it." (**spec**: collection-widgets).

## Computed field (computed-field-editor)

- Terms are Field / Number / Function, each with a drag handle and ✕, instead of the ⇅ and ⊕ icons. Function is only Absolute value or Divide (Divide has output scale + Half to even / Reject inexact). "Add term" is a button.
- The formula preview includes function tokens.
- Result line: "Result: <type> · may be empty" with a check icon; no example value.
- Inference error shown on the offending term card (dashed outline + message), Save disabled.

## Collections list and menus (collections, collections-outcomes, collections-import-export)

- Header: sort, "Import and export" (desktop button, mobile icon → action sheet), "New collection" / "New".
- Header menu: Import JSON, Export all, Export selected…; "Export selected…" opens a checklist whose button reads "Export 2 collections" ("Export 2" on mobile).
- Per-collection menu grouped under Export and Import: Rename, Clone, Export CSV, Export JSON, Import CSV…, Delete…. No per-collection Import JSON ("Duplicate" becomes "Clone").
- Clone opens a "Clone collection" dialog with Name prefilled "<name> (copy)".
- Rename is inline on desktop (Enter/Esc hints) and an inline card on mobile.
- One card subtitle format on both widths: "6 records · 3 fields · edited 2 h ago".
- Results show as toasts: "Exported to <file name>" (no Show button), records/collections imported, or the abort reason naming collection/row and item/column.

## Selection mode (collection-selection)

- The Edit button becomes "Edit field": field picker with a value control, then "Set … on N records?".
- The action bar puts the count first, then "in <collection>" on desktop. Mobile actions are icon buttons: Select all, Edit field, Delete.
- In the Delete confirm, Delete is the secondary button and "Keep records" the primary one.
- Selected rows and cards get the accent tint, a left accent edge and a checked box. The dashboard dims while selecting.
- Result toasts read "Set Type on 2 records" and "Deleted 2 records".

## Record form (record-form-*, collection-incomplete)

- Desktop Edit record title "Edit record · 1 field needed", context "in <collection> · created <date>"; mobile edit sheets show the same context line.
- Seeded defaults show the "↳ Default" marker; a required field with a default shows no "*". Mobile frames show a "* required" legend.
- ✕ sits inside the box before the caret on dropdown and searchable fields.
- Empty dashboard copy: "No widgets yet. Add one to summarize this collection."
- Date / Date & time range errors read "Must be on or after 2026-01-01" (**core**: Rust formats Date bounds as day numbers today).

## Schema sheet and field editor (schema-sheet, schema-field-editor, schema-add-field)

- Each row ends with a chevron. Slider summaries include the control: "Integer · 0–10 · slider".
- Mobile: "Add field" is a dashed full-width button; no drag handles, reorder by long-press.
- Desktop: a delete icon on row hover. Confirm "Delete field “…”?" — "Removes the field from the schema. 2 records lose their value for it." (count from the loaded records).
- Field editor "?" help beside Required, Default value, Date range, Length limits, Multiline, Range, Step.
- Integer editor: Required, Default value, Range (Min/Max), Show as slider with Step and "Step must divide the range.".
- Choice editor: options list (drag, name, trash), Add option, Default select with None first; delete option confirm "3 records use it and keep it. It can't be picked for new records." ("Delete option" secondary / "Keep option" primary).
- Turning Required on without a default over existing records: inline warning plus a Save confirm "Make “…” required?" ("Make required" secondary / "Keep optional" primary).

## Help popup (help-popup)

- Desktop: a popover with "Got it". Mobile: a bottom sheet. Mobile "?" buttons are 44×44.

## Onboarding and startup (onboarding-first-run, onboarding-joining, onboarding-dataset-mismatch, startup-errors)

- First run: each card is the action (no Continue). While pairing is open, the locked Create card explains why and offers "Stop pairing" (≥ 44px).
- Join path: "Pairing is open · <time> left", nearby endpoints only with Connect, Stop pairing, then the code confirm; failure "The other device has no dataset yet…" with Back.
- Joining: one line "Copying the dataset from <name>. Keep both devices open until this finishes." with an indeterminate ring; "the other device" when unnamed. No percentage, no Cancel.
- Different dataset: "Back" primary right, "Reset this device's data…" secondary left, ghost "Pair a different device".
- Startup: keyring locked and no keyring available are banners over the working app with Retry (like ports in use); sidebar status reads "Offline" while a banner shows. Fatal error offers Reset, no error code.
- Recovery: "Recovering this device's data" (ring) and "Recovery needs another device" (Reset secondary, Retry primary).

## Devices page (devices, devices-connections)

- Section order: Trusted devices, This device, Connections.
- This device has "Name other devices see when pairing" under the name; "Copy ID" turns into an inline "ID copied"; "Networking is not set up" state.
- Every state tag has an icon; Synced uses the accent tint. Paused, Synced and Offline rows side by side.
- Timestamps older than a day: "Seen Mon 28 Sep 09:12 · Synced Mon 28 Sep 09:12".
- The ⋮ menu on a revoked row shows Rename and Delete…, no Revoke.
- "Pair device" is hidden while the list is empty. "Discovery is off — pairing still works." sits as a muted line beside "Pair device".
- Mobile: the whole row opens Details with a chevron (no ⋮); Connections rows have no icon tiles.
- A failed switch toggle shows "Couldn't change this. Try again." inline.

## Pairing (devices-pairing, devices-code-confirm, devices-confirm-dialogs)

- Pairing shows a countdown ring; nearby rows show only the endpoint in monospace with Connect.
- End states: "Pairing expired" and "Pairing rejected", each with "Start pairing".
- Code confirmation: full device ID, selectable and copyable; "Saving trust…" (buttons disabled) and "Keyring locked" (Retry) states. Sidebar "Looking for paired devices · pairing open".
- Destructive dialogs put the destructive action as a secondary button on the left.
- Reset has an "I understand this can't be undone" checkbox on both widths and the line "<N> trusted devices are kept and can be paired again."

## Device details and unreachable (devices-details, devices-unreachable, devices-connect-address)

- Details grid: State, Failure code, Last attempt, Last endpoint, Sync port "UDP 47380". Log categories pairing / address / peer / device; All / Pairing / Peer filter on both widths.
- Connect by address… in Details; desktop Copy log next to Reconnect. Revoked device details: log and Copy log only.
- Connect by address: prefilled last endpoint; inline errors with the text kept; success toast "Connected to <name>".

## Settings (settings, settings-about, settings-microphone, settings-language, settings-model-states, settings-confirm-dialogs)

- About lists every address labelled LAN or Tailnet (client-side classification; the bridge returns plain ip:port), each with a copy button and inline "Address copied"; no mid-number wrap on mobile; "Not on a local network or tailnet" state.
- Microphone: "Android settings" is a secondary button; each state has an icon and the existing one-line explanation.
- Voice input: muted "Audio is processed on this device and never saved."; Hands-free hidden until the models are Ready.
- Language with one model missing: "Other languages" group with per-model Delete, "Wi-Fi recommended" and "Needs 148 MB · <free> free on this phone" above Download; "Delete this speech model?" confirm.
- "Re-download voice models?" confirm.

## Voice sheet (voice-primer, voice-download, voice-listening)

- Primer privacy line is "Audio is processed on this device and never saved." only.
- In-sheet download card states: Reconnecting…, Checking downloaded data…, Download paused (Resume), Download failed (Retry).
- Listening shows "Stops on its own after 30 seconds."
