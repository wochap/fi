# Fi redesign (Claude Design handoff)

Source of truth for the UI redesign. Exported from Claude Design on 2026-09-28
(section 7 added in the second export, same day).
Open `Fi Redesign.dc.html` in a browser (it loads `support.js`, `_ds/…/styles.css`
and `Voice Record Sheet.dc.html`); each mock has an anchor, e.g. `#6g`.

Implement from the HTML/CSS source, not from screenshots. Design tokens in
`_ds/…/styles.css` match `flutter_app/lib/theme/nocturne.dart` one to one.
Icons are Phosphor (`ph-*` class names) at the weights shown (`ph`, `ph-fill`, `ph-bold`).

## Mocks in scope

Precedence: section 7 overrides 6, 6 overrides 5, and 5 overrides 4.
Sections 1–3, mock 4e and mock 5d are out of scope.

| Mock | Screen | Platform | Overridden by | Change |
|------|--------|----------|---------------|--------|
| 4a | Collections list, row meta, grouped overflow menu | desktop | — | ui-refresh-lists |
| 4b | Devices page, status line, empty state, copyable ID | desktop | 5e (after pairing) | ui-refresh-lists |
| 4c | Collection records table, typed headers, sticky first column, incomplete row | desktop | — | ui-refresh-lists |
| 4d | New record dialog, labels beside controls | desktop | 7a/7b | form-and-schema |
| 4f | Collections list + action sheet | mobile | — | ui-refresh-lists |
| 4g | Devices + bottom navigation | mobile | 5f (details), 7i (adds Settings tab) | ui-refresh-lists |
| 4h | Schema sheet, tap row to edit | mobile | 7g/7h (field editor) | form-and-schema |
| 4i | New record, labels above | mobile | 7c/7d | form-and-schema |
| 5a | Field controls: choice by option count, clear rules, unset states | both | — | form-and-schema |
| 5b | Schema field editor: Date, relative default, date range | desktop | 7g on mobile | form-and-schema |
| 5c | Schema field editor: Text, length limits, default checked against limits | desktop | 7g on mobile | form-and-schema |
| 5e | Device details expanded inline, connection log | desktop | — | ui-refresh-lists |
| 5f | Device details as a pushed screen | mobile | — | ui-refresh-lists |
| 6a–6l | Voice fill in the New record sheet (`Voice Record Sheet.dc.html`, `state` prop) | mobile | 7c (field styling), 7j (errors) | voice-record-fill |
| 7a | New record dialog, every type empty | desktop | — | form-and-schema |
| 7b | New record dialog, filled, errors after first save, form summary | desktop | — | form-and-schema |
| 7c | New record sheet without voice, every type empty | mobile | — | form-and-schema |
| 7d | New record sheet filled with errors, dropdown picker sheet, search sheet | mobile | — | form-and-schema |
| 7e | Edit record (desktop Delete bottom left, mobile ⋮ menu, no mic) | both | — | form-and-schema |
| 7f | Collection records view: cards, incomplete banner, ⋮ menu, FAB | mobile | — | ui-refresh-lists |
| 7g | Schema field editor as its own screen (Date, Text) | mobile | — | form-and-schema |
| 7h | Add field, Choice options editing | mobile | — | form-and-schema |
| 7i | Settings › Voice input, Settings tab in bottom bar | mobile | — | voice-record-fill |
| 7j | Voice error panels in the sheet | mobile | — | voice-record-fill |
| 7k | Incomplete row opens Edit record with Needed field | desktop | — | ui-refresh-lists |

## Rules stated in the designs

- Choice control: 2–4 options segmented (tap the selected one again to clear), 5–10 dropdown
  (picker sheet on mobile), more than 10 searchable (full-height search sheet on mobile).
- Clear (✕) appears only on optional fields that have a value. Required fields never show it.
- Optional boolean is Yes / No / unset; a required boolean keeps the switch.
- An unset slider shows a dashed track and a "Set" button.
- Mobile New and Edit record share one bottom sheet. New has mic + Save record;
  Edit has ⋮ › Delete and Save changes, no mic. Desktop uses the dialog, no voice.
- Errors appear after the first save attempt: accent border + icon + text, plus a
  summary above the footer with Show (jumps to the first error).
- Needed (dashed border) = required field missing on an existing record, or one voice couldn't fill.
- Duration: desktop ± and h/m/s/ms boxes; mobile one text field with a parsed preview.
- Mobile bottom bar: Collections · Devices · Settings. Voice input lives under Settings.
- Mobile forms are one field per row; touch targets are at least 44px.
- Switch is 38×22 on desktop, 44×26 on mobile. Mobile list rows are at least 64 high.
- Fading dividers only between rows inside cards.
- Menus on desktop, action sheets on mobile.
- Voice field status is never color alone: Voice = sparkle chip + tint, Default = arrow label,
  Needed = dashed border + label, typed by the user = no marker.
- Save is disabled only while listening or processing.
