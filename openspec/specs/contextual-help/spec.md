## Purpose

TBD: Define the keyed contextual help-copy registry and the help affordances placed beside non-obvious controls.

## Requirements

### Requirement: Keyed help-copy registry
The Flutter application SHALL hold all contextual help copy in one registry keyed by a stable help id, and every help affordance SHALL resolve its text through that registry rather than embedding copy at the call site. A help id that is referenced but not present in the registry SHALL fail a test rather than render an empty popup.

#### Scenario: Copy is reviewable in one place
- **WHEN** a reviewer opens the help-copy registry
- **THEN** every help id used by the field editor, widget form, computed-fields-and-queries dialog, and pairing card is present with its text

#### Scenario: Missing help id
- **WHEN** a surface references a help id absent from the registry
- **THEN** the registry test fails naming the id, and at runtime the affordance is not rendered rather than rendering an empty popup

### Requirement: Help affordance beside non-obvious controls
Surfaces SHALL place a `?` help button beside each control whose meaning is not self-evident, and tapping it SHALL open a dismissible popup showing the registry copy for that control without changing any form state. At minimum the following controls SHALL carry a help affordance: in the field editor, Required, Default, Decimal scale, Minimum/Maximum, Minimum/Maximum length, and Multiline; in the widget form, Widget type, Use a saved query, Aggregation, Field to aggregate, Output scale and Rounding policy, Group by, Date field, Category field, X axis and Y axis, Filter, and each presentation option; in the computed-fields-and-queries dialog, the Computed fields section, the Source field, and the Saved queries section; on the pairing card, Start pairing and the single-initiator hint.

#### Scenario: Open help for Required
- **WHEN** the user taps the `?` beside the Required switch in the field editor
- **THEN** a popup explains what required means, that existing records lacking the field are marked invalid, and that a default fills the field for existing and new records; the switch value is unchanged

#### Scenario: Open help for Group by
- **WHEN** the user taps the `?` beside Group by in the widget form
- **THEN** a popup explains that grouping buckets records by calendar period on the chosen date field and that the aggregation is computed per bucket

#### Scenario: Popup dismissal
- **WHEN** the help popup is open and the user taps outside it or its close action
- **THEN** the popup closes and the underlying form retains every value it held before the popup opened
