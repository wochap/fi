# image-fields Specification

## Purpose

Defines the `Images` field type's media-folder ingestion (`<uuidv7>_<sanitized_name>.<ext>`), Android `All files access` (`MANAGE_EXTERNAL_STORAGE`) permission and inline folder primer, record form states (single and multiple images, thumbnails on and off, missing on disk waiting for external sync, unset media folder, and required validation), desktop table and mobile card view-mode rendering, and the in-app image lightbox.

## Requirements

### Requirement: Media folder ingestion and portable relative paths
When a user attaches or captures an image (PNG, JPEG, WebP, or GIF) for an `Images` field, Fi SHALL copy the file into the device's configured Media Folder under `<uuidv7>_<sanitized_name>.<ext>` and store only `{ relative_path, original_name, mime_type, size_bytes }` in the record value. Removing an attachment or deleting a record SHALL remove only the Automerge reference and MUST NOT delete the file from disk.

#### Scenario: Attach receipt photo into configured media folder
- **WHEN** the device's Media Folder is `/home/gean/Sync/fi-media` and the user attaches `/tmp/My Receipt (2026).JPG` (`421,888` bytes, JPEG)
- **THEN** Fi copies the bytes to `/home/gean/Sync/fi-media/<uuidv7>_My_Receipt_2026.jpg` and sets the draft attachment item to `{ relative_path: "<uuidv7>_My_Receipt_2026.jpg", original_name: "My Receipt (2026).JPG", mime_type: "image/jpeg", size_bytes: 421888 }`

#### Scenario: Resolve relative path across Linux and Android
- **WHEN** a record containing `relative_path: "0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg"` syncs from Linux (`/home/gean/Sync/fi-media`) to Android configured with `/storage/emulated/0/Sync/fi-media`
- **THEN** Android resolves the image at `/storage/emulated/0/Sync/fi-media/0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg` without modifying the record value

#### Scenario: Clearing a field preserves the file on disk
- **WHEN** the user taps `✕` to clear an `Images` field referencing `0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg` and saves the record
- **THEN** the record's field becomes `Null` in Automerge while `0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg` remains untouched in the Media Folder

### Requirement: Empty and inline media folder onboarding states on the record form
An empty `Images` field on the record form SHALL show a dashed drop-zone button (`Choose image…` with drag-and-drop) at `>= 720px` and side-by-side `Take photo` (`ph-camera`) and `Choose image` (`ph-image`) buttons below `720px`. When no Media Folder is configured on the device, the field SHALL render an inline `Choose a media folder first` card with `Choose folder…` (plus an `All files access` status row and `Android settings` button on Android when `MANAGE_EXTERNAL_STORAGE` is not granted). When a required `Images` field is empty after a save attempt, its picker buttons SHALL show a danger border and `Required` below them.

#### Scenario: Inline folder setup before attaching
- **WHEN** no Media Folder is configured and the user views or taps an `Images` field on the record form
- **THEN** the field displays `Choose a media folder first` with `Choose folder…`, and picking a folder saves the setting and proceeds to the image picker

#### Scenario: Required empty field after save attempt
- **WHEN** the user attempts to save a record while a required `Images` field is empty
- **THEN** the picker buttons render with a danger border and the `Required` error message below them

### Requirement: Populated record form states with thumbnails on or off
When an `Images` field holds locally present attachments and `show_thumbnails` is `true`, a single-image field (`allow_multiple = false`) SHALL render a `124px` thumbnail card with `Tap to view`, an `✕` clear button when optional (omitted when required), `original_name`, `<human_size> · <relative_path>`, and `Replace`; a multi-image field (`allow_multiple = true`) SHALL render a 3-column grid of `78px` thumbnail tiles with drag-reorder handles (`ph-dots-six-vertical`), per-tile `✕` remove buttons, filename/size footers, and an `+ Add image` tile. When `show_thumbnails` is `false`, attachments SHALL render as compact `44px` rows with drag handles (when multiple), `ph-file-image`, `original_name`, `relative_path`, tabular size, and `✕`.

#### Scenario: Single-image populated card with thumbnail on
- **WHEN** the user picks `receipt.jpg` (`412 KB`) on an optional single-image field with `show_thumbnails = true`
- **THEN** the field displays the `124px` thumbnail, `Tap to view`, the `✕` clear button, `receipt.jpg`, `412 KB · <uuidv7>_receipt.jpg`, and `Replace`

#### Scenario: Multi-image drag reorder and compact rows
- **WHEN** an `Images` field with `allow_multiple = true` holds `[receipt.jpg, espresso.jpg]` and the user drags `espresso.jpg` before `receipt.jpg` and saves
- **THEN** the record commits `[espresso.jpg, receipt.jpg]` in the new order, and when `show_thumbnails` is `false` the two items render as compact rows without image thumbnails

### Requirement: Missing-on-disk record form states
When a record references an image whose `relative_path` is not present on disk, the field SHALL preserve the reference across edits and render a striped placeholder box showing `original_name · <human_size>` and `relative_path`:
- When the Media Folder is configured, the placeholder SHALL show `ph-cloud-arrow-down`, `File not in folder yet · waiting for external sync`, `Reference is kept when saving`, and a `Check again` action.
- When no Media Folder is configured on this device, the placeholder SHALL show `ph-folder-dashed`, `Set a media folder in Settings to view this file on this device.`, and a `Set folder…` action.
- In a multi-image field, each item SHALL resolve independently, displaying `<present> of <total> on this device` in the field header when mixed.

#### Scenario: Missing file reference is preserved when editing another field
- **WHEN** a record's `receipt` field references `0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg` which is not yet on disk, and the user edits `amount` and saves
- **THEN** `amount` is updated and the `receipt` attachment metadata remains intact in the record

#### Scenario: Check again detects newly synced file
- **WHEN** an `Images` field shows `File not in folder yet · waiting for external sync`, Syncthing finishes writing the file into the Media Folder, and the user taps `Check again`
- **THEN** the placeholder transitions immediately to the rendered image thumbnail

### Requirement: View mode rendering in desktop tables and mobile cards
In view mode, the desktop records table (`>= 720px`) SHALL render a `28×28px` thumbnail + `original_name` for a single present image, up to two stacked `28×28px` thumbnails + `+<N-2>` tag + `<N> files` for multiple images, a dashed `28×28px` `ph-file-dashed` badge with `<original_name> · missing` when missing on disk, and `—` when empty. Mobile record cards (`< 720px`) SHALL render up to two `64×64px` thumbnails beside the field metadata when `show_thumbnails` is `true` and present, or a `64×64px` striped `ph-cloud-arrow-down` placeholder with `Waiting for external sync` when missing on disk.

#### Scenario: Desktop table cell with three images
- **WHEN** a record holds three locally present images on the `photos` field and is viewed in the desktop records table
- **THEN** the `photos` cell displays two stacked `28×28px` thumbnails, a `+1` neutral tag, and `3 files`

#### Scenario: Mobile card waiting for external sync
- **WHEN** a record holds one image `invoice.jpg` (`412 KB`) whose file is not yet in the phone's Media Folder
- **THEN** the mobile record card displays a `64×64px` striped `ph-cloud-arrow-down` placeholder, `invoice.jpg · 412 KB`, and `Waiting for external sync`

### Requirement: In-app image lightbox and external handoff
Tapping a locally present image thumbnail in the desktop records table, on a mobile record card, or in the record editor form SHALL open the in-app Image Lightbox modal over a dark scrim, displaying `original_name`, `<index> of <total> · <human_size> · <width>×<height>`, previous/next navigation arrows and a thumbnail strip when multiple images are present, the `relative_path` under `File in media folder`, an `Open externally` (`ph-arrow-square-out`) action that opens the file in the OS viewer, and `Close`.

#### Scenario: Navigate multi-image lightbox and open externally
- **WHEN** the user taps the first thumbnail of a record with two images (`receipt.jpg` and `espresso.jpg`)
- **THEN** the lightbox opens showing `receipt.jpg`, `1 of 2 · 412 KB · 1600×1200`, the relative path inside the media folder, next/previous arrows, and the 2-item thumbnail strip; tapping `Next image` switches to `espresso.jpg` (`2 of 2`)

### Requirement: Fi-managed unused media identification and age-filtered manual deletion
Fi SHALL identify unused media files strictly as root-level regular files in the configured Media Folder that:
1. Match Fi's managed naming convention `<uuidv7>_<name>.<ext>` where `<uuidv7>` is a valid RFC 9562 version-7 UUID and `<ext>` is a supported image extension (`jpg`, `jpeg`, `png`, `webp`, or `gif`, case-insensitive); and
2. Are not referenced by any active (non-deleted) record across any active (non-deleted) collection (including cloned records and cross-collection copies).

Subdirectories, temporary `.fi_tmp_*` files, Syncthing metadata (such as `.stfolder`), and any non-Fi-managed files MUST NEVER be counted as unused or deleted.

When previewing or executing manual cleanup with a minimum age of `N` days (`N >= 0`), Fi SHALL compute each candidate's age from the millisecond creation timestamp embedded in its UUIDv7 prefix relative to the current UTC time:
- When `N == 0`, every unused Fi-managed file matches regardless of age.
- When `N > 0`, only unused Fi-managed files whose age is at least `N * 86,400` seconds match.

Deleting unused media SHALL occur only when explicitly confirmed by the user via manual cleanup; removing an attachment, deleting a record, or clearing the Media Folder setting MUST still leave files on disk.

#### Scenario: Non-Fi files, subdirectories, and cloned record references are protected
- **WHEN** the Media Folder contains a referenced file `0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg` (referenced by a cloned record in another collection), an unreferenced Fi-managed file `01900000-0000-7000-8000-000000000001_old.jpg`, an unrelated file `vacation.jpg`, and a `.stfolder` directory
- **THEN** only `01900000-0000-7000-8000-000000000001_old.jpg` is reported as unused, and deleting unused media with `min_age_days = 0` removes only that file while leaving the cloned-record image, `vacation.jpg`, and `.stfolder` intact

#### Scenario: Minimum age threshold filters by UUIDv7 creation timestamp
- **WHEN** the Media Folder contains two unreferenced Fi-managed files — one whose UUIDv7 timestamp is 400 days old (`400 KB`) and one whose UUIDv7 timestamp is 10 days old (`1.2 MB`)
- **THEN** previewing cleanup with `min_age_days = 365` reports `1` matching file (`400 KB`) out of `2` total unused files (`1.6 MB`), and executing cleanup with `min_age_days = 365` deletes only the 400-day-old file while preserving the 10-day-old file
