# Fi UI design guide (Nocturne)

Read this before adding or changing any Flutter UI. The app follows **Nocturne**: a quiet, dense,
dark interface. Inter at weight 500 for headings, soft 8px corners, and an accent used as a line or a
glow, never as a flood of color. Follow these rules so new screens match the existing ones.

## Where things live

| File | What it holds |
| --- | --- |
| `lib/theme/nocturne.dart` | `Nocturne` tokens (colors, radii, shadows, fonts) and `nocturneTheme()`, the only `ThemeData` |
| `lib/theme/nocturne_widgets.dart` | Shared pieces: `FadedRule`, `Kicker`, `SectionLabel`, `GlowDot`, `IconTile`, `Tag`, `NocturneCard`, `nocturneGlow()`, `DashedSlot`, `FiLogoMark`, `FiLogoTile` |
| `lib/theme/side_sheet.dart` | `showSideSheet()`: a 480px sheet from the right, or a bottom sheet on a phone |
| `lib/theme/form_surface.dart` | `showFormSurface()` + `FormSurface`: every create/edit form, a bottom sheet on a phone and a dialog (optionally two-pane with an aside) otherwise |
| `assets/fonts/` | Inter (400, 500) and JetBrains Mono (400), with OFL licences |

Before building something new, look for an existing piece that already does it. Add a new shared
widget to `nocturne_widgets.dart` only when a second screen needs it.

## Hard rules

1. **Take every color from the tokens.** Use `Nocturne.*` or `Theme.of(context).colorScheme`,
   never `Colors.red`, `Colors.green` or hex literals in feature code. Muted text is
   `Nocturne.muted(opacity)`. The only `Colors.*` allowed outside `lib/theme/` is
   `Colors.transparent`.
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
   glows. For tinted fills use the dark ramp steps (`accent900`, `accent800`, `neutral800`), never
   the accent itself on a large area. Text drawn in the accent at paragraph size should be
   `accent300`.
7. **Dark only.** There is no light theme; don't add `brightness` branches.
8. **Use Material icons** (outlined variants where they exist). The design system mentions
   Phosphor icons; this app deliberately uses Material instead.

## Type scale

The type scale lives in `nocturneTheme().textTheme`. Prefer it over ad-hoc `TextStyle`s; if you
must write one, use these sizes:

| Use | Style |
| --- | --- |
| Page title, desktop (h2) | `headlineMedium`: 32/500, letter spacing −0.015em |
| Page title, phone (h3) | `headlineSmall`: 25/500 |
| Dialog or sheet title | `titleLarge`: 20/500 |
| Card title | 17/500, set explicitly (`titleMedium` is deliberately 14 because Material uses it for dropdown values) |
| Body / inputs | 14 |
| Meta / secondary line | 12–13 at `Nocturne.muted(.55–.6)` |
| Section heading | `SectionLabel('…')`: 13/500, uppercase, 0.08em letter spacing, 60% opacity |
| Card kicker | `Kicker('…')`: 10px, uppercase, accent (widget tiles keep the title's own case) |
| Table header | 11px uppercase, 60% opacity, with the field kind after it at lower opacity |
| Numbers | Add `fontFeatures: Nocturne.tabular` to every column or figure of numbers |
| Ids, formulas, codes | `fontFamily: Nocturne.monoFamily` |

## Surfaces and elevation

- The page ground is `Nocturne.bg`. Cards and sheets are `Nocturne.surface` with a 1px
  `neutral800` edge: use `NocturneCard` or the themed `Card` (zero margin, no shadow).
- Rows inside a sheet sit on `Nocturne.bg` with radius 8 (see `_SheetRow` and `_schemaRow` in
  `collections_page.dart`).
- Use `Nocturne.shadowSm`, `shadowMd` or `shadowLg` for elevation, never ad-hoc heavy shadows.
- For depth, use `nocturneGlow()` on cards: an elliptical `accent900` glow in one corner. Only
  headline cards get it (stat tiles, the pairing card); charts and lists stay flat.
- **Rules fade.** For a freestanding horizontal rule use `FadedRule()`, which fades out over 48px
  at each end. Box outlines, dividers inside a control, and the top border of a sheet footer stay
  solid. Prefer whitespace to rules.
- For "add another" slots, use `DashedSlot`.

## Layout and breakpoints

| Where | Breakpoint | Behavior |
| --- | --- | --- |
| Screen width (`MediaQuery`) | 720 | ≥720: 216px sidebar (`_Sidebar` in `app.dart`). <720: slim logo row plus `NavigationBar`, bottom sheets instead of side sheets, larger touch targets (44–48px), create/edit forms as bottom sheets |
| Collection content width (`LayoutBuilder`) | 760 | ≥760: records table and labelled header buttons. <760: record card list, icon buttons, floating "+ Record" button |
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
  panel, which has an `accent700` border).
- **Dialogs** are for focused edits and confirmations. The title is 20/500, and actions are
  Cancel (`TextButton`) then the primary (`FilledButton`), right-aligned.
- **Create and edit forms use `FormSurface`**, opened with `showFormSurface()`. Don't build a
  form out of `AlertDialog` or an inline `showModalBottomSheet`. The surface picks the
  presentation from the screen width:
  - On a phone (<720) it is a bottom sheet with a drag handle, title plus context
    (`contextLabel: 'in <collection>'`), 48px inputs, and Cancel (1 part) beside the primary
    (2 parts).
  - Otherwise it is a dialog, and with an `aside` at ≥820 a two-pane dialog.
  - `headerActions` (such as Remove) are icon buttons in the sheet's title row, and text buttons
    before Cancel in a dialog. Give each a `Key`; it is applied in both modes.
  - An `aside` (a live preview) is pinned between the body and the footer when there is no room
    for a pane, capped at 160px (pass a compact `pinnedAside`), and hidden while the keyboard is up.
  - `message` is the form-level slot directly above the buttons, drawn in the error color, for
    errors that belong to no single input.
  - Confirmations stay `AlertDialog`s.
- **Wrap bottom sheet content in `BottomSheetInsets`** (`lib/theme/side_sheet.dart`) so it clears
  both the keyboard and Android's navigation bar. `useSafeArea` alone leaves the bottom uncovered.
- **Selection mode** swaps the header for an `accent900` action bar with an `accent700` border.
  The content behind it drops to 40% opacity and ignores taps.
- **Status** is shown with `GlowDot` (lit accent while reaching peers, dim `neutral600` when
  offline, error color on error) plus a short label.
- **Empty and missing values** are "—" at 40% opacity. Invalid items get a small `warning_amber`
  icon in the error color.
- **Dates for reading** use `formatDateTimeHuman` / `formatDateHuman` from `exact_format.dart`
  ("Sep 22, 2026 · 14:05", or "Sep 22 · 14:05" when short). Editors keep the sortable formats.
  Use `FieldRendererRegistry().displayText(..., human: true)` for table cells.
- **States:** hover is a `text@4–7%` or `accent@10–12%` tint, pressed about double that, disabled
  45% opacity. There is no ink ripple (`NoSplash`). The theme already provides all of this, so
  don't restyle per widget.

## Charts

All `fl_chart` code stays in `lib/widgets/chart_renderers.dart`. Series use `Nocturne.accent`;
grid lines use `_gridLine` (dashed divider). Axis labels are exact values rendered by the app, never
chart-package ticks.

## Tests and verification

- Keep widget types stable where tests find them by type: `FilledButton` (Save / primary),
  `TextButton` (Cancel), `SwitchListTile`, `DropdownButtonFormField`, `Checkbox`,
  `PopupMenuButton<String>`. Note that `FilledButton.icon` has a different runtime type, so
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
- Run commands through the nix dev shell: `nix develop -c bash -c 'cd flutter_app && flutter test'`.

## Not done yet

- Android launcher icon from the 3b mark (needs a PNG / adaptive icon set).
- Swipe-to-delete on phone record rows.
- A segmented aggregation picker in the query editor (tests currently drive the dropdown).
- A "Current result" line in the query editor (no API evaluates a saved query outside a widget).
