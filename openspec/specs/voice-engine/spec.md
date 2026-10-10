# voice-engine Specification

## Purpose

Turns one spoken English turn into a transcript and a patch of typed field values, entirely on the device, using the provisioned Whisper and instruction models. The model is constrained by each collection's schema, and values are normalized by deterministic code.

## Requirements

### Requirement: Push-to-talk audio capture
On Android, the engine SHALL capture microphone audio only between the start and the stop of a turn, as 16 kHz mono 16-bit PCM held in memory. While capturing, it SHALL report the input level (0–1, RMS-based) at least ten times per second. A turn SHALL stop capturing automatically after 30 seconds and continue as if the user had stopped. The engine SHALL report `micBusy` when the microphone cannot be opened, and `permissionDenied` when access is not granted. It SHALL report `interruptedCall` when audio focus is lost for a call during the turn, and `interruptedBackground` when the app leaves the foreground. In every case the captured audio SHALL be discarded.

#### Scenario: Levels while speaking
- **WHEN** the user speaks during a turn
- **THEN** the engine reports levels at least ten times per second, rising above the silence level

#### Scenario: Thirty-second cap
- **WHEN** the user keeps talking for 35 seconds
- **THEN** capture stops at 30 seconds and the turn proceeds to transcription with the first 30 seconds

#### Scenario: Call during a turn
- **WHEN** a phone call takes audio focus while the engine is listening
- **THEN** capture stops, the audio is discarded, and the turn fails with `interruptedCall`

### Requirement: Voice language of a turn
Every turn SHALL carry a voice language, English (`en`) or Spanish (`es`). The voice language SHALL select the speech model and the language Whisper transcribes, the normalization rules, and the language line of the prompt. A turn whose language code is neither `en` nor `es` SHALL be handled as English. The instruction model and the grammar SHALL be the same for both languages.

#### Scenario: Spanish turn
- **WHEN** a turn with voice language `es` is filled
- **THEN** it is transcribed with the Spanish speech model in Spanish and its spans are normalized with the Spanish rules

#### Scenario: Unknown language code
- **WHEN** a turn arrives with language code `fr`
- **THEN** it is transcribed and normalized as English

### Requirement: On-device transcription
The engine SHALL transcribe a turn's audio on the device, with no network use, using the provisioned speech model of the turn's voice language: `ggml-base.en.bin` for English and the multilingual `ggml-base.bin` for Spanish. Whisper SHALL be told the turn's language (`en` or `es`) rather than detecting it. The engine SHALL find the file name of the speech model from the model manifest by role and language, not from a fixed name. It SHALL trim leading and trailing silence and return the text with Whisper's non-speech tokens removed. A turn whose audio holds no speech (energy below the silence threshold for the whole turn) or whose transcript is empty after cleaning SHALL fail with `noSpeech`. A missing speech model for the turn's language SHALL fail the turn with `modelLoadFailed`. The Whisper model SHALL be loaded for the transcription and released afterwards.

#### Scenario: Transcribe a short turn
- **WHEN** the user says “Lunch at Nando's, twelve fifty, food, yesterday” in an English turn
- **THEN** the transcript contains those words in order, apart from casing and punctuation

#### Scenario: Spanish transcription
- **WHEN** a Spanish turn is transcribed
- **THEN** the engine loads `ggml-base.bin` and runs Whisper with the language `es`

#### Scenario: Speech model of the language missing
- **WHEN** a Spanish turn runs and `ggml-base.bin` is not on the device
- **THEN** the turn fails with `modelLoadFailed`

#### Scenario: Silence
- **WHEN** the turn holds only silence
- **THEN** the turn fails with `noSpeech` and no fill runs

### Requirement: Schema-constrained filling
The engine SHALL build, for each collection schema, a grammar that only allows a JSON array of patch entries. Each entry SHALL hold:
- `field`: one of the collection's active, non-computed field names;
- `value`: a string span, `true`, `false`, `null`, or, for a Choices field only, an array of one or more string spans;
- `evidence`: a string.

No field SHALL appear twice, and there SHALL be at most one entry per field. For each Choice field the value SHALL be constrained to its active option labels or `null`. For each Choices field the value SHALL be constrained to an array of distinct active option labels of that field, or `null`. The grammar SHALL be compiled once per schema version and reused, whatever the turn's language.

The prompt SHALL list the fields compactly with type, required flag, options and the values already in the draft, SHALL include today's local date and weekday, and SHALL instruct the model to use `null` for anything not said and to copy evidence words from the transcript. For a Spanish turn the prompt SHALL also state that the transcript is in Spanish and that values and evidence must be copied in Spanish exactly as spoken, without translating. Generation SHALL use greedy sampling, the model's thinking or reasoning mode SHALL be off, and output SHALL be capped at 256 tokens.

#### Scenario: Output always parses
- **WHEN** the engine fills any transcript against a schema with Text, Decimal, Choice and Date fields
- **THEN** the model output parses as the patch array, and every field name and Choice label in it belongs to the schema

#### Scenario: Grammar reused
- **WHEN** two turns fill the same collection without a schema change between them
- **THEN** the grammar is compiled once

#### Scenario: Spanish prompt
- **WHEN** a Spanish turn is filled
- **THEN** the prompt states that the transcript is Spanish and asks for values and evidence copied without translation, and an English turn's prompt has no such line

#### Scenario: Choices labels constrained
- **WHEN** the engine fills “tags work and urgent” against a schema with a Choices field "tags" holding "work", "urgent" and "food"
- **THEN** the output entry for "tags" is an array of labels of that field only, and the patch value is the set {"work", "urgent"}

### Requirement: Deterministic value normalization
The engine SHALL convert each entry's value span into the field's typed value with deterministic rules of the turn's language, not with the model.

English rules:
- **Integer** and **Decimal**: digits or English number words (“twelve fifty” → 12.50, “twenty two forty” → 22.40, “three” → 3). Decimals round half-even to the field scale; integers must be whole.
- **Boolean**: yes/no/true/false/on/off.
- **Date**, relative to the device's local date:
  - today, tomorrow and yesterday;
  - weekday names (the most recent past occurrence, or today);
  - “last <weekday>” and “next <weekday>”;
  - “<month> <day>” and “<day> <month>”, with an optional year, taking the nearest past date when the year is missing;
  - ISO dates.
- **Date & time**: a date phrase plus an optional time (“3pm”, “15:30”, “at noon”), in local time; “now” is the current minute.
- **Duration**: the core duration grammar, plus spoken forms (“45 minutes”, “an hour and a half”, “ninety seconds”).

Spanish rules (accents are optional in every word, so “miercoles” reads as “miércoles”):
- **Integer** and **Decimal**: digits or Spanish number words, including “y” between tens and units (“treinta y dos” → 32), the one-word forms 16–29 (“dieciséis”, “veintidós”), hundreds (“cien”, “ciento”, “doscientos” … “novecientos”), “mil” and “millón”/“millones” (“mil doscientos” → 1200, “dos mil trescientos cuarenta” → 2340). Two whole amounts joined by “con” or said one after the other are a money pair for a scale-2 field (“doce con cincuenta” → 12.50, “doce cincuenta” → 12.50, “doce euros con cincuenta” → 12.50). “coma” or “punto” starts the decimal part, read as a number (“doce coma cinco” → 12.5, “doce coma cincuenta” → 12.50). In digits a comma is the decimal separator (“12,50” → 12.50), a period followed by exactly three digits groups thousands (“1.200” → 1200), and another period is a decimal point (“12.50” → 12.50). “menos” makes the amount negative. Currency words (euros, pesos, dólares, céntimos, centavos) and one trailing measure word (kilómetros, km, kilos, páginas, …) are ignored. Decimals round half-even to the field scale; integers must be whole.
- **Boolean**: sí/si/verdadero/activado/encendido for true, no/falso/desactivado/apagado for false.
- **Date**, relative to the device's local date:
  - hoy, mañana, ayer, anteayer (also “antes de ayer”) and “pasado mañana”;
  - weekday names with or without “el” (the most recent past occurrence, or today);
  - “el <weekday> pasado” or “el pasado <weekday>”, meaning the same as English “last <weekday>”, and “el próximo <weekday>” or “el <weekday> que viene”, meaning the same as “next <weekday>”;
  - “<day> de <month>”, with an optional leading “el” and an optional “de <year>”, the day in digits or words (“12 de marzo”, “doce de marzo”, “primero de marzo”), taking the nearest past date when the year is missing;
  - ISO dates.
- **Date & time**: a date phrase plus an optional time introduced by “a las”/“a la” (“a las tres”, “a las 15:30”, “a las tres y media”, “a las nueve y cuarto”, “a las ocho menos cuarto”), “al mediodía” or “a medianoche”, with an optional “de la mañana”/“de la madrugada” (before noon) or “de la tarde”/“de la noche” (after noon), in local time; “ahora” and “ahora mismo” are the current minute.
- **Duration**: the core duration grammar, plus spoken forms with horas, minutos and segundos (“45 minutos”, “una hora y media”, “media hora”, “una hora y cuarto”, “noventa segundos”, “dos horas y quince minutos”).

Rules for both languages:
- **Choice**: case-insensitive exact label, then the closest label within an edit distance of 2 and 30% of the label length. Accents are ignored when comparing. An ambiguous match is dropped.
- **Text**: the span as spoken, trimmed. It is dropped when longer than the field's maximum length.

A turn SHALL use only its own language's words: an English word in a Spanish turn, or a Spanish word in an English turn, does not convert. An entry whose span cannot be converted SHALL be dropped, not guessed. A `null` value SHALL mean "not said" and produce no entry.

#### Scenario: Spoken amount
- **WHEN** an entry for a Decimal field with scale 2 has the span “twelve fifty” in an English turn
- **THEN** the typed value is 12.50

#### Scenario: Spanish money pair
- **WHEN** an entry for a Decimal field with scale 2 has the span “doce con cincuenta” in a Spanish turn
- **THEN** the typed value is 12.50

#### Scenario: Spanish thousands
- **WHEN** an entry for an Integer field has the span “mil doscientos” in a Spanish turn
- **THEN** the typed value is 1200

#### Scenario: Spanish decimal comma
- **WHEN** an entry for a Decimal field with scale 2 has the span “12,50” or “doce coma cincuenta” in a Spanish turn
- **THEN** the typed value is 12.50

#### Scenario: Relative date
- **WHEN** the local date is Monday 2026-09-28 and an entry for a Date field has the span “yesterday” in an English turn
- **THEN** the typed value is 2026-09-27

#### Scenario: Last weekday
- **WHEN** the local date is Monday 2026-09-28 and the span is “last Tuesday” in an English turn
- **THEN** the typed value is 2026-09-22

#### Scenario: Spanish relative dates
- **WHEN** the local date is Monday 2026-09-28 and a Spanish turn has the Date spans “ayer”, “mañana”, “el martes pasado” and “12 de marzo”
- **THEN** the typed values are 2026-09-27, 2026-09-29, 2026-09-22 and 2026-03-12

#### Scenario: Spanish date and time
- **WHEN** the local date is Monday 2026-09-28 and a Spanish turn has the Date & time span “ayer a las tres de la tarde”
- **THEN** the typed value is 2026-09-27 15:00 local time

#### Scenario: Spanish duration
- **WHEN** a Spanish turn has the Duration span “una hora y media”
- **THEN** the typed value is 1 hour 30 minutes

#### Scenario: Spanish boolean
- **WHEN** a Spanish turn has the Boolean spans “sí” and “no”
- **THEN** the typed values are true and false

#### Scenario: Other language's words do not convert
- **WHEN** a Spanish turn has the Date span “yesterday”
- **THEN** no entry for that field is returned

#### Scenario: Fuzzy choice
- **WHEN** a Choice field has options food, transport, home, other and the span is “Food”
- **THEN** the value is the option food

#### Scenario: Choice ignores accents
- **WHEN** a Choice field has the option “Café” and a Spanish turn has the span “cafe”
- **THEN** the value is the option Café

#### Scenario: Unconvertible span dropped
- **WHEN** an entry for a Decimal field has the span “a lot” in an English turn or “mucho” in a Spanish turn
- **THEN** no entry for that field is returned

### Requirement: Evidence check and returned patch
The engine SHALL keep an entry only when its evidence, after normalizing case, whitespace, punctuation (including “¿” and “¡”) and accents, occurs in the transcript, and the value span occurs within or equals the evidence. The returned patch SHALL hold field ids, typed values and evidence. It SHALL contain nothing for fields the model left `null`. When no entry survives, the turn SHALL fail with `nothingMatched`.

#### Scenario: Invented value removed
- **WHEN** the transcript is “Taxi home yesterday” and the model proposes amount “20” with evidence “twenty”
- **THEN** the amount entry is removed because “twenty” is not in the transcript

#### Scenario: Accents ignored in evidence
- **WHEN** the transcript is “Café con Ana, ¿cuánto? doce euros” and the model gives evidence “cafe con ana”
- **THEN** the evidence counts as found in the transcript

#### Scenario: Nothing survives
- **WHEN** every proposed entry fails the evidence check
- **THEN** the turn fails with `nothingMatched`

### Requirement: Dictation turn with delete-only cleanup
The engine SHALL offer a dictation turn alongside the fill turn. A dictation turn SHALL capture and transcribe audio exactly as a fill turn does (same capture, cap, voice language, speech model and failures), report the transcript as soon as it exists, and then return a cleaned text. Cleanup SHALL run the instruction model with a prompt that asks it to remove self-corrections, retracted words and filler (for example "no wait", "I mean", "scratch that", "nevermind", "um", and in Spanish "digo", "perdón", "mejor dicho", "este") and to keep every other word unchanged and in order. Generation SHALL use greedy sampling with thinking off, and output SHALL be capped at 256 tokens.

The engine SHALL accept the cleaned text only when its words, compared after normalizing case and accents and ignoring punctuation, are a subsequence of the transcript's words and at least one word remains. Otherwise the cleaned text SHALL equal the transcript. The engine SHALL also return the indexes of the transcript words the cleanup removed, so the app can strike them through. A dictation turn SHALL NOT fail with `nothingMatched`. When the cleanup itself fails with `lowMemory` or `modelLoadFailed`, the turn SHALL fail with that error.

After the transcript is reported, the app SHALL be able to skip the cleanup of a dictation turn. Skipping SHALL stop generation at the next opportunity and return within one second. The turn SHALL then succeed with the cleaned text equal to the transcript and no removed indexes. Skipping SHALL NOT fail the turn, SHALL NOT discard the transcript, and SHALL have no effect once the turn has returned its result or failed, or before the transcript exists.

#### Scenario: Self-correction removed
- **WHEN** an English dictation turn's transcript is “Lunch at Nando's, scratch that, lunch at Wagamama with Sam”
- **THEN** the cleaned text is “Lunch at Wagamama with Sam” and the removed indexes cover “Lunch at Nando's, scratch that,”

#### Scenario: Invented word rejected
- **WHEN** the model returns “Lunch at the Wagamama” for the transcript “Lunch at Wagamama”
- **THEN** “the” is not in the transcript, and the cleaned text equals the transcript

#### Scenario: Nothing to clean
- **WHEN** the transcript is “Team lunch at Wagamama” and the model returns it unchanged
- **THEN** the cleaned text equals the transcript and no index is removed

#### Scenario: Spanish cleanup
- **WHEN** a Spanish dictation turn's transcript is “Comprar leche de avena, digo, leche de almendra”
- **THEN** the cleaned text is “Comprar leche de almendra”

#### Scenario: Cleanup skipped
- **WHEN** a dictation turn has reported the transcript “Pick up oat milk, no wait, almond milk” and the app skips the cleanup while the model is generating
- **THEN** the turn returns within one second with the cleaned text “Pick up oat milk, no wait, almond milk” and no removed indexes

#### Scenario: Skip after the result
- **WHEN** the app skips the cleanup of a dictation turn that has already returned its cleaned text
- **THEN** the returned result is unchanged

### Requirement: Model lifecycle and failures
The engine SHALL load the instruction model, without blocking the form, when a New record sheet opens with whole-form voice fill offered or a record form opens that offers field dictation, in both cases with the models ready. It SHALL keep the model loaded while the app is in the foreground. It SHALL release the model after 5 minutes in the background or when Android reports memory pressure. A turn that needs the model while it is loading SHALL wait for the load. A missing or unreadable model file SHALL fail the turn with `modelLoadFailed`. An allocation failure while loading or running SHALL fail with `lowMemory` and release the partial state. Cancel SHALL stop transcription or generation at the next opportunity and return within one second. Cancelling or skipping SHALL apply only to the turn it was issued for: starting a new turn SHALL NOT clear it, so an earlier turn's transcription or generation still stops at its next opportunity, and SHALL NOT stop the new turn. Model files, audio and transcripts SHALL never be sent over the network or written to logs.

#### Scenario: Warm on sheet open
- **WHEN** the models are ready and the user opens New record
- **THEN** the instruction model starts loading in the background, and the sheet stays usable

#### Scenario: Warm on Edit record with dictation
- **WHEN** the models are ready and the user opens Edit record on Android for a collection with a Text field
- **THEN** the instruction model starts loading in the background, and the form stays usable

#### Scenario: Released in the background
- **WHEN** the app stays in the background for 5 minutes
- **THEN** the instruction model is released

#### Scenario: Damaged model
- **WHEN** the instruction model file cannot be loaded
- **THEN** the turn fails with `modelLoadFailed`

#### Scenario: New turn right after a skip
- **WHEN** the app skips a dictation turn's cleanup and immediately starts a new dictation turn
- **THEN** the earlier generation stops within one second, and the new turn is neither cancelled nor kept waiting for the earlier cleanup to finish

### Requirement: Performance targets on the target device
On the target device class (Dimensity 8300-Ultra, 8 GB RAM, arm64), measured on a release build with a warm instruction model and a schema of up to 12 fields:
- Transcribing a 5-second turn SHALL take at most 2 seconds at the median.
- Filling SHALL take at most 6 seconds at the median.
- A full turn from stop to patch SHALL take at most 8 seconds at the 90th percentile.
- Peak resident memory of the app during a turn SHALL stay at or below 3.5 GB.

These targets are accepted by a recorded on-device measurement, not by automated tests.

#### Scenario: Measured on the phone
- **WHEN** the benchmark run of 20 turns is executed on the target device
- **THEN** the recorded medians, 90th percentile and peak memory meet the targets, or the shortfall is recorded with the chosen mitigation

### Requirement: Evaluation harness
The repository SHALL contain an opt-in evaluation that runs the engine's filling and normalization on a fixed set of at least 60 English utterances and a fixed set of at least 30 Spanish utterances, each against at least three sample schemas, using the provisioned models on a desktop build with the native feature enabled. A run SHALL evaluate one language, chosen when it is started, and English by default. For each run it SHALL report:
- field-level accuracy;
- the rate of invented fields (entries for fields the utterance does not mention);
- the evidence-rejection rate;
- the median fill latency.

It SHALL not run in the default test suite. The acceptance bar SHALL be at least 85% field-level accuracy and at most 5% invented fields after the evidence check, for each language.

#### Scenario: Evaluation report
- **WHEN** the evaluation is run with the models present
- **THEN** it prints accuracy, invented-field rate, evidence-rejection rate and median latency, and exits non-zero when the acceptance bar is not met

#### Scenario: Spanish evaluation
- **WHEN** the evaluation is run for Spanish
- **THEN** it fills the Spanish utterance set as Spanish turns and reports the same figures against the same bar

### Requirement: Choices values in the patch
For a Choices field, the engine SHALL map each label of the array to its option id, drop duplicates, and return the set as the entry's typed value. The evidence check SHALL apply to the whole entry: the evidence must occur in the transcript and every label span must occur within the evidence, after the same normalization as other entries. A Choices entry SHALL replace the field's set when applied, following the same overwrite rules as any other entry.

#### Scenario: Labels not in the evidence
- **WHEN** the transcript is “tags work” and the model returns ["work", "urgent"] with evidence “tags work”
- **THEN** the entry is removed because “urgent” is not within the evidence

#### Scenario: Spanish Choices
- **WHEN** a Spanish turn says “etiquetas trabajo y urgente” for a Choices field with options "trabajo" and "urgente"
- **THEN** the patch sets that field to {"trabajo", "urgente"}
