# app-localization Specification

## Purpose

Shows the whole Flutter interface in English or Spanish. The app follows the system language, the user can override it, dates and numbers are formatted for the active language, and a check keeps the Spanish copy complete.

## Requirements

### Requirement: Supported interface languages
The app SHALL support exactly two interface languages: English (`en`) and Spanish (`es`). When the language preference is "System default", the app SHALL use the first system locale whose language is English or Spanish, in the order of the system's preferred locales. Region subtags SHALL be ignored, so `es-MX`, `es-ES` and `es-AR` all use Spanish. When no system locale is English or Spanish, the app SHALL use English. Where a quoted interface text appears in any spec, the quote is the English copy, and the Spanish interface SHALL show its Spanish translation in that place.

#### Scenario: Spanish system
- **WHEN** the language preference is System default and the system locale is `es-MX`
- **THEN** the interface is in Spanish, for example the bottom navigation reads "Colecciones", "Dispositivos" and "Ajustes"

#### Scenario: Unsupported system language falls back to English
- **WHEN** the language preference is System default and the system locales are `fr-FR` then `de-DE`
- **THEN** the interface is in English

#### Scenario: Second system locale is supported
- **WHEN** the language preference is System default and the system locales are `fr-FR` then `es-ES`
- **THEN** the interface is in Spanish

### Requirement: Language preference applies live and persists
The app SHALL keep a device-local language preference with three values: System default, English and Español. The default is System default. Changing it SHALL switch every visible screen, including open dialogs and sheets once they rebuild, to the chosen language without restarting the app and without losing navigation state or unsaved form input. The preference SHALL be stored on the device, kept across restarts, and never synced to other devices. While the preference is System default, a change of the system language while the app runs SHALL switch the interface too. An unreadable stored value SHALL be treated as System default.

#### Scenario: Switching to Español applies at once
- **WHEN** the interface is in English on the Settings page and the user picks Español
- **THEN** the Settings page reads "Ajustes" with the section "Idioma" immediately, and the selected destination is still Settings

#### Scenario: Preference survives a restart
- **WHEN** the user picks Español, closes the app and opens it again on an English system
- **THEN** the interface is in Spanish

#### Scenario: Back to System default
- **WHEN** the preference is Español on an English system and the user picks System default
- **THEN** the interface is in English

### Requirement: All user-facing text is localized
Every text the Flutter app shows to the user SHALL come from the active language's copy. This covers labels, headings, buttons, tabs, tooltips, hints, placeholders, empty states, dialogs, snackbars, banners, error lines, contextual help, pairing and SAS screens, the voice sheet panels and the voice models card, and the Settings sections. Pluralized counts SHALL use the plural rules of the active language. Spanish copy SHALL use neutral Latin American Spanish and address the user as "tú". The following SHALL stay the same in every language: user data (collection, field, option and device names, record values), the language names "English" and "Español", model friendly names, the product name "Fi", the build label, ids, addresses, ports, formulas, and the raw state, codes and log lines under a device's Details. Spoken voice feedback and voice example utterances are outside this requirement.

#### Scenario: Dialog in Spanish
- **WHEN** the interface is in Spanish and the user opens the voice models delete confirmation
- **THEN** the title, body and both buttons are Spanish, and the byte size in the body is formatted for Spanish

#### Scenario: Plural count
- **WHEN** the interface is in Spanish and a CSV import adds one record, and later another import adds 3 records
- **THEN** the snackbars read the Spanish singular and plural forms respectively

#### Scenario: User data untouched
- **WHEN** the interface is in Spanish and a collection is named "Expenses"
- **THEN** the collection still reads "Expenses"

### Requirement: Rust-originated errors are shown in the active language
When a failure reported by Rust carries a typed kind or code, the app SHALL show text for that kind or code in the active language, not the English message Rust attached. This SHALL apply to: bridge error kinds other than validation; validation issues with the codes required, type_mismatch, length, out_of_range, inactive_option and field_unavailable; networking-deferred reasons (locked keyring, unavailable secure store, exhausted port range, which names the UDP range); widget evaluation error kinds; pairing failure kinds; voice error kinds; and voice model error kinds. A length or out_of_range issue SHALL state the field's bounds when the form knows the field. The Rust message SHALL be shown as given only for an `invalid` validation issue, for the reason of a stopped import, and inside technical details such as logs.

#### Scenario: Required field in Spanish
- **WHEN** the interface is in Spanish and saving a record fails with a required issue on one field
- **THEN** the message under that field is the Spanish "required" text

#### Scenario: Out of range with bounds
- **WHEN** the interface is in Spanish and saving fails with an out_of_range issue on an integer field with bounds 1 and 10
- **THEN** the message under that field is Spanish and names 1 and 10

#### Scenario: Ports exhausted in Spanish
- **WHEN** the interface is in Spanish and networking is deferred because UDP ports 47380–47389 are in use
- **THEN** the networking banner explains the condition in Spanish, names the range 47380–47389, and offers the retry action

### Requirement: Locale-aware formatting
Human-readable dates, times, relative status times ("just now", "5 min ago"), month and weekday names, byte sizes, percentages, counts and fixed-decimal values SHALL be formatted for the active language. Spanish SHALL use a comma as the decimal separator ("1,43 GB", "12,50") and Spanish month abbreviations ("28 sept"). No grouping separators SHALL be added to fixed-decimal values. A fixed-decimal input SHALL accept the active language's decimal separator, and in Spanish SHALL also accept a period as the decimal separator. Machine-oriented forms SHALL stay the same in every language: sortable editor dates (`2026-09-24`, `2026-09-24 14:05`), duration text, formulas, ids, addresses and ports.

#### Scenario: Byte size in Spanish
- **WHEN** the interface is in Spanish and the voice models total 1,433,458,515 bytes
- **THEN** the total reads "1,43 GB"

#### Scenario: Decimal input in Spanish
- **WHEN** the interface is in Spanish and the user types "12,50" into a fixed-decimal field with scale 2
- **THEN** the stored value is 12.50 and the field shows "12,50"

#### Scenario: Record date in Spanish
- **WHEN** the interface is in Spanish and a record was created on 2026-09-22
- **THEN** its human-readable date uses the Spanish month abbreviation

### Requirement: Spanish copy fits the layout
Buttons, navigation tabs, sidebar rows, tags and sheet or dialog headers SHALL never be truncated or clipped in either language at 360px width and wider. Where the Spanish copy is longer, the control SHALL wrap its text or the row SHALL stack its controls. Long free text (descriptions, help, guidance lines) SHALL wrap. The key screens (Collections list, Devices, Settings, the voice models card, the New record sheet and the pairing card) SHALL render in Spanish without layout overflow at 360px and 1240px widths.

#### Scenario: Spanish Settings on a narrow phone
- **WHEN** the interface is in Spanish on a 360px-wide screen with the voice models card showing "Volver a descargar" and "Eliminar"
- **THEN** both buttons show their full text and no overflow is reported

#### Scenario: Spanish Devices on desktop
- **WHEN** the interface is in Spanish on a 1240px-wide screen
- **THEN** the sidebar rows "Colecciones", "Dispositivos" and "Ajustes" show their full text and no overflow is reported

### Requirement: Translation completeness is checked
The English and Spanish copy SHALL hold exactly the same set of message keys, and each message SHALL declare the same placeholders in both languages. No Spanish message SHALL be empty. A test SHALL fail, naming the key, when a key is missing in either language, when placeholders differ, or when a Spanish message is empty.

#### Scenario: Missing Spanish key
- **WHEN** a developer adds a key to the English copy only
- **THEN** the completeness test fails and names the key

#### Scenario: Placeholder mismatch
- **WHEN** the English message declares `{size}` and the Spanish one declares `{tamano}`
- **THEN** the completeness test fails and names the key
