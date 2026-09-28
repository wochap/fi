# nocturne-visual-system Specification

## Purpose

Defines the icon set, the field-type icons, and the small shared marks (clear button, tags, field-status markers, switches, phone touch targets) that every Fi screen uses, so that redesigned screens match `docs/design/fi-redesign`.

## Requirements

### Requirement: Phosphor is the only icon set
The Flutter app SHALL draw every icon from the Phosphor icon set, in the regular weight unless a design mock names the fill or bold weight for that use. App code MUST NOT use Material `Icons.*` glyphs; where a framework widget would draw its own Material glyph (such as a default back button), the app SHALL supply the Phosphor icon explicitly. Replacing an icon SHALL NOT change the surrounding layout, the icon's size, its color, or the tooltip or semantic label it carries.

#### Scenario: No Material glyphs remain
- **WHEN** the app's screens are rendered in widget tests (collections, collection view, record form, schema sheet, devices, pairing, onboarding, recovery)
- **THEN** no `Icon` that app code supplies uses a glyph from the Material Icons font, and the app source contains no reference to `Icons.`

#### Scenario: Icon swap keeps tooltips
- **WHEN** an icon-only button that had the tooltip "More actions" is rendered after the swap
- **THEN** it shows the Phosphor `dots-three-vertical` glyph at the same size and still has the tooltip "More actions"

### Requirement: Field type icons
The app SHALL show one fixed Phosphor icon for each field type wherever a field type is shown with an icon: Text `text-aa`, Integer `hash`, Decimal `percent`, Boolean `toggle-left`, Date `calendar-blank`, Date & time `calendar-check`, Duration `timer`, Choice `list-bullets`. Every field type SHALL have exactly one icon, and no two types SHALL share an icon.

#### Scenario: Every type has its icon
- **WHEN** the type icon is requested for each of the eight field types
- **THEN** each returns the Phosphor glyph listed above and the eight glyphs are distinct

### Requirement: Clear mark
The app SHALL provide one clear (✕) mark for removing a field's value: a 22px circle filled with neutral-700 holding an 11px `x` glyph in the text color. On screens narrower than 720px its tappable area SHALL be at least 44×44px while the drawn circle stays 22px. A form field SHALL show the clear mark only when the field is optional and currently has a value, and MUST NOT show it on a required field. Activating it SHALL clear the value and SHALL carry the accessible label "Clear".

#### Scenario: Optional field with a value
- **WHEN** an optional text field holding "Groceries" is rendered
- **THEN** a clear mark labelled "Clear" is shown inside the input, and tapping it empties the field

#### Scenario: Optional field without a value
- **WHEN** an optional text field is empty
- **THEN** no clear mark is shown

#### Scenario: Required field
- **WHEN** a required text field holding "Buy oat milk" is rendered
- **THEN** no clear mark is shown

#### Scenario: Phone hit area
- **WHEN** the clear mark is rendered on a 390px-wide screen
- **THEN** its drawn circle is 22px and its tappable area is at least 44×44px

### Requirement: Tag variants
The app SHALL provide tags in three variants matching the design system: accent (accent-800 fill, accent-100 text), neutral (neutral-800 fill, neutral-100 text), and outline (transparent fill, 1px accent border, accent text). All tags SHALL use 11px text with 0.02em letter spacing, 3px by 10px padding, and a 6px corner radius, and MAY show a leading icon 4px before the text in the text color.

#### Scenario: Outline tag with an icon
- **WHEN** an outline tag "Incomplete" with a `warning-circle` icon is rendered
- **THEN** it has no fill, a 1px accent border, accent text and icon, 11px text and a 6px radius

#### Scenario: Accent tag
- **WHEN** an accent tag "Required" is rendered
- **THEN** it has an accent-800 fill and accent-100 text

### Requirement: Field status markers
The app SHALL provide three markers that sit at the trailing end of a form field's label row, and SHALL never convey a field's status by color alone:
- Voice: a chip at least 28px tall with 8px horizontal padding and a 14px radius, accent-900 fill, a 1px accent-700 inner ring, a filled `sparkle` glyph and the text "Voice" at 11px in accent-100. It is a button whose accessible label names the field and says it was filled by voice.
- Default: the `arrow-bend-down-right` glyph and the text "Default" at 11px in the text color at 55% opacity.
- Needed: the `warning-circle` glyph and the text "Needed" at 11px in accent-200.

#### Scenario: Voice chip is a labelled button
- **WHEN** the Voice marker is rendered for the field "amount"
- **THEN** it shows the sparkle glyph and "Voice", is at least 28px tall, and has an accessible label containing "amount" and "filled by voice"

#### Scenario: Status is readable without color
- **WHEN** the Default and Needed markers are rendered
- **THEN** each shows its own glyph and its own word, so the two are distinguishable in grayscale

### Requirement: Switch sizes
Switches SHALL be 38×22px with a 12px knob on screens at least 720px wide and 44×26px with a 14px knob on narrower screens. An on switch SHALL have a 1px accent border, an accent-900 track and an accent knob at the trailing end; an off switch SHALL have a 1px divider border, no track fill and a knob in the text color at 55% opacity at the leading end.

#### Scenario: Desktop switch
- **WHEN** an on switch is rendered on a 1240px-wide screen
- **THEN** it is 38×22px with a 12px accent knob at the trailing end

#### Scenario: Phone switch
- **WHEN** an off switch is rendered on a 390px-wide screen
- **THEN** it is 44×26px with a 14px muted knob at the leading end and a divider-colored border

### Requirement: Phone touch targets and row height
The app SHALL provide a shared phone-sized icon button and a shared card list row for redesigned screens. On screens narrower than 720px the icon button SHALL have a hit area of at least 44×44px and the card list row SHALL be at least 64px tall; on wider screens the icon button SHALL stay 36×36px and the row SHALL size to its content. Screens that are not yet redesigned keep their current sizes.

#### Scenario: Icon button on a phone
- **WHEN** the shared icon button is rendered on a 390px-wide screen
- **THEN** its tappable area is at least 44×44px

#### Scenario: Icon button on desktop
- **WHEN** the shared icon button is rendered on a 1240px-wide screen
- **THEN** it is 36×36px

#### Scenario: List row on a phone
- **WHEN** the shared card list row is rendered on a 390px-wide screen with one line of text
- **THEN** the row is at least 64px tall
