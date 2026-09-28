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

### Requirement: On-device transcription
The engine SHALL transcribe a turn's audio with the provisioned English Whisper model on the device, with no network use. It SHALL trim leading and trailing silence and return the text with Whisper's non-speech tokens removed. A turn whose audio holds no speech (energy below the silence threshold for the whole turn) or whose transcript is empty after cleaning SHALL fail with `noSpeech`. The Whisper model SHALL be loaded for the transcription and released afterwards.

#### Scenario: Transcribe a short turn
- **WHEN** the user says “Lunch at Nando's, twelve fifty, food, yesterday”
- **THEN** the transcript contains those words in order, apart from casing and punctuation

#### Scenario: Silence
- **WHEN** the turn holds only silence
- **THEN** the turn fails with `noSpeech` and no fill runs

### Requirement: Schema-constrained filling
The engine SHALL build, for each collection schema, a grammar that only allows a JSON array of patch entries. Each entry SHALL hold:
- `field`: one of the collection's active, non-computed field names;
- `value`: a string span, `true`, `false` or `null`;
- `evidence`: a string.

No field SHALL appear twice, and there SHALL be at most one entry per field. For each Choice field the value SHALL be constrained to its active option labels or `null`. The grammar SHALL be compiled once per schema version and reused.

The prompt SHALL list the fields compactly with type, required flag, options and the values already in the draft, SHALL include today's local date and weekday, and SHALL instruct the model to use `null` for anything not said and to copy evidence words from the transcript. Generation SHALL use greedy sampling, the model's thinking or reasoning mode SHALL be off, and output SHALL be capped at 256 tokens.

#### Scenario: Output always parses
- **WHEN** the engine fills any transcript against a schema with Text, Decimal, Choice and Date fields
- **THEN** the model output parses as the patch array, and every field name and Choice label in it belongs to the schema

#### Scenario: Grammar reused
- **WHEN** two turns fill the same collection without a schema change between them
- **THEN** the grammar is compiled once

### Requirement: Deterministic value normalization
The engine SHALL convert each entry's value span into the field's typed value with deterministic rules, not with the model:

- **Integer** and **Decimal**: digits or English number words (“twelve fifty” → 12.50, “twenty two forty” → 22.40, “three” → 3). Decimals round half-even to the field scale; integers must be whole.
- **Boolean**: yes/no/true/false/on/off.
- **Choice**: case-insensitive exact label, then the closest label within an edit distance of 2 and 30% of the label length. An ambiguous match is dropped.
- **Date**, relative to the device's local date:
  - today, tomorrow and yesterday;
  - weekday names (the most recent past occurrence, or today);
  - “last <weekday>” and “next <weekday>”;
  - “<month> <day>” and “<day> <month>”, with an optional year, taking the nearest past date when the year is missing;
  - ISO dates.
- **Date & time**: a date phrase plus an optional time (“3pm”, “15:30”, “at noon”), in local time; “now” is the current minute.
- **Duration**: the core duration grammar, plus spoken forms (“45 minutes”, “an hour and a half”, “ninety seconds”).
- **Text**: the span as spoken, trimmed. It is dropped when longer than the field's maximum length.

An entry whose span cannot be converted SHALL be dropped, not guessed. A `null` value SHALL mean "not said" and produce no entry.

#### Scenario: Spoken amount
- **WHEN** an entry for a Decimal field with scale 2 has the span “twelve fifty”
- **THEN** the typed value is 12.50

#### Scenario: Relative date
- **WHEN** the local date is Monday 2026-09-28 and an entry for a Date field has the span “yesterday”
- **THEN** the typed value is 2026-09-27

#### Scenario: Last weekday
- **WHEN** the local date is Monday 2026-09-28 and the span is “last Tuesday”
- **THEN** the typed value is 2026-09-22

#### Scenario: Fuzzy choice
- **WHEN** a Choice field has options food, transport, home, other and the span is “Food”
- **THEN** the value is the option food

#### Scenario: Unconvertible span dropped
- **WHEN** an entry for a Decimal field has the span “a lot”
- **THEN** no entry for that field is returned

### Requirement: Evidence check and returned patch
The engine SHALL keep an entry only when its evidence, after normalizing case, whitespace and punctuation, occurs in the transcript, and the value span occurs within or equals the evidence. The returned patch SHALL hold field ids, typed values and evidence. It SHALL contain nothing for fields the model left `null`. When no entry survives, the turn SHALL fail with `nothingMatched`.

#### Scenario: Invented value removed
- **WHEN** the transcript is “Taxi home yesterday” and the model proposes amount “20” with evidence “twenty”
- **THEN** the amount entry is removed because “twenty” is not in the transcript

#### Scenario: Nothing survives
- **WHEN** every proposed entry fails the evidence check
- **THEN** the turn fails with `nothingMatched`

### Requirement: Model lifecycle and failures
The engine SHALL load the instruction model when a New record sheet opens with the models ready, without blocking the sheet, and SHALL keep it loaded while the app is in the foreground. It SHALL release the model after 5 minutes in the background or when Android reports memory pressure. A turn that needs the model while it is loading SHALL wait for the load. A missing or unreadable model file SHALL fail the turn with `modelLoadFailed`. An allocation failure while loading or running SHALL fail with `lowMemory` and release the partial state. Cancel SHALL stop transcription or generation at the next opportunity and return within one second. Model files, audio and transcripts SHALL never be sent over the network or written to logs.

#### Scenario: Warm on sheet open
- **WHEN** the models are ready and the user opens New record
- **THEN** the instruction model starts loading in the background, and the sheet stays usable

#### Scenario: Released in the background
- **WHEN** the app stays in the background for 5 minutes
- **THEN** the instruction model is released

#### Scenario: Damaged model
- **WHEN** the instruction model file cannot be loaded
- **THEN** the turn fails with `modelLoadFailed`

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
The repository SHALL contain an opt-in evaluation that runs the engine's filling and normalization on a fixed set of at least 60 English utterances against at least three sample schemas, using the provisioned models on a desktop build with the native feature enabled. For each run it SHALL report:
- field-level accuracy;
- the rate of invented fields (entries for fields the utterance does not mention);
- the evidence-rejection rate;
- the median fill latency.

It SHALL not run in the default test suite. The acceptance bar SHALL be at least 85% field-level accuracy and at most 5% invented fields after the evidence check.

#### Scenario: Evaluation report
- **WHEN** the evaluation is run with the models present
- **THEN** it prints accuracy, invented-field rate, evidence-rejection rate and median latency, and exits non-zero when the acceptance bar is not met
