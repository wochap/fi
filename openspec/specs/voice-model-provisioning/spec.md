# voice-model-provisioning Specification

## Purpose

Downloads, verifies, stores and removes the on-device speech and language models that voice fill needs, so the feature works offline after one explicit download.

## Requirements

### Requirement: Pinned model manifest
The app SHALL ship a model manifest that lists every file voice fill needs, each with a download URL pinned to a fixed revision, its exact size in bytes, its SHA-256 digest, a friendly label, a role, and a language. The role SHALL be `speech` for the speech recognition model or `understanding` for the instruction model. The language SHALL be a language code such as `en` for a model that serves one language, or empty (`null`) for a model shared by every language. The bundled manifest SHALL label `ggml-base.en.bin` "Whisper Base (English)" with role `speech` and language `en`, and `qwen2.5-1.5b-instruct-q5_k_m.gguf` "Qwen2.5 1.5B Instruct" with role `understanding` and no language. The total download size shown to the user SHALL be the sum of the manifest sizes of files not yet verified on the device, and every size shown for the models SHALL be computed from the manifest. The manifest SHALL carry a version, and a model set SHALL count as ready only when every file of the current manifest version is present and verified.

#### Scenario: Size shown before download
- **WHEN** no model file is on the device and the manifest lists files of 147,964,211 and 1,285,494,304 bytes
- **THEN** the offered download size is their sum, 1,433,458,515 bytes, formatted as "1.43 GB"

#### Scenario: Friendly model details
- **WHEN** the app reads the bundled manifest
- **THEN** the speech file is "Whisper Base (English)", role speech, language en, 148 MB, and the understanding file is "Qwen2.5 1.5B Instruct", role understanding, no language, 1.29 GB

#### Scenario: Manifest version changes
- **WHEN** the app is updated with a manifest whose version differs from the one the stored files were verified against
- **THEN** the model set is not ready until the files the new manifest lists are present and verified

### Requirement: Explicit, resumable download
Rust SHALL download model files only after an explicit user request, into the app's private storage, over HTTPS. It SHALL report progress (bytes done, bytes total, estimated time left) as a stream at least once per second while bytes arrive, SHALL support pause and cancel, and SHALL resume a paused or interrupted download from the bytes already on disk when the server supports ranged requests, starting over otherwise. A file SHALL be written under a temporary name and moved into place only after its SHA-256 matches the manifest; a mismatch SHALL delete the file and report a typed checksum error. Before starting, Rust SHALL check free storage and SHALL refuse with a typed error when the remaining download plus 200 MB headroom does not fit.

#### Scenario: Progress reported
- **WHEN** a download of 1.3 GB is running and 494 MB have arrived
- **THEN** the stream reports 494 MB of 1.3 GB, 38%, and an estimate of the time left

#### Scenario: Pause and resume
- **WHEN** the user pauses at 38% and later resumes
- **THEN** the download continues from the bytes already stored rather than from zero

#### Scenario: Interrupted by the app closing
- **WHEN** the app is closed at 38% and reopened and the user taps Download again
- **THEN** the download resumes from the stored bytes

#### Scenario: Corrupt file rejected
- **WHEN** a downloaded file's SHA-256 does not match the manifest
- **THEN** the file is deleted, the model set is not ready, and a checksum error is reported

#### Scenario: Not enough storage
- **WHEN** the device has less free storage than the remaining download plus 200 MB
- **THEN** no download starts and a typed not-enough-storage error states how much space is needed

### Requirement: Model status, re-download and delete
Rust SHALL report the model set's status as not downloaded, downloading (with progress), reconnecting (with progress), verifying (with verification progress), paused (with progress), ready (with size on disk), or failed (with a typed reason and progress), and SHALL emit a status event whenever it changes. Every status SHALL carry, for each manifest file, its name, label, role, language, manifest size, bytes stored, and a file state: waiting, downloading, checking, ready, or damaged. A file SHALL be ready when it is verified, checking while its stored bytes are being verified, damaged when the last failure was its checksum mismatch, downloading when it is the file being transferred, and waiting otherwise. A checksum failure SHALL name the damaged file.

"Cancel" SHALL stop the download and delete every file and partial download of the model set, returning the status to not downloaded with the full manifest size. "Delete model" SHALL remove every model file and any partial download and return the status to not downloaded. "Re-download" SHALL delete and then start a fresh download. Neither delete nor re-download SHALL run while a voice fill is in progress.

A failed download SHALL keep the bytes already stored, except the file that failed its checksum, so that starting again resumes. A start refused for storage SHALL also set the status to failed with the not-enough-storage reason. A write that fails because the storage is full SHALL fail the download with the not-enough-storage reason, stating the space needed for the rest of the download plus the 200 MB headroom.

#### Scenario: Delete frees storage
- **WHEN** the model set is ready and the user confirms Delete model
- **THEN** every model file is removed, the status reads not downloaded, and the freed size equals the size that was on disk

#### Scenario: Status survives restart
- **WHEN** the model set was ready and the app restarts
- **THEN** the status reads ready without downloading again

#### Scenario: Cancel deletes downloaded data
- **WHEN** the speech model is verified, 464 MB of the understanding model are stored, and the user cancels
- **THEN** both the verified speech model and the partial understanding model are deleted, and the status reads not downloaded with 1.43 GB to download

#### Scenario: Per-file state while downloading
- **WHEN** the speech model is verified and the understanding model is transferring with 464 MB stored
- **THEN** the status lists the speech model as ready with 148 MB stored and the understanding model as downloading with 464 MB of 1.29 GB stored

#### Scenario: Damaged file named
- **WHEN** the understanding model fails its checksum
- **THEN** the status is failed with the checksum reason naming `qwen2.5-1.5b-instruct-q5_k_m.gguf`, that file's state is damaged, its partial bytes are deleted, and the verified speech model is kept

#### Scenario: Storage fills during the download
- **WHEN** a write fails because the device storage is full
- **THEN** the status is failed with the not-enough-storage reason, and the bytes already stored are kept

### Requirement: Stalled download recovery
While a download runs, Rust SHALL treat 15 seconds without receiving any byte as a stall. A stall, a network error, or an HTTP 408, 429 or 5xx answer SHALL NOT fail the download at once: Rust SHALL report the reconnecting status with the progress so far and SHALL retry automatically, resuming from the bytes already stored with a ranged request. Retries SHALL wait 1, 2, 4, 8, 16 and then 30 seconds between attempts, and the wait SHALL reset once bytes arrive again. After 6 consecutive attempts that receive no bytes, the download SHALL fail with the network reason, keeping the stored bytes. Any other HTTP status SHALL fail the download at once with the HTTP status reason. When bytes arrive after reconnecting, the status SHALL return to downloading.

#### Scenario: Connection goes silent
- **WHEN** the server stops sending bytes in the middle of a file and the connection stays open
- **THEN** within 16 seconds the status reads reconnecting, and a new request asks for the range starting at the stored byte count

#### Scenario: Recovery after a stall
- **WHEN** a retry after a stall receives bytes
- **THEN** the status returns to downloading and the finished file matches its SHA-256

#### Scenario: Network stays down
- **WHEN** 6 consecutive attempts receive no bytes
- **THEN** the status is failed with the network reason and the stored bytes remain on disk

#### Scenario: Not found is not retried
- **WHEN** the server answers HTTP 404
- **THEN** the status is failed with HTTP status 404 without a retry

### Requirement: Prompt download control
Pause and Cancel SHALL take effect within one second, including while a read is waiting on a silent connection, during a retry wait, and during verification. Pause SHALL keep the stored bytes and report paused. Starting or resuming SHALL always work: when an earlier download worker is still stopping, Rust SHALL stop it and start a new download, and only one worker SHALL write to the model files at a time. Starting while a download is already downloading, reconnecting or verifying SHALL change nothing.

#### Scenario: Pause during a silent connection
- **WHEN** the connection is silent and the user pauses
- **THEN** the status reads paused within one second and the stored bytes are kept

#### Scenario: Cancel during a silent connection
- **WHEN** the connection is silent and the user cancels
- **THEN** within one second the download stops, the model set's files are deleted, and the status reads not downloaded

#### Scenario: Resume right after pause
- **WHEN** the user pauses and taps Resume while the earlier worker is still stopping
- **THEN** a new download starts from the stored bytes and the status reads verifying or downloading

### Requirement: Verification progress
Before resuming a file from stored bytes, Rust SHALL verify the stored bytes and SHALL report the verifying status meanwhile, with the file being checked, the bytes checked, the bytes to check, and an estimate of the time left once a rate is known. The first status event of a download, a verification, or a reconnect SHALL be emitted immediately, and later progress events SHALL follow at least once per second while bytes are read or checked.

#### Scenario: Resume a large partial file
- **WHEN** 900 MB of the understanding model are stored and the user resumes
- **THEN** the status immediately reads verifying for that file with 0 of 900 MB checked, then reports checked bytes at least once per second, then reads downloading

#### Scenario: First progress is immediate
- **WHEN** the user starts a download from nothing
- **THEN** a downloading event with the file list is emitted before the first second passes
