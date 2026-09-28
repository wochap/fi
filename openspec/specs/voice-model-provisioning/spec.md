# voice-model-provisioning Specification

## Purpose

Downloads, verifies, stores and removes the on-device speech and language models that voice fill needs, so the feature works offline after one explicit download.

## Requirements

### Requirement: Pinned model manifest
The app SHALL ship a model manifest that lists every file voice fill needs, each with a download URL pinned to a fixed revision, its exact size in bytes, and its SHA-256 digest. The total download size shown to the user SHALL be the sum of the manifest sizes of files not yet verified on the device. The manifest SHALL carry a version, and a model set SHALL count as ready only when every file of the current manifest version is present and verified.

#### Scenario: Size shown before download
- **WHEN** no model file is on the device and the manifest lists files of 148 MB and 1.13 GB
- **THEN** the offered download size is their sum, formatted as "1.3 GB"

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
Rust SHALL report the model set's status as not downloaded, downloading (with progress), paused (with progress), ready (with size on disk), or failed (with a typed reason), and SHALL emit a status event whenever it changes. "Delete model" SHALL remove every model file and any partial download and return the status to not downloaded. "Re-download" SHALL delete and then start a fresh download. Neither SHALL run while a voice fill is in progress.

#### Scenario: Delete frees storage
- **WHEN** the model set is ready and the user confirms Delete model
- **THEN** every model file is removed, the status reads not downloaded, and the freed size equals the size that was on disk

#### Scenario: Status survives restart
- **WHEN** the model set was ready and the app restarts
- **THEN** the status reads ready without downloading again
