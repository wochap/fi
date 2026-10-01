# voice-record-fill Specification

## Purpose

Lets a phone user fill the New record form by speaking. The user reviews the filled form before saving, speech is processed only on the device, and fields the user typed are never overwritten.

## Requirements

### Requirement: Voice fill availability and entry
Voice fill SHALL be offered only in the New record sheet on screens narrower than 720px, and only when a voice engine is available to the build. It MUST NOT appear in Edit record, in the desktop dialog, or anywhere else. When offered, the sheet footer SHALL hold a 56px round mic button at its leading edge and "Save record" filling the rest of the row. The first time the sheet opens with voice fill offered, a tip SHALL appear at the top of the sheet: a sparkle icon, "Fill by voice", "Tap the mic below and say the details. You review before saving.", and a dismiss action. Once dismissed, the tip SHALL NOT appear again on this device.

#### Scenario: Mic on a phone
- **WHEN** a voice engine is available and the user opens New record on a 390px-wide screen
- **THEN** the footer shows the mic button beside "Save record"

#### Scenario: No mic without an engine
- **WHEN** no voice engine is available to the build
- **THEN** the New record sheet shows no mic, no tip and no voice panel

#### Scenario: No mic in Edit record or on desktop
- **WHEN** the user opens Edit record on a phone, or New record on a 1240px-wide screen
- **THEN** no mic is shown

#### Scenario: Tip shown once
- **WHEN** the user dismisses the "Fill by voice" tip and later opens New record again
- **THEN** the tip is not shown

### Requirement: First-use setup inline in the sheet
The first mic tap SHALL run setup inside the sheet's voice panel slot, in this order, skipping any step already satisfied:

1. A microphone primer. It has a mic icon, "Speak to fill records", "Audio is processed on this device and never saved. English only for now.", "Next, Android will ask for microphone access.", and "Not now" / "Continue". Continue requests the Android microphone permission.
2. A model download offer (mock 8f). It has "Download voice models", "<language> · <size> total, one time. Everything runs on this phone.", one row per manifest model with its role ("Speech recognition" or "Understanding"), its friendly label and its manifest size, a line stating whether the phone is on mobile data (with "Wi-Fi recommended") or Wi-Fi, a line with free storage, and "Later" / "Download <size>". <size> is the sum of the files not yet verified, and <language> is the language name of the speech model.

While the model downloads, the panel SHALL show a compact card: a title, a pause action, a hide action, a progress bar, "<done> of <total> · <percent>%" with the time left, and "Keep filling by hand. The mic turns on when it's ready." The title SHALL read "Downloading voice models" while downloading, "Reconnecting…" while reconnecting, "Checking downloaded data…" while verifying, and "Download paused" while paused. A failed download SHALL show its reason line in the card. The form SHALL stay fully usable during setup and download. The mic SHALL show a progress ring with the percentage and a download icon while downloading, reconnecting or verifying, and SHALL become the idle mic when the model is ready.

#### Scenario: Primer then permission
- **WHEN** the microphone permission was never granted and the user taps the mic
- **THEN** the primer appears, and Continue triggers the Android permission request

#### Scenario: Offer after permission
- **WHEN** the permission is granted and no model is ready
- **THEN** the download offer shows "English · 1.43 GB total, one time. Everything runs on this phone.", the rows "Speech recognition · Whisper Base (English) · 148 MB" and "Understanding · Qwen2.5 1.5B Instruct · 1.29 GB", the network line, free storage, and "Download 1.43 GB"

#### Scenario: Keep typing while downloading
- **WHEN** the download is at 42% and the user types "Lunch" in description
- **THEN** the field accepts the text, the card shows "612 MB of 1.43 GB · 42%", and the mic shows a 42% ring

#### Scenario: Reconnecting in the sheet
- **WHEN** the download is reconnecting
- **THEN** the card title reads "Reconnecting…" and the mic keeps its progress ring

#### Scenario: Not now
- **WHEN** the user taps "Not now" on the primer
- **THEN** the primer closes, no permission is requested, and the mic stays idle

### Requirement: Mic button states
The mic button SHALL present its state by icon and label, not by color alone:
- Idle: an outlined accent circle with a microphone, labelled "Fill by voice".
- Ready: an accent-900 fill with a halo, labelled "Answer by voice". It is used while the panel asks for missing fields.
- Listening: a stop icon with a glow, labelled "Stop listening".
- Processing: a progress ring with a dots icon, labelled "Processing speech" and busy.
- Downloading: a percentage ring with a download icon, labelled "Voice model downloading, N percent".

Tapping the mic in the idle or ready state SHALL start listening, and tapping it while listening SHALL stop listening and start processing. Pressing and holding the mic SHALL listen until release.

#### Scenario: Tap to talk
- **WHEN** the user taps the idle mic, speaks, and taps it again
- **THEN** the mic moves from idle to listening to processing, with its label changing each time

#### Scenario: Hold to talk
- **WHEN** the user holds the mic, speaks, and releases it
- **THEN** listening runs only while the mic is held, and processing starts on release

### Requirement: Listening and processing panels
While listening, the panel SHALL show a pulsing dot with "Listening", an elapsed timer (m:ss), live input-level bars, "Try: “<example>”" built from this collection's active field names and plausible values, "Tap stop when done, or hold the mic to talk", and Cancel. While processing, the panel SHALL show two steps: "Transcribed", checked once the transcript exists, then "Filling fields…" with a progress ring. It SHALL also show the transcript as soon as it exists, "Usually 4–8 seconds", and Cancel. Cancel SHALL stop the current turn, discard its audio and transcript, and leave the form as it was before the turn. "Save record" SHALL be disabled while listening or processing and enabled otherwise. Panel state changes SHALL be announced to screen readers.

#### Scenario: Example from the collection
- **WHEN** the collection has fields description, amount, category and date
- **THEN** the listening hint names values for some of those fields, for example “Lunch, 12.50, category food, yesterday”

#### Scenario: Transcript shown early
- **WHEN** transcription finishes while filling is still running
- **THEN** "Transcribed" is checked, the transcript is shown, and "Filling fields…" is in progress

#### Scenario: Cancel mid-processing
- **WHEN** the user taps Cancel while fields are being filled
- **THEN** no field changes, the transcript is discarded, and Save record is enabled

### Requirement: Applying a voice fill
The engine SHALL return a patch: a list of entries, each naming an active field of the collection, a typed value, and the evidence, meaning the words of the transcript it came from. The app SHALL apply the patch to the draft with these rules:

- An entry naming an unknown, deleted or computed field SHALL be ignored.
- An entry whose value is not valid for the field's type or options SHALL be ignored.
- An entry whose evidence does not appear in the transcript SHALL be ignored.
- An entry SHALL NOT overwrite a field the user typed or picked in this sheet.
- An entry MAY replace a default value or a value from an earlier voice turn.

The draft SHALL then be validated through the existing Rust draft validation. After applying, the panel SHALL read "Filled N fields" (N = entries applied), with a "Heard" disclosure listing each turn's transcript and "Check the fields, then save." with "Speak again". When no entry applies, the panel SHALL show the "Nothing matched" error panel.

#### Scenario: Fill four fields
- **WHEN** the transcript is “Lunch at Nando's, twelve fifty, food, yesterday” and the patch sets description, amount, category and date
- **THEN** the four fields hold the values, each shows the Voice marker, and the panel reads "Filled 4 fields"

#### Scenario: Typed field wins
- **WHEN** the user typed "Taxi home from airport" in description and a later turn's patch sets description to "Taxi home"
- **THEN** description keeps "Taxi home from airport", the other entries apply, and the panel says "Your edit to description was kept."

#### Scenario: Evidence not in transcript
- **WHEN** a patch entry sets amount to 12.50 with evidence "twelve fifty" but the transcript does not contain those words
- **THEN** amount is not changed

### Requirement: Voice field markers and evidence
A field filled by voice SHALL show the Voice chip in its label row, an accent-900 tint and an accent-700 border on its control. Tapping the chip SHALL open a "Heard" popover under the label with the transcript and the evidence words highlighted, plus "Clear field" and "Done". "Clear field" SHALL empty the field and remove its marker. When the user changes a voice-filled field by hand, its marker SHALL be removed and the field SHALL count as typed. A defaulted field SHALL show the Default marker, and a field the user typed SHALL show no marker.

#### Scenario: Evidence popover
- **WHEN** the user taps the Voice chip on amount after “Lunch at Nando's, twelve fifty, food, yesterday”
- **THEN** a popover titled "Heard" shows the transcript with "twelve fifty" highlighted, with "Clear field" and "Done"

#### Scenario: Editing removes the marker
- **WHEN** the user edits the voice-filled description by hand
- **THEN** the Voice chip and tint disappear from description

### Requirement: Asking for missing required fields
After a voice turn, when required fields are still empty, the panel SHALL read "Still need: <field names>" with a round counter "1 of 2", the line "Filled N fields. Say the rest, or type into the marked fields.", and "Answer by voice". The mic SHALL be in the ready state. Each missing field SHALL show the Needed marker and a dashed accent border. An answering turn SHALL apply its patch with the same rules and SHALL NOT reset other fields. When required fields are still empty after the second asking round, the panel SHALL stop asking and read "Couldn't get the <field names>" with "Type it in the marked field, then save. The mic still works if you want to try again." The Needed marks SHALL stay until the fields have values. A follow-up turn that changes fields SHALL read "Updated <field names>", with the Heard disclosure listing the turns in order as 1st, 2nd.

#### Scenario: First asking round
- **WHEN** a turn fills description and date but not the required amount and category
- **THEN** the panel reads "Still need: amount, category" and "1 of 2", both fields show Needed with a dashed border, and the mic is ready

#### Scenario: Answer patches the form
- **WHEN** the user answers “Twenty two forty, transport”
- **THEN** amount and category are filled, description and date are unchanged, and the panel reads "Updated amount, category"

#### Scenario: Stop after two rounds
- **WHEN** amount is still empty after the second asking round
- **THEN** the panel reads "Couldn't get the amount", the mic returns to idle, and amount keeps its Needed mark

### Requirement: Closing and saving with voice
The user SHALL save only by pressing "Save record". Voice fill MUST NOT save a record by itself. Closing the sheet while listening or processing, or after any field changed, SHALL ask "Discard this record?" with "Voice processing will stop and the fields you changed will be lost.", "Discard" and "Keep editing". Discard SHALL stop the turn and close the sheet. Keep editing SHALL keep the turn running.

#### Scenario: Never auto-saves
- **WHEN** a voice turn fills every required field
- **THEN** no record is created until the user presses "Save record"

#### Scenario: Close while processing
- **WHEN** the user taps the sheet's ✕ while fields are being filled
- **THEN** the discard confirmation appears, and "Keep editing" returns to the running turn

### Requirement: Voice error panels
Errors SHALL replace the voice panel at the top of the sheet, keep the form usable, and have their title announced to screen readers:

| Error | Title | Line | Actions |
|---|---|---|---|
| No speech | "Didn't hear anything" | "Check the mic isn't covered, then try again." | Dismiss, Try again |
| Nothing matched | "Nothing matched" | "I couldn't match anything to this collection's fields. Try naming a field, like “amount 12.50”." | Try again |
| Permission off | "Microphone access is off" | "Allow microphone access in Android settings to fill by voice. You can keep typing." | Not now, Open settings |
| Mic busy | "Microphone is busy" | "Another app is using the microphone. Close it, then try again." | Try again |
| Model failed to load | "Voice model couldn't load" | "The model file may be damaged. Retry, or re-download it in Settings." | Settings, Retry |
| Low memory | "Not enough memory" | "Close other apps and try again. Your form is kept." | Try again |
| App went to background | "Recording stopped" | "Fi went to the background, so recording stopped. Nothing was kept." | Speak again |
| Incoming call | "Stopped for a call" | "Recording stopped when a call came in. Nothing was kept." | Speak again |

Each panel SHALL use its own icon. In every case the form's values SHALL be kept.

#### Scenario: App goes to background
- **WHEN** the app goes to the background while listening
- **THEN** recording stops, the captured audio is discarded, and on return the panel shows "Recording stopped" with "Speak again"

#### Scenario: Permission permanently denied
- **WHEN** the microphone permission is denied and the user taps the mic
- **THEN** the "Microphone access is off" panel shows, and "Open settings" opens the app's Android settings page

### Requirement: Audio stays on the device
Captured audio and transcripts SHALL be processed only on the device. Audio SHALL be held only in memory for the current turn and discarded when the turn ends, is cancelled, or fails. Audio and transcripts MUST NOT be written to disk, logs, diagnostics or synced data. Transcripts SHALL be kept only in the open sheet for the Heard disclosure and evidence, and discarded when the sheet closes.

#### Scenario: Nothing persisted
- **WHEN** a voice turn completes and the sheet is closed
- **THEN** no audio or transcript exists in app storage, retained log events, or the diagnostic block

### Requirement: Hands-free spoken feedback
When the Settings switch "Hands-free spoken feedback" is on, the app SHALL speak, using the phone's built-in text-to-speech, the "Still need" question and, after a turn that leaves nothing missing, "N fields filled. Tap Save record when ready." While speaking, the panel SHALL show speaking bars, "Speaking", the spoken line, and a mute action that stops speech and turns the switch off. The switch SHALL be off by default and hidden while the model set is not ready.

#### Scenario: Spoken confirmation
- **WHEN** hands-free is on and a turn fills every required field with four fields
- **THEN** the phone says "4 fields filled. Tap Save record when ready." and the panel shows the speaking state with mute

### Requirement: Settings tab with voice input
Below 720px the bottom navigation SHALL show Collections, Devices and Settings. Settings SHALL show three sections:
- Voice input, shown only when a voice engine is available. It holds:
  - The voice models card (mocks 8b, 8d). Its header reads "Voice models", a state tag with an icon and text, and a summary line starting with the speech model's language name. Below it, one row per manifest model shows its role ("Speech recognition" or "Understanding"), its friendly label, and its size or state: the manifest size when waiting or ready, "<stored> of <size>" while partly stored, "Checking" while verifying, and "<size> · damaged" after a checksum failure. The card shows one of these states:
    - Not downloaded: tag "Not downloaded", summary "<language> · <total> total", "Wi-Fi recommended", "Needs <remaining> · <free> free on this phone", and "Download <remaining>".
    - Downloading: tag "Downloading", summary "<language> · <done> of <total>", a progress bar with the percent and "about <time> left", Pause and Cancel.
    - Reconnecting: tag "Reconnecting", "Connection lost — reconnecting…", the progress bar frozen in a neutral color, "The download resumes where it stopped.", "Leaving Fi can pause the network. Keep it open to finish faster.", Pause and Cancel.
    - Verifying: tag "Verifying", summary "<language> · <total>", "Checking downloaded data…" with the time left when known, a striped bar without a percent, and Cancel.
    - Paused: tag "Paused", summary "<language> · paused at <done> of <total>", the frozen progress bar with the percent and "resumes from here", Resume and Cancel.
    - Failed: tag "Failed", a reason title and line, Retry and "Cancel and delete". A network or HTTP failure reads "No connection" / "Couldn't reach the download server. Check your Wi-Fi, then retry. Downloaded data is kept." with summary "<language> · stopped at <done>". A storage failure reads "Not enough storage" / "Free up <needed> on this phone, then retry." with the same summary. A checksum failure reads "Downloaded file is damaged" / "The <role> model failed its check. Retry downloads it again (<size>)." with summary "<language> · check failed".
    - Ready: tag "Ready", summary "<language> · <total> used on this phone", Re-download and Delete.
  - The hands-free switch with "Speaks the “still need” question and a short confirmation", shown only when the models are ready.
  - The privacy line "Audio is processed on this device and never saved. English only for now."
- Microphone, with the permission state and an "Android settings" link.
- About, with the build label.

State tags SHALL pair an icon with their text, never color alone. Retry SHALL resume from the stored bytes. Cancel and "Cancel and delete" SHALL ask "Cancel download?" with "Downloaded data (<done>) will be deleted.", "Cancel download" and "Keep downloading", unless nothing is stored. Delete SHALL ask "Delete voice models?" with "Frees <size>. Voice fill won’t work until you download them again.", "Delete" and "Keep models". Re-download SHALL be confirmed first. In each confirm dialog the safe choice SHALL be the primary button on the right and the destructive choice the secondary button on the left. There is no undo.

Desktop navigation SHALL NOT change.

#### Scenario: Ready model in Settings
- **WHEN** the model set is ready
- **THEN** Settings › Voice input shows "Voice models", "English · 1.43 GB used on this phone", a "Ready" tag, the rows "Speech recognition · Whisper Base (English) · 148 MB" and "Understanding · Qwen2.5 1.5B Instruct · 1.29 GB", Re-download, Delete and the hands-free switch

#### Scenario: Downloading in Settings
- **WHEN** the speech model is verified and 464 MB of the understanding model are stored
- **THEN** the card shows "English · 612 MB of 1.43 GB", a "Downloading" tag, "42%", the understanding row "464 MB of 1.29 GB", Pause and Cancel

#### Scenario: Cancel asks first
- **WHEN** the user taps Cancel while downloading with 612 MB stored and confirms "Cancel download"
- **THEN** the download stops, the downloaded data is deleted, and the card shows "Not downloaded" with "Download 1.43 GB"

#### Scenario: Keep downloading
- **WHEN** the user taps Cancel and then "Keep downloading"
- **THEN** the dialog closes and the download continues

#### Scenario: Failed with a network reason
- **WHEN** the download failed with the network reason at 612 MB
- **THEN** the card shows a "Failed" tag, "No connection", Retry and "Cancel and delete", and Retry resumes from 612 MB

#### Scenario: Damaged file
- **WHEN** the understanding model failed its checksum
- **THEN** the card shows "Downloaded file is damaged", "The understanding model failed its check. Retry downloads it again (1.29 GB).", and the understanding row reads "1.29 GB · damaged"

#### Scenario: Delete asks first
- **WHEN** the user taps Delete and confirms
- **THEN** the models are deleted, the card shows "Not downloaded" with "Download 1.43 GB", and the hands-free switch is hidden

### Requirement: Voice engine boundary and fake engine
The app SHALL reach speech-to-text and field filling only through one voice engine boundary. It takes the audio of one turn, the collection's active fields (id, name, type, required, options, bounds) and the current draft values, and returns a transcript and a patch. It SHALL report typed failures (no speech, model not loaded, out of memory, microphone busy, cancelled). It SHALL report input levels while listening, so the level bars reflect the microphone. A scripted fake engine SHALL be available in debug builds, or when the build defines `FI_VOICE_FAKE=true`. It returns scripted transcripts and patches after realistic delays, and can be set to produce each typed failure.

The native on-device engine SHALL be the engine of every build that includes it, which is Android arm64 release and debug builds. It is not used when the build defines `FI_VOICE_FAKE=true`, which forces the fake engine. The native engine SHALL report itself available whether or not the models are downloaded, so the first-use download flow can run. Builds without the native engine and without `FI_VOICE_FAKE` SHALL use the fake engine in debug mode and report the engine as unavailable in release mode.

#### Scenario: Release build without an engine
- **WHEN** a release build has no native engine and no `FI_VOICE_FAKE`
- **THEN** the engine reports unavailable and voice fill is not offered

#### Scenario: Android release uses the native engine
- **WHEN** an Android arm64 release build starts
- **THEN** the selected engine is the native engine, it reports available, and the mic is offered on the New record sheet

#### Scenario: Fake engine drives every state
- **WHEN** the fake engine is scripted to return “Taxi home yesterday” with description and date entries, and then to fail with no speech
- **THEN** the sheet shows the filled state with "Still need" for the missing required fields, and then the "Didn't hear anything" panel
