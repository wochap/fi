## Purpose

TBD: Define the keyed contextual help-copy registry and the help affordances placed beside non-obvious controls.

## Requirements

### Requirement: Keyed help-copy registry
The Flutter application SHALL hold all contextual help copy in one registry keyed by a stable help id, and every help affordance SHALL resolve its text through that registry rather than embedding copy at the call site. The registry SHALL hold a title and body for every help id in each supported interface language, and an affordance SHALL show the copy of the active language. A help id that is referenced but not present in the registry, or whose copy is missing or empty in any supported language, SHALL fail a test rather than render an empty popup.

#### Scenario: Copy is reviewable in one place
- **WHEN** a reviewer opens the help-copy registry
- **THEN** every help id used by the field editor, widget form, computed-fields-and-queries dialog, and pairing card is present with its text

#### Scenario: Missing help id
- **WHEN** a surface references a help id absent from the registry
- **THEN** the registry test fails naming the id, and at runtime the affordance is not rendered rather than rendering an empty popup

#### Scenario: Help in Spanish
- **WHEN** the interface is in Spanish and the user taps the `?` beside the Required switch in the field editor
- **THEN** the popup shows the Spanish title and body for Required

#### Scenario: Spanish help copy missing
- **WHEN** a help id has English copy but no Spanish copy
- **THEN** the registry test fails naming the id and the language

### Requirement: Help affordance beside non-obvious controls
Surfaces SHALL place a `?` help button beside each control whose meaning is not self-evident, and tapping it SHALL open a dismissible popup showing the registry copy for that control without changing any form state. The `?` button SHALL be at least 28×28 at 720px and wider and at least 44×44 below 720px. At 720px and wider the popup SHALL be a popover anchored under the `?` button, showing the title, the body and a "Got it" action, and SHALL close on "Got it", Esc, or a click outside it. Below 720px the popup SHALL be a bottom sheet showing the title, the body and a full-width "Got it" action, and SHALL close on "Got it", a tap outside it, a swipe down, or system back. At minimum the following controls SHALL carry a help affordance: in the field editor, Required, Default, Decimal scale, Minimum/Maximum (Range and Date range), Minimum/Maximum length, Multiline, and Show as slider; in the widget form, Widget type, Use a saved query, Aggregation, Field to aggregate, Output scale and Rounding policy, Group by, Date field, Category field, X axis and Y axis, Filter, and each presentation option; in the computed-fields-and-queries dialog, the Computed fields section, the Source field, and the Saved queries section; on the pairing card, Start pairing and the single-initiator hint.

#### Scenario: Open help for Required
- **WHEN** the user taps the `?` beside the Required switch in the field editor
- **THEN** a popup explains what required means, that existing records lacking the field are marked invalid, and that a default fills the field for existing and new records; the switch value is unchanged

#### Scenario: Open help for Group by
- **WHEN** the user taps the `?` beside Group by in the widget form
- **THEN** a popup explains that grouping buckets records by calendar period on the chosen date field and that the aggregation is computed per bucket

#### Scenario: Popup dismissal
- **WHEN** the help popup is open and the user taps outside it or "Got it"
- **THEN** the popup closes and the underlying form retains every value it held before the popup opened

#### Scenario: Popover on desktop
- **WHEN** the user clicks the `?` beside Use a saved query in the widget form on a 1240px-wide screen
- **THEN** a popover opens under that button with the title "Use a saved query", its body and "Got it", and pressing Esc closes it

#### Scenario: Bottom sheet on a phone
- **WHEN** the user taps a `?` on a 390px-wide screen
- **THEN** a bottom sheet opens with the help title, body and a full-width "Got it", and the `?` button they tapped measures at least 44×44
