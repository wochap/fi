# nocturne-visual-system Specification

## Purpose

Defines the icon set, the field-type icons, and the small shared marks (clear button, tags, field-status markers, switches, phone touch targets) that every Fi screen uses, so that redesigned screens match `design/project/Fi Redesign.dc.html`.

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
The app SHALL show one fixed Phosphor icon for each field type wherever a field type is shown with an icon: Text `text-aa`, Integer `hash`, Decimal `percent`, Boolean `toggle-left`, Date `calendar-blank`, Date & time `calendar-check`, Duration `timer`, Choice `list-bullets`, Choices `list-checks`. Every field type SHALL have exactly one icon, and no two types SHALL share an icon.

#### Scenario: Every type has its icon
- **WHEN** the type icon is requested for each of the nine field types
- **THEN** each returns the Phosphor glyph listed above and the nine glyphs are distinct

### Requirement: Clear mark
The app SHALL provide one clear (✕) mark for removing a field's value: a 22px circle filled with the neutral edge role holding an 11px `x` glyph in the text color. On screens narrower than 720px its tappable area SHALL be at least 44×44px while the drawn circle stays 22px. A form field SHALL show the clear mark only when the field is optional and currently has a value, and MUST NOT show it on a required field. Activating it SHALL clear the value and SHALL carry the accessible label "Clear".

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

#### Scenario: Mocha fill
- **WHEN** the clear mark is rendered in the dark theme
- **THEN** its circle is `#585b70`

### Requirement: Tag variants
The app SHALL provide tags in five variants matching the design system: accent (accent fill role, accent ink strong text), neutral (neutral fill strong role, text color), outline (transparent fill, 1px accent border, accent text), danger (transparent fill, 1px danger border, text-colored label, danger icon) and success (success at 22% opacity as the fill, text-colored label, success icon). All tags SHALL use 11px text with 0.02em letter spacing, 3px by 10px padding, and a 6px corner radius, and MAY show a leading icon 4px before the text in the text color, except that the danger and success variants draw their icon in their status color.

#### Scenario: Outline tag with an icon
- **WHEN** an outline tag "Incomplete" with a `warning-circle` icon is rendered
- **THEN** it has no fill, a 1px accent border, accent text and icon, 11px text and a 6px radius

#### Scenario: Accent tag
- **WHEN** an accent tag "Required" is rendered in the dark theme
- **THEN** it has the accent fill role `#251e2d` as its fill and the accent ink strong role `#f5eefe` as its text

#### Scenario: Danger tag
- **WHEN** a danger tag "Revoked" with an icon is rendered
- **THEN** it has no fill, a 1px danger border, its label in the text color and its icon in danger

#### Scenario: Success tag
- **WHEN** a success tag "Synced" with an icon is rendered
- **THEN** its fill is success at 22% opacity, its label is in the text color and its icon is in success

### Requirement: Field status markers
The app SHALL provide three markers that sit at the trailing end of a form field's label row, and SHALL never convey a field's status by color alone:
- Voice: a chip at least 28px tall with 8px horizontal padding and a 14px radius, the accent fill role as its fill, a 1px inner ring in the accent edge role, a filled `sparkle` glyph and the text "Voice" at 11px in the accent ink strong role. It is a button whose accessible label names the field and says it was filled by voice.
- Default: the `arrow-bend-down-right` glyph and the text "Default" at 11px in the text color at 55% opacity.
- Needed: the `warning-circle` glyph and the text "Needed" at 11px in the accent ink role.

#### Scenario: Voice chip is a labelled button
- **WHEN** the Voice marker is rendered for the field "amount"
- **THEN** it shows the sparkle glyph and "Voice", is at least 28px tall, and has an accessible label containing "amount" and "filled by voice"

#### Scenario: Status is readable without color
- **WHEN** the Default and Needed markers are rendered
- **THEN** each shows its own glyph and its own word, so the two are distinguishable in grayscale

### Requirement: Switch sizes
Switches SHALL be 38×22px with a 12px knob on screens at least 720px wide and 44×26px with a 14px knob on narrower screens. An on switch SHALL have a 1px accent border, a track in the accent fill role and an accent knob at the trailing end; an off switch SHALL have a 1px divider border, no track fill and a knob in the text color at 55% opacity at the leading end.

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

### Requirement: Catppuccin Mocha palette
The app's dark theme SHALL use the Catppuccin Mocha tokens of the design system (`design/project/_ds/nocturne-*/styles.css`, `:root`): bg `#1e1e2e`, surface `#313244`, text `#cdd6f4`, accent `#cba6f7`, divider `#585b70` at 60% opacity, section `#181825`, section glow `#45475a`, section ghost `#6c7086`, scrim `#11111b` at 65% opacity, the neutral ramp 100–900 `#cdd6f4`, `#bac2de`, `#a6adc8`, `#9399b2`, `#7f849c`, `#6c7086`, `#585b70`, `#45475a`, `#313244`, and the accent ramp 100–900 `#f5eefe`, `#ecddff`, `#d9c2f6`, `#d2b4f6`, `#cba6f7`, `#9377b5`, `#5f4a76`, `#413350`, `#251e2d`. Shadows SHALL be: small, a 1px `#585b70` edge; medium, a 1px `#6c7086` edge plus a 0/6/18px black shadow at 55%; large, a 1px `#7f849c` edge plus a 0/16/40px black shadow at 65%. Dialog and sheet backdrops SHALL use the scrim. The lavender ramp (`accent-2`) is not part of the app palette.

#### Scenario: Page and card colors
- **WHEN** the collections screen is rendered in the dark theme
- **THEN** the page background is `#1e1e2e`, cards are `#313244` and body text is `#cdd6f4`

#### Scenario: Dialog backdrop
- **WHEN** a confirm dialog opens over a screen
- **THEN** the barrier behind it is `#11111b` at 65% opacity

### Requirement: Colors come from the active theme
Every color and shadow a widget draws SHALL come from one theme color set provided by the app theme, so that providing a different set changes every screen without changing the widgets. Widget code SHALL name a theme token (bg, surface, text, accent, divider, scrim, section tokens, shadows, the text color at an opacity) or a theme-relative role, and MUST NOT name a numbered ramp step (`accent100`–`accent900`, `neutral100`–`neutral900`), a color literal, or a `Colors.*` member other than `Colors.transparent`; only the theme definition files may. A design-rules test SHALL scan the app source and fail naming each file and line that breaks this rule.

#### Scenario: Numbered step in feature code
- **WHEN** a screen file outside the theme definition reads the accent 900 step directly
- **THEN** the design-rules test fails and names that file and line

#### Scenario: One set drives every screen
- **WHEN** the app theme is built from a color set whose surface differs from Mocha's
- **THEN** cards, sheets and dialogs on every screen draw that surface with no change to their widget code

### Requirement: Theme-relative roles
The theme color set SHALL provide these roles, each pointing at a step of the active theme's ramps: accent fill, accent edge, accent text, accent ink, accent ink strong, neutral fill, neutral fill strong, neutral edge, neutral ghost and neutral muted. In Mocha they SHALL be accent 900, accent 700, accent 300, accent 200, accent 100, neutral 900, neutral 800, neutral 700, neutral 600 and neutral 500. Tinted fills SHALL use a fill role, borders and rings an edge role, paragraph-size accent text the accent text role, small accent labels and icons on a fill the accent ink role, and text on an accent fill the accent ink strong role.

#### Scenario: Selection bar
- **WHEN** selection mode shows its action bar
- **THEN** the bar is filled with the accent fill role and bordered with the accent edge role, which in Mocha are `#251e2d` and `#5f4a76`

#### Scenario: Paragraph-size accent text
- **WHEN** a sentence is drawn in the accent at body size
- **THEN** it uses the accent text role, `#d9c2f6` in Mocha, not the accent itself

### Requirement: Status colors
The theme color set SHALL provide danger `#f38ba8`, success `#a6e3a1` and warning `#f9e2af` in Mocha. Errors, failed and revoked states SHALL use danger; synced and ready states SHALL use success; expired, locked and attention states SHALL use warning. Status colors SHALL color icons, marks, outlines and tag edges or fills only; words, including tag labels and sentences, SHALL stay in the text color in every theme. An error, failed, revoked, synced, ready, expired or locked state MUST NOT be faked with the accent or a faded text color, and no status SHALL be shown by color alone. The accent remains the color of active, selected, connected, syncing and other in-progress or attention-neutral states, such as the Incomplete outline tag and a lit glow dot.

#### Scenario: Failed download
- **WHEN** the voice models card shows the Failed state
- **THEN** its state tag uses the danger variant with a danger icon and the word "Failed" in the text color, and the reason line is in the text color

#### Scenario: Ready models
- **WHEN** the voice models card shows the Ready state
- **THEN** its state tag uses the success variant with a success icon and the word "Ready" in the text color

#### Scenario: Locked keystore
- **WHEN** the keystore-locked screen is shown
- **THEN** its status icon is drawn in warning and its explanation in the text color
