# Fi UI design guide (Nocturne)

Read this before adding or changing any Flutter UI. The app follows **Nocturne**: a quiet, dense,
interface on Catppuccin, in two themes: Mocha (dark) and Latte (light). Inter at weight 500 for headings, soft 8px corners, and an accent used as a line or a
glow, never as a flood of color. Follow these rules so new screens match the existing ones.

## Design source

The redesign mocks live in one canvas, `design/project/Fi Redesign.dc.html` (it imports
`Voice Record Sheet.dc.html`; design tokens are in `design/project/_ds/`). Each mock is anchored by a
screen-based id, and code, specs and this guide cite it as `mock <id>`, for example
`mock devices-unreachable` or `mocks settings, settings-language`.

The specs and the built app describe current behaviour. The canvas is ahead of the build in places,
so a mock is the target only for the screens a change explicitly takes on; when such a mock and this
guide disagree, update this guide to match.

## Where things live

| File | What it holds |
| --- | --- |
| `lib/theme/nocturne.dart` | `NocturneColors` (the theme's colors, roles, status colors, scrim and shadows; `NocturneColors.mocha` and `NocturneColors.latte`), read with `context.nocturne`; `Nocturne` constants (radii, fonts, breakpoints, input heights via `Nocturne.inputHeight`); `nocturneTheme(NocturneColors)`, the only `ThemeData` builder |
| `lib/theme/app_theme.dart` | `latteTheme` / `mochaTheme` (built once), `AppThemeController` + `ThemeScope` (the Appearance preference), `systemOverlayStyle()` (bar icon brightness) |
| `lib/theme/nocturne_widgets.dart` | Shared pieces: `FadedRule`, `Kicker`, `SectionLabel`, `GlowDot`, `IconTile`, `Tag` (accent, `Tag.neutral`, `Tag.outline`, `Tag.danger`, `Tag.success`, optional leading icon), `NocturneCard`, `nocturneGlow()`, `DashedSlot`, `FiLogoMark`, `FiLogoTile`, `ClearMark`, the field status markers `VoiceChip` / `DefaultMarker` / `NeededMarker`, `FiSwitch` / `FiSwitchTile`, `FiIconButton`, `CardListRow` |
| `lib/theme/fi_icons.dart` | `FiIcons`: every icon the app draws, named by meaning and pointing at a Phosphor glyph; `fieldTypeIcon()` for the nine field types |
| `lib/theme/side_sheet.dart` | `showSideSheet()`: a 480px sheet from the right, or a bottom sheet on a phone |
| `lib/theme/form_surface.dart` | `showFormSurface()` + `FormSurface`: every create/edit form, a bottom sheet on a phone and a dialog (optionally two-pane with an aside) otherwise |
| `lib/theme/inputs.dart` | `FiTextInput`, `FiSelect`, `FiPickerInput`, `FiSlider`, `FiSegmented`, `FiDurationInput`: every text, number, search, select, picker, slider, segmented and duration input, at the small or normal height token; `DurationGrammar` (set once at startup to the core's grammar, `lib/bridge/duration_grammar.dart`) and `formatDurationPreview()` |
| `lib/theme/choice_input.dart` | `FiChoiceInput`: a Choice picked by option count (segmented up to 4, select or phone picker sheet up to 10, search above that), with `showChoicePickerSheet()` and the full-height `showChoiceSearchSheet()`; `FiChoicesInput`: a Choices set by the same thresholds (toggle chips up to 4, then a field with "N picked" opening the checkbox sheet `showChoicesSheet()` with Done, plus search above 10); `ChoicesTagRow`: a Choices value as list tags with "+N" overflow. When the field allows adding options from records (`onAdd`), the layout follows the stored options only, segmented choice and toggle chips end with an `AddOptionChip` ("＋ Add", a small input in place), every other layout uses the search (sheet on a phone) whose list ends with "＋ Add “text”" unless an option equals the text ignoring case (that one is tagged "existing"), and added options show `NewOptionTag` |
| `lib/record_form.dart` | `RecordFormBody`: the record editor's fields, labels in a 140px column beside the controls at ≥720 and above them below, with the Default / Needed markers in the label row |
| `lib/field_editor.dart` | `FieldEditorBody` (name, 3×3 type grid, option chips with a settings block per chip, Choice / Choices options with a ⋯ menu per row (Merge… / Delete…; 44px on a phone, 28px on a desktop), the duplicate-label and "records still use merged options" banners, the merge sheet (mock schema-merge-options), the "Allow adding options from records" switch, default checks; Choice ↔ Choices stays switchable on an existing field), hosted as a desktop inline panel or by `FieldEditorScreen` (the pushed phone screen); `fieldSummary()` for schema rows |
| `lib/theme/action_sheet.dart` | `showActionSheet()` + `ActionSheet`: a phone row menu as a bottom sheet, headed by what it acts on (icon tile, title, subtitle), with 48px action rows in optionally labelled groups (mock collections) |
| `lib/device_details.dart` | A trusted device's Details: `DeviceDetails` (state grid, failure, DeviceId with copy, categorized connection log with the All / Pairing / Peer filter, Reconnect and Copy log), `DeviceDetailsScreen` (the pushed phone screen, mock devices-details), `DeviceStateTag`, `LogLineRow`, `seenSyncedLine()`, `shortDeviceId()` / `groupedDeviceId()`, `copyWithConfirmation()` |
| `lib/ui_prefs.dart` | `UiPrefs` and its stores: device-local presentation choices (the collections sort, the voice tip dismissal, hands-free spoken feedback) in `ui_prefs.json` in the app support directory; never sent to Rust or synced. Write with `UiPrefsStore.update` so writers of different fields don't undo each other |
| `lib/voice/` | Voice fill in the phone New record sheet and field dictation (voice-* mocks): `dictation.dart` (`DictationController`, `VoiceTurnCoordinator`, `DictationMic`, `DictationStateRow`, `DictationReview`), `engine.dart` (`VoiceEngine` boundary, `FakeVoiceEngine`, `UnavailableVoiceEngine`, `selectVoiceEngine()`), `patch.dart` (`applyPatch` rules, `VoiceDraftState` field origins), `controller.dart` (`VoiceFillController`, the sheet's flow), `panel.dart` (`VoicePanel`, `VoiceEvidencePopover`, `VoiceFieldMark`, `voiceErrorCopy()`), `mic_button.dart` (`VoiceMicButton`, `VoiceProgressRing`), `example.dart` (`exampleUtterance()`), `services.dart` (permission, network, TTS and model services, `VoicePrefs`, `VoiceScope`, `formatBytes()`), `fakes.dart` (test fakes) |
| `lib/settings_page.dart` | `SettingsPage`, the third phone tab (mock settings): Voice input (model row, hands-free, re-download, delete), Microphone and About (the build label) |
| `lib/collections_page.dart` `_RecordTable` | The desktop records table (mock collection-records): a `two_dimensional_scrollables` `TableView` with a pinned header row and first column (170px, others 150px), typed headers with the required mark, incomplete-row marks, and the "Scroll for more columns →" hint with a trailing fade |
| `lib/theme/form_errors.dart` | `FieldErrorMessage` / `FieldErrorLines` (warning icon + message under a control), `FormErrorLines`, `FormErrorSummary` ("Couldn't save. N fields need attention." + Show), `RequiredLegend`, `requiredLabel()`, `errorOf()` / `decorationErrorText()`: how forms show errors and required inputs |
| `assets/fonts/` | Inter (400, 500) and JetBrains Mono (400), with OFL licences |

Before building something new, look for an existing piece that already does it. Add a new shared
widget to `nocturne_widgets.dart` only when a second screen needs it.

## Hard rules

1. **Take every color from the theme.** Read `final c = context.nocturne;` (or
   `Theme.of(context).colorScheme`), never `Colors.red`, `Colors.green` or hex literals. Muted
   text is `c.muted(opacity)`. Outside `lib/theme/nocturne.dart` there are no numbered ramp steps
   (`accent100…900`, `neutral100…900`), no `Color(0x…)` literals and no `Colors.*` other than
   `Colors.transparent`; `test/design_rules_test.dart` enforces this. Painters and helpers without
   a `BuildContext` take a `NocturneColors` from their widget's `build`.
2. **Never fill a primary button.** `FilledButton` is the primary action, and the theme draws it
   as an accent outline on transparent. Don't pass a `backgroundColor` that fills it. Use at most
   one primary button per surface.
3. Map button variants to widgets as follows (the theme styles each):
   - Primary: `FilledButton`
   - Secondary: `OutlinedButton` (divider-colored border, text color)
   - Ghost / tertiary: `TextButton` (accent text)
   - Icon-only: `IconButton` (36×36). Always give it a `tooltip`; tests and accessibility rely on it.
4. **Use only three corner radii:** 8 (`Nocturne.radius`) for cards, inputs, buttons and rows;
   14 (`Nocturne.radiusLg`) for dialogs; 4 (`Nocturne.radiusSm`) for tiny marks. Tags use 6, and
   bottom sheets use 20 on their top corners.
5. **Keep weights at 400 and 500.** Nothing bolder: hierarchy comes from size and space, not
   weight. Don't use `FontWeight.w600` or `w700`.
6. **Keep the accent to lines and small marks:** borders, icons, tags, a 2px selection edge, and
   glows. For tinted fills use the fill roles (`accentFill`, `neutralFill`, `neutralFillStrong`),
   never the accent itself on a large area. Text drawn in the accent at paragraph size is
   `accentText`.
7. **Never branch on brightness; use roles.** A role resolves to the right step on each theme, so
   one widget reads right on dark and light grounds.
8. **Use Phosphor icons through `FiIcons`** (`lib/theme/fi_icons.dart`), in the regular weight
   unless a mock names fill or bold. Never reference Material `Icons.*` anywhere in `lib/` (the
   generated `lib/src/` excepted); `test/design_rules_test.dart` enforces this. Where a framework
   widget would draw its own Material glyph (a default back button, for example), pass the
   `FiIcons` icon explicitly. Tests find icons by `FiIcons.*` too. Switches are `FiSwitch` /
   `FiSwitchTile`, never Material's `Switch` or `SwitchListTile`.
9. **Inputs come from the shared widgets.** Build text, integer, decimal, search, select,
   slider, segmented choice, duration and Date / Date & time / time inputs with `FiTextInput`,
   `FiSelect`, `FiPickerInput`, `FiSlider`, `FiSegmented`, `FiDurationInput` and (for a Choice)
   `FiChoiceInput` (or `FiChoicesInput` for a Choices set), never a raw `TextField`, `TextFormField`, `DropdownButton`,
   `DropdownButtonFormField` or `SegmentedButton` in feature code. Pass `label`, `required` and
   `errors` to them rather than building an `InputDecoration`. Switches, checkboxes and buttons
   are not inputs here.
10. **Clear only what is optional.** An input that edits an optional value shows the one
   `ClearMark` only while it holds a value (`onClear:` on `FiTextInput` / `FiSelect` /
   `FiPickerInput`, `allowClear:` on `FiSlider` / `FiSegmented` / `FiDurationInput`); a
   required value never shows it. A `FiSegmented` that allows clearing clears on a second tap of
   the selected segment. An unset `FiSlider` shows a dashed track and "Set" (which picks the
   minimum).
11. **The trailing slot is `[ClearMark?, trailingAction?]`.** An action that belongs to the
   input (the dictation mic) goes in `FiTextInput.trailingAction`, after the clear mark, with its
   own 44px target; in a multiline input the slot stays pinned to the top.

## Colors: Catppuccin Mocha and Latte, roles and statuses

Colors live in `NocturneColors` (`lib/theme/nocturne.dart`), a `ThemeExtension` read with
`context.nocturne`. There are two instances, each copied literally from
`design/project/_ds/nocturne-*/styles.css`: `NocturneColors.mocha` from `:root` (base `#1e1e2e`,
surface0 `#313244`, text `#cdd6f4`, mauve accent `#cba6f7`) and `NocturneColors.latte` from
`[data-theme="light"]` (base `#eff1f5`, surface0 `#ccd0da`, text `#4c4f69`, mauve accent `#8839ef`,
scrim text at 40%). `nocturneTheme(colors)` builds both `ThemeData`s; brightness comes from the set.

Which theme is active: `MaterialApp` gets `theme` (Latte), `darkTheme` (Mocha) and `themeMode`
from the Appearance preference (Settings › Appearance: System default, Light, Dark; stored as
`app_theme` in `ui_prefs.json`, device-local, never synced). System default follows the phone or
desktop setting live. Switching only rebuilds through the theme, so every screen keeps its state;
that only holds if colors are read in `build`, so never cache a theme color in `initState`, a
`late final`, or a static decoration or text style. At start the stored choice applies without a
cross-fade (`themeAnimationDuration` is zero until the frame after it loads).

Platform chrome: on Android the launch and window background is `@color/fi_bg`
(`values/colors.xml` Latte `#eff1f5`, `values-night/colors.xml` Mocha `#1e1e2e`), so the launch
screen follows the phone's setting (the app preference isn't readable before the engine starts).
While running, an `AnnotatedRegion<SystemUiOverlayStyle>` in `MaterialApp.builder` sets only the
status and navigation bar icon brightness (dark icons on Latte); bar colors are never set, since the
app draws edge-to-edge under the bars. On Linux, System default follows whatever brightness Flutter
reports from the xdg-desktop-portal `color-scheme`; on this NixOS/Hyprland desktop the portal
reports it (`prefer-dark` reads as 1). If a desktop doesn't report it, Light and Dark still work.
Theme tokens: `bg`, `surface`, `text`, `accent`, `divider`, `section`, `sectionGlow`, `sectionGhost`,
`scrim` (the backdrop behind dialogs and sheets), `shadowSm/Md/Lg`, `muted(opacity)`.

Numbered ramp steps never flip, but the direction of use does between a dark and a light ground,
so call sites use roles:

| Role | Use |
| --- | --- |
| `accentFill` | A tinted accent fill: selection bar, selected rows, accent tags, switch track, glows |
| `accentEdge` | An accent border or inner ring: edit panels, the voice field mark |
| `accentText` | Accent text at paragraph size; the required `*` |
| `accentInk` | Small accent labels and icons on a fill (selected nav items, Needed marker) |
| `accentInkStrong` | Text on an accent fill (accent tag label, voice chip) |
| `neutralFill` | A quiet neutral fill |
| `neutralFillStrong` | A stronger neutral fill or a card edge: neutral tags, tooltips, snackbars |
| `neutralEdge` | A neutral border: menus, dialogs, the clear mark |
| `neutralGhost` | A dim or ghosted mark: the offline dot, placeholder icons |
| `neutralMuted` | Muted chrome |

**Status colors** are `danger` (errors, invalid inputs, Revoked and Failed), `success` (Synced,
Ready) and `warning` (expired, locked, attention). They draw icons, marks, outlines and tag edges or
fills only; every word, tag labels included, stays in `text`. Never fake an error, failed,
revoked, synced, ready, expired or locked state with the accent or a faded text color. The accent
stays the color of active, selected, connected and syncing states. Tags: `Tag` (accent),
`Tag.neutral`, `Tag.outline`, `Tag.danger` (1px danger edge, danger icon), `Tag.success` (success
fill, success icon); there is no warning tag.

## Input sizes

Every shared input of one size has the same box height on a screen, whatever its kind, label,
prefix or suffix. Error and helper lines go below the box and never change its height; a
multiline input starts at the box height and grows by whole lines.

| Size | Desktop (≥720) | Phone (<720) | Use |
| --- | --- | --- | --- |
| normal (default) | 40 | 48 | Form fields |
| small (`.compact`) | 32 | 40 | Inline builder rows: expression builder nodes, query builder conditions |

The height comes from padding derived from the token, not from `InputDecoration.constraints`
(which would squeeze the box when errors appear). Don't override `contentPadding` or wrap an input
in a fixed-height box; if a size looks wrong, change the token.

## Type scale

The type scale lives in `nocturneTheme(...).textTheme`. Prefer it over ad-hoc `TextStyle`s; if you
must write one, use these sizes:

| Use | Style |
| --- | --- |
| Page title, desktop (h2) | `headlineMedium`: 32/500, letter spacing −0.015em |
| Page title, phone (h3) | `headlineSmall`: 25/500 |
| Dialog or sheet title | `titleLarge`: 20/500 |
| Card title | 17/500, set explicitly (`titleMedium` is deliberately 14 because Material uses it for dropdown values) |
| Body / inputs | 14 |
| Meta / secondary line | 12–13 at `c.muted(.55–.6)` |
| Section heading | `SectionLabel('…')`: 13/500, uppercase, 0.08em letter spacing, 60% opacity |
| Card kicker | `Kicker('…')`: 10px, uppercase, accent (widget tiles keep the title's own case) |
| Table header | 11px uppercase, 60% opacity, with the field kind after it at lower opacity |
| Numbers | Add `fontFeatures: Nocturne.tabular` to every column or figure of numbers |
| Ids, formulas, codes | `fontFamily: Nocturne.monoFamily` |

## Surfaces and elevation

- The page ground is `c.bg`. Cards and sheets are `c.surface` with a 1px
  `neutralFillStrong` edge: use `NocturneCard` or the themed `Card` (zero margin, no shadow).
- Rows inside a sheet sit on `c.bg` with radius 8 (see `_SheetRow` and `_schemaRow` in
  `collections_page.dart`).
- Use `c.shadowSm`, `shadowMd` or `shadowLg` for elevation, never ad-hoc heavy shadows.
- For depth, use `nocturneGlow()` on cards: an elliptical `accentFill` glow in one corner. Only
  headline cards get it (stat tiles, the pairing card); charts and lists stay flat.
- **Rules fade.** For a freestanding horizontal rule use `FadedRule()`, which fades out over 48px
  at each end. Box outlines, dividers inside a control, and the top border of a sheet footer stay
  solid. Prefer whitespace to rules.
- For "add another" slots, use `DashedSlot`.

## Layout and breakpoints

| Where | Breakpoint | Behavior |
| --- | --- | --- |
| Screen width (`MediaQuery`) | 720 | ≥720: 216px sidebar (`_Sidebar` in `app.dart`, Collections and Devices, the build label under the sync status). <720: slim logo row plus `NavigationBar` (Collections · Devices · Settings; the build label in Settings › About), bottom sheets instead of side sheets, larger touch targets (44–48px), create/edit forms as bottom sheets |
| Screen width, collection screen | 720 | ≥720: records table. <720: record cards (newest first), a phone header with Schema and a ⋮ menu (Queries, Select records, Collection actions…), floating "+ Record" button, row menus as action sheets, device Details as a pushed screen |
| Collection content width (`LayoutBuilder`) | 760 | Above the phone breakpoint: ≥760 labelled header buttons, <760 the same actions as icon buttons |
| Form surface screen width | 820 | ≥820: a form with an aside (the widget editor's preview) shows it as a 280px pane beside the form; below, the aside is pinned above the buttons |

- Page padding: desktop 32 horizontal / 22 top; phone 16–18 horizontal. Layouts are left-aligned
  and asymmetric: content hugs the left, and reading-width pages cap near 816–880px
  (`ConstrainedBox`).
- Spacing is dense: 22–26 between sections, 10–14 between fields, 6–8 inside rows.
- Stacked outlined inputs need a gap between them (use `Column(spacing: 14)` or `SizedBox`), or
  their floating labels collide. A scroll view that starts with an input needs about 8px of top
  padding so the label isn't clipped.

## Interaction patterns

- **Secondary editors are side sheets, not dialogs.** Collection-level editors (Schema, Queries)
  open through `showSideSheet(kicker: collectionName, title: …)`, which has a footer note and a
  primary Done. Don't stack dialogs: add or create inline inside the sheet (see the "New field"
  and field edit panels, which have an `accentEdge` border). On a phone, where the sheet is too
  short for a form, an item opens as its own pushed screen instead (`FieldEditorScreen`).
- **Dialogs** are for focused edits and confirmations. The title is 20/500, and actions are
  Cancel (`TextButton`) then the primary (`FilledButton`), right-aligned.
- **Create and edit forms use `FormSurface`**, opened with `showFormSurface()`. Don't build a
  form out of `AlertDialog` or an inline `showModalBottomSheet`. The surface picks the
  presentation from the screen width:
  - On a phone (<720) it is a bottom sheet with a drag handle, title plus context
    (`contextLabel: 'in <collection>'`), and Cancel (1 part) beside the primary (2 parts). Its
    inputs are 48px from the input tokens; the surface doesn't restyle them. The record editor
    instead sets `closeInHeader` (a ✕ ends the title row), `menuActions` (one ⋮ menu) and
    `fullWidthPrimaryOnPhone` (only the primary, full width, 52px).
  - In a dialog, `footerHint` ("* Required · Ctrl+Enter to save") and `leadingFooterAction` (a
    destructive "Delete…") sit at the footer's leading edge, apart from Cancel and the primary;
    `submitOnCtrlEnter` runs the primary on Ctrl+Enter; `showContextInDialog` shows the context
    beside the title.
  - `summary` is pinned above the footer, outside the scrolling body (the record editor's
    `FormErrorSummary`).
  - Otherwise it is a dialog, and with an `aside` at ≥820 a two-pane dialog.
  - `headerActions` (such as Remove) are icon buttons in the sheet's title row, and text buttons
    before Cancel in a dialog. Give each a `Key`; it is applied in both modes.
  - An `aside` (a live preview) is pinned between the body and the footer when there is no room
    for a pane, capped at 160px (pass a compact `pinnedAside`), and hidden while the keyboard is up.
  - `message` / `errors` is the form-level slot directly above the buttons, drawn in the error
    color, for errors that belong to no single input.
  - `showRequiredLegend` adds the single "* required" line under the title.
  - Confirmations stay `AlertDialog`s.
- **Form errors** follow one model, `FormIssues` (`controllers.dart`), built from a `BridgeError`
  with `FormIssues.from(error)` or from a list of issues:
  - An issue that names exactly one field (or form key) shows directly under that input: an
    accent border on the control, a warning icon and the message in `danger`, the same
    red as the form-level slot. Pass the lines as `errors:` to the shared input, which draws them
    with `FieldErrorMessage` so each issue is its own line; controls without a decoration (a switch, a segmented choice) use
    `FieldErrorLines`. Several issues on one field are several lines, in Rust's order, with no
    bullets. Tests read them back with `decorationErrorText()`.
  - After a save leaves fields with errors, the record editor pins a `FormErrorSummary` above the
    footer; Show scrolls to the first field in error, in form order, and focuses it. Pressing
    Save does the same jump on its own; the debounced re-validation while editing never moves
    the form.
  - An issue that names no field or several, and any non-validation failure, goes in the
    form-level slot above Cancel / primary (`FormSurface.errors`, or `FormErrorLines` placed just
    before a custom form's actions), one line per issue.
  - Map Rust's form keys to inputs with `FormIssues.keyed({...})` or `restrictTo({...})`; a key
    with no input falls into the form slot so nothing is lost.
  - Messages come from Rust and never contain ids. Don't prefix them with the field name; they sit
    under it.
- **Validation timing:** show nothing before the first press of the primary action. Keep the
  primary enabled; pressing it validates and shows what is wrong. After that first attempt, every
  edit re-validates and errors clear as soon as they are fixed (record forms re-run Rust's
  `validateRecordDraft` dry run, debounced ~200ms, dropping stale answers; other forms clear an
  input's issues when it changes and recompute client blockers). A record opened because the list
  marks it invalid starts in the attempted state.
- **Required inputs** get an `*` after the label in `accentText`, never the error color, via
  `requiredLabel(name)` (the shared inputs apply it with `required: true`; a switch row uses it as
  its title; it reads "name, required" to screen readers). A form with any marked input shows one `RequiredLegend` ("* required") line; the record editor
  says it in its desktop footer hint instead. A required schema field with a default, fixed or
  relative, is not marked (`FieldRendererRegistry.marksRequired`).
- **Record saves go through one Rust command.** New and Edit record both call
  `saveRecordDraft` (an edit sends only the changed fields), carrying the options the form added
  as pending options (`PendingOptionDto`, picked in values by a `pending:<n>` key). The record
  editor holds them until Save, drops one as soon as no value picks it, and passes them to the
  debounced `validateRecordDraft`; discarding the form creates nothing.
- **Date and Date & time record editors offer Today / Now.** Pass `quickFill: true` to
  `FieldRendererRegistry.editor` wherever a record value is entered (new, edit, batch edit); it
  adds the action as a button beside the box at ≥720 and an inline accent link inside the box
  below, hidden while the input holds a value. Today fills the local calendar day; Now fills
  the current local minute. Schema metadata slots (default, minimum, maximum) and query inputs
  never pass it, because a quick fill there would freeze the moment the schema was edited. The
  Date & time editor always shows local time as `yyyy-MM-dd HH:mm` (`formatDateTime`).
- **Wrap bottom sheet content in `BottomSheetInsets`** (`lib/theme/side_sheet.dart`) so it clears
  both the keyboard and Android's navigation bar. `useSafeArea` alone leaves the bottom uncovered.
- **Selection mode** swaps the header for an `accentFill` action bar with an `accentEdge` border.
  The content behind it drops to 40% opacity and ignores taps.
- **Status** is shown with `GlowDot` (lit accent while reaching peers, dim `neutralGhost` when
  offline, error color on error) plus a short label.
- **Empty and missing values** are "—" at 40% opacity. Invalid items get a small `warning_amber`
  icon in the error color.
- **Dates for reading** use `formatDateTimeHuman` / `formatDateHuman` from `exact_format.dart`
  ("Sep 22, 2026 · 14:05", or "Sep 22 · 14:05" when short). Editors keep the sortable formats.
  Use `FieldRendererRegistry().displayText(..., human: true)` for table cells.
- **States:** hover is a `text@4–7%` or `accent@10–12%` tint, pressed about double that, disabled
  45% opacity. There is no ink ripple (`NoSplash`). The theme already provides all of this, so
  don't restyle per widget.

- **Voice fill** exists only in the phone New record sheet and only when `VoiceScope.of` returns
  services (an engine is available; the fake one in debug builds or with
  `--dart-define=FI_VOICE_FAKE=true`). Whole-form fill is never in Edit record or a dialog. The sheet is its own route,
  so `_recordEditor` carries the shell's `VoiceScope` into it. `FormSurface.phoneFooterLeading`
  holds the 56px `VoiceMicButton` beside a flexible Save; `FormSurface.top` holds the `VoicePanel`.
  Each mic state has its own icon and label, never color alone. Panels use `bg` cards with 8px
  radius; the primer and listening panels use the accentFill→bg radial glow with an accentEdge edge.
  A voice-filled field shows `VoiceChip` in its label row and `VoiceFieldMark` (accentFill tint,
  accentEdge border) on its control; a field a turn asks for gets the Needed marker and a dashed
  accent border. The evidence popover is inline under the label row, not an overlay. Save is
  disabled only while listening or processing, and closing with changes asks "Discard this
  record?". Transcripts stay in the controller's memory and die with the sheet: never log, persist
  or send them.
- **Field dictation** (mocks `record-form-field-states` Dictation, `record-form-edit`,
  `voice-dictation-review`) puts a `DictationMic` in the trailing slot of every Text and multiline
  Text input of New and Edit record, on Android (`PlatformScope.android`) with an engine, at any
  width. `DictationController` owns the turn; the form's `VoiceTurnCoordinator` lets one turn run
  at a time, so every other field mic and the footer mic are disabled meanwhile. While listening
  or processing, the input shows `DictationStateRow` over its value (`FiTextInput.overlay`: level
  bars and "Listening… m:ss", or a ring and "Cleaning up…"), keeps its text and is read-only; the
  mic becomes a stop square. Failures are one `DictationErrorLine` under the field with Retry.
  Setup reuses the panel's `VoicePrimerCard`, `VoiceOfferCard` and `VoiceErrorCard` in a bottom
  sheet (phone) or dialog (wide). The "Dictated" review (`DictationReview`) offers Cleaned
  (Default) and As heard (removed words struck through, and read out as "Removed: …"), then
  Insert for an empty field or Append / Replace (Replace primary); it is skipped when the field is
  empty and nothing was cleaned. Applied text goes through the keystroke path: it counts as typed,
  gets no Voice marker, and makes closing ask first.

## Charts

All `fl_chart` code stays in `lib/widgets/chart_renderers.dart`. Series use `c.accent`;
grid lines use `_gridLine` (dashed divider). Axis labels are exact values rendered by the app, never
chart-package ticks.

## Tests and verification

- Keep widget types stable where tests find them by type: `FilledButton` (Save / primary),
  `TextButton` (Cancel), `SwitchListTile`, `DropdownButtonFormField`, `Checkbox`,
  `PopupMenuButton<String>`. `FiSelect<T>` builds a `DropdownButtonFormField<T>` (which contains
  a `DropdownButton<T>`), and `FiTextInput` / `FiPickerInput` build a `TextFormField` (which
  contains a `TextField`). A `Key` given to a shared input sits on the wrapper, so look the
  `TextField` up with `find.descendant` when a test reads its decoration.
- `test/inputs_test.dart` guards the input heights: add a case there for any new input kind. Note that `FilledButton.icon` has a different runtime type, so
  `find.widgetWithText(FilledButton, …)` won't match it. Use plain `FilledButton` where tests look
  it up.
- Tests render with a wide placeholder font. Any `Text` inside a `Row` needs
  `Flexible`/`Expanded` plus ellipsis, or it overflows in tests.
- Side sheets slide in. In tests, `pumpAndSettle()` before tapping inside them.
- Without ripples, a stream event can land after the last frame; add a second `pump()` rather
  than depending on an animation keeping frames queued.
- Checks after UI work: `flutter analyze`, `flutter test`, then look at the result at 1280×800 and
  390×844. To see it without a desktop, render goldens in a throwaway test: load the fonts with
  `FontLoader` from `assets/fonts/…` and `fonts/MaterialIcons-Regular.otf`, then write goldens to a
  scratch directory with `--update-goldens`. Delete the test afterwards. Test goldens draw shadows
  as solid black; that's expected.
- Both themes: `test/latte_theme_test.dart` pumps the key screens under Latte and Mocha and fails
  if a Mocha-only color is drawn on Latte (`expectNoMochaColor`). Use `platformBrightness(tester, …)`
  (or `useDarkPlatform` from `widget_test.dart`) when a test asserts a theme's colors: the test
  platform is light, so the app draws Latte by default.
- Latte goldens: `test/latte_goldens_test.dart` renders 12 mocked screens (onboarding-first-run, collections, collection-records, collection-selection, record-form-empty, record-form-edit, schema-sheet, devices, settings, settings-language, settings-model-states, settings-microphone) under Latte at 1280×800 and
  390×844 with the bundled fonts into `test/goldens/latte/`. Compare them with the mocks in
  `design/project/Fi Redesign.dc.html` toggled to `data-theme="light"`; fix a wrong color by picking
  another role, never a numbered step. Regenerate after a deliberate change with
  `flutter test --update-goldens test/latte_goldens_test.dart` (Linux host only; rasterization differs elsewhere).
- Run commands through the nix dev shell: `nix develop -c bash -c 'cd flutter_app && flutter test'`.

## Not done yet

- Android launcher icon from the 3b mark (needs a PNG / adaptive icon set).
- Swipe-to-delete on phone record rows.
- A segmented aggregation picker in the query editor (tests currently drive the dropdown).
- Buttons beside inputs are not sized to the input tokens yet.
- A "Current result" line in the query editor (no API evaluates a saved query outside a widget).
