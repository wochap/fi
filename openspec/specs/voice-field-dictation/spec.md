# voice-field-dictation Specification

## Purpose

Lets the user dictate into a single Text field of a record form on Android, cleans self-corrections and filler from the transcript on the device, and lets the user review and apply the cleaned or as-heard text before saving.

## Requirements

### Requirement: Dictation mic availability
Field dictation SHALL be offered on Text and multiline Text inputs in the New record and Edit record forms. It SHALL be offered only on Android and only when a voice engine is available to the build (the native engine, or the fake engine in debug builds or with `FI_VOICE_FAKE=true`), at any screen width. It MUST NOT be offered on any other field type, on computed fields, or outside the record forms. When offered, the mic SHALL sit in the input's trailing slot, labelled "Dictate into <field name>", with a touch target of at least 44px. When the field is optional and holds text, the clear mark ✕ SHALL sit before the mic. A required field SHALL show only the mic. In a multiline input the trailing slot SHALL stay pinned to the top.

#### Scenario: Mic on a text field in Edit record
- **WHEN** a voice engine is available on Android and the user opens Edit record for a record with a multiline notes field
- **THEN** the notes input shows the mic in its trailing slot

#### Scenario: Clear mark before the mic
- **WHEN** the optional description field holds "Groceries"
- **THEN** its trailing slot shows ✕ followed by the mic

#### Scenario: Required field
- **WHEN** the required title field holds "Buy oat milk"
- **THEN** its trailing slot shows only the mic

#### Scenario: No mic on other types
- **WHEN** the form shows a Decimal amount field and a Date field
- **THEN** neither shows a dictation mic

#### Scenario: No mic without an engine or off Android
- **WHEN** no voice engine is available, or the app runs on Linux desktop
- **THEN** no Text input shows a dictation mic

### Requirement: Dictation states in the field
Tapping the mic SHALL start a dictation turn for that field. While listening, the field SHALL show live level bars, "Listening…" with an elapsed timer (m:ss), and a stop square in place of the mic, labelled "Stop listening". Tapping the stop square SHALL stop listening and start processing. While processing, the field SHALL show "Cleaning up…" with a small progress ring and be busy for screen readers. The turn SHALL stop listening on its own after 30 seconds and continue as if stopped. Every other field SHALL stay editable in every state. The field being dictated into SHALL keep its current text until the user applies the result. State changes SHALL be announced to screen readers, and no state SHALL be shown by color alone.

#### Scenario: Listen then process
- **WHEN** the user taps the description mic, speaks, and taps the stop square
- **THEN** the field shows "Listening… 0:04" with level bars, then "Cleaning up…" with a ring

#### Scenario: Other fields stay usable
- **WHEN** the description field is listening
- **THEN** the user can type into the amount field

### Requirement: Dictated review sheet
After processing, the app SHALL show the "Dictated" sheet, titled "Dictated" with the subtitle "into <field name>", unless the sheet is skipped (see below). The sheet SHALL show:
- Two selectable versions: "Cleaned", tagged "Default" and selected first, and "As heard". In the "As heard" version, the words the cleanup removed SHALL be struck through.
- When the two versions are identical, only one version, with the line "Nothing to clean up.".
- When the field holds text, the line "In the field now: “<current text>”" and the actions [Append] and [Replace], with Replace primary.
- When the field is empty, the line "The field is empty." and the action [Insert].

Insert and Replace SHALL set the field to the selected version. Append SHALL add the selected version to the end of the current text, separated by one space, or by nothing when the current text already ends in whitespace. Dismissing the sheet SHALL discard the result and leave the field unchanged. When the field is empty and the cleaned version equals the raw transcript, the app SHALL skip the sheet and insert the text directly. A multiline field SHALL keep line breaks already in it. Text that would exceed the field's maximum length SHALL be applied and then reported by the form's normal validation.

#### Scenario: Field has text
- **WHEN** notes holds "Buy oat milk" and the user says “Pick up oat milk, no wait, almond milk, and eggs, I mean a dozen eggs”
- **THEN** the sheet shows Cleaned "Pick up almond milk and a dozen eggs" (selected), As heard with the removed words struck through, "In the field now: “Buy oat milk”", Append and Replace

#### Scenario: Append
- **WHEN** notes holds "Buy oat milk" and the user picks Cleaned and taps Append
- **THEN** notes reads "Buy oat milk Pick up almond milk and a dozen eggs"

#### Scenario: Replace with the raw version
- **WHEN** the user picks As heard and taps Replace
- **THEN** the field holds the raw transcript exactly

#### Scenario: Field empty
- **WHEN** description is empty and the user says “Lunch at Nando's, scratch that, lunch at Wagamama with Sam”
- **THEN** the sheet shows "The field is empty." and Insert, and Insert sets description to the cleaned text

#### Scenario: Identical versions
- **WHEN** description holds "Lunch" and the transcript needs no cleanup
- **THEN** the sheet shows one version, "Nothing to clean up.", Append and Replace

#### Scenario: Sheet skipped
- **WHEN** description is empty and the user says “Team lunch at Wagamama”, which needs no cleanup
- **THEN** no sheet appears, description holds "Team lunch at Wagamama", and no record is saved

#### Scenario: Dismiss discards
- **WHEN** the user dismisses the Dictated sheet
- **THEN** the field keeps its previous text

### Requirement: Dictated text is typed text
Text applied from dictation SHALL count as typed by the user. It SHALL NOT show the Voice marker or evidence popover, and whole-form voice fill SHALL NOT overwrite it afterwards. The record SHALL be saved only by Save record. Applying dictation SHALL count as a change for the form's discard confirmation.

#### Scenario: No Voice marker
- **WHEN** dictated text is inserted into description in New record
- **THEN** description shows no Voice chip, and a later whole-form voice turn that proposes a description keeps the dictated text

### Requirement: Dictation errors and setup
Dictation failures SHALL appear as one line under the field with a Retry action, and the field SHALL keep its text:

| Failure | Line |
|---|---|
| No speech | "Didn't hear anything" |
| Microphone busy | "Microphone is busy" |
| Model failed to load, low memory, interrupted by background or call | the matching title from voice-record-fill's error table |

Retry SHALL start a new dictation turn for the field. Cancel (from the discard confirmation, or the form closing) SHALL discard the turn silently. When the microphone permission was never granted, tapping the mic SHALL show the existing microphone primer. When it is permanently denied, tapping the mic SHALL show the existing "Microphone access is off" panel with "Open settings". When the voice language's model set is not ready, tapping the mic SHALL open the existing voice model download offer for the full set. A download in progress SHALL show on the mic as the existing progress ring.

#### Scenario: Nothing heard
- **WHEN** a dictation turn into description holds only silence
- **THEN** "Didn't hear anything" with Retry appears under description, and description keeps "Groceries"

#### Scenario: Models missing
- **WHEN** the English set is not downloaded and the user taps a field mic
- **THEN** the voice model download offer appears

### Requirement: One voice turn at a time
At most one voice turn, whole-form fill or dictation, SHALL run at a time. While a turn runs, every other dictation mic and the whole-form mic SHALL be disabled. Closing the form while a dictation turn is listening or processing SHALL ask the existing "Discard this record?" confirmation (in Edit record, the form's existing discard confirmation). Discard SHALL cancel the turn.

#### Scenario: Second mic disabled
- **WHEN** description is listening
- **THEN** the notes mic and the footer mic are disabled

### Requirement: Dictation privacy and language
Dictation SHALL use the voice language (the app's resolved interface language) and the same on-device models as voice fill. Audio SHALL be held only in memory for the turn, and audio and transcripts MUST NOT be written to disk, logs, diagnostics or synced data. A dictation's transcript SHALL be discarded once the result is applied, dismissed or failed. In Spanish the copy SHALL read "Escuchando…", "Limpiando…", "Dictado", "en <field name>", "Limpio", "Predeterminado", "Tal cual", "Ahora en el campo: «<text>»", "Añadir", "Reemplazar" and "Insertar", and quotes SHALL use «».

#### Scenario: Spanish review
- **WHEN** the interface is Spanish and notes holds "Comprar pan"
- **THEN** the sheet reads "Dictado", "en notas", "Limpio", "Tal cual", "Ahora en el campo: «Comprar pan»", "Añadir" and "Reemplazar"

#### Scenario: Nothing kept
- **WHEN** a dictation result is applied and the form is closed
- **THEN** no audio or transcript exists in app storage, logs or diagnostics
