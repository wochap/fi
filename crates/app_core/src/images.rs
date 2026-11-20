use std::{
    collections::HashSet,
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use thiserror::Error;
use uuid::Uuid;

use crate::values::ImageAttachment;

const MAX_SANITIZED_STEM_LEN: usize = 48;
const MS_PER_DAY: u64 = 86_400_000;

#[derive(Debug, Error)]
pub enum ImageIngestError {
    #[error("media folder {path:?} is not accessible: {message}")]
    MediaFolderUnavailable { path: PathBuf, message: String },
    #[error("unsupported image format; only JPEG, PNG, WebP, and GIF images are supported")]
    UnsupportedFormat,
    #[error("image I/O error: {0}")]
    Io(#[from] std::io::Error),
}

/// Summary of the device-local Media Folder on disk and how it compares to active record
/// references.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MediaFolderStatus {
    pub accessible: bool,
    pub file_count: u64,
    pub total_bytes: u64,
    pub missing_referenced_count: u64,
    pub unused_file_count: u64,
    pub unused_total_bytes: u64,
}

/// Preview of unused Fi-managed image files in the Media Folder for a given minimum-age threshold.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnusedMediaPreview {
    pub total_unused_count: u64,
    pub total_unused_bytes: u64,
    pub matching_count: u64,
    pub matching_bytes: u64,
}

/// Outcome of a manual unused media deletion pass.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnusedMediaCleanupResult {
    pub deleted_count: u64,
    pub freed_bytes: u64,
}

/// Detects an image's MIME type and canonical lowercase file extension from its magic bytes.
pub fn detect_image_format(bytes: &[u8]) -> Result<(&'static str, &'static str), ImageIngestError> {
    if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        return Ok(("image/jpeg", "jpg"));
    }
    if bytes.len() >= 8 && bytes[..8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
        return Ok(("image/png", "png"));
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Ok(("image/webp", "webp"));
    }
    if bytes.len() >= 6 && (&bytes[0..6] == b"GIF87a" || &bytes[0..6] == b"GIF89a") {
        return Ok(("image/gif", "gif"));
    }
    Err(ImageIngestError::UnsupportedFormat)
}

/// Infers a supported image MIME type from a filename's extension.
#[must_use]
pub fn infer_mime_from_extension(filename: &str) -> Option<&'static str> {
    let (_, ext) = filename.rsplit_once('.')?;
    match ext.to_ascii_lowercase().as_str() {
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "webp" => Some("image/webp"),
        "gif" => Some("image/gif"),
        _ => None,
    }
}

/// Sanitizes an original filename into a safe ASCII stem for `<uuidv7>_<sanitized_name>.<ext>`.
/// Keeps ASCII alphanumerics, `-`, and `_`, collapses runs of other characters to `_`, trims
/// leading/trailing `_` and `-`, truncates to 48 characters, and falls back to `"image"`.
#[must_use]
pub fn sanitize_filename_stem(original_name: &str) -> String {
    let base = Path::new(original_name)
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(original_name);
    let stem = match base.rsplit_once('.') {
        Some((s, _)) if !s.is_empty() => s,
        _ => base,
    };

    let mut out = String::with_capacity(stem.len().min(MAX_SANITIZED_STEM_LEN));
    let mut prev_underscore = false;
    for ch in stem.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
            if ch == '_' {
                if !prev_underscore && !out.is_empty() {
                    out.push('_');
                    prev_underscore = true;
                }
            } else {
                out.push(ch);
                prev_underscore = false;
            }
        } else if !prev_underscore && !out.is_empty() {
            out.push('_');
            prev_underscore = true;
        }
    }

    let trimmed = out.trim_matches(|c| c == '_' || c == '-');
    let truncated = if trimmed.len() > MAX_SANITIZED_STEM_LEN {
        trimmed[..MAX_SANITIZED_STEM_LEN].trim_end_matches(|c| c == '_' || c == '-')
    } else {
        trimmed
    };

    if truncated.is_empty() {
        "image".to_string()
    } else {
        truncated.to_string()
    }
}

/// Builds a fresh collision-free relative filename `<uuidv7>_<sanitized_name>.<ext>`.
#[must_use]
pub fn build_relative_path(original_name: &str, canonical_ext: &str) -> String {
    let id = Uuid::now_v7();
    let stem = sanitize_filename_stem(original_name);
    format!("{id}_{stem}.{canonical_ext}")
}

/// Derives a display `original_name` from a `relative_path` by stripping a leading `<uuid>_`
/// prefix if present (used during CSV import).
#[must_use]
pub fn derive_original_name_from_relative_path(relative_path: &str) -> String {
    if let Some((prefix, rest)) = relative_path.split_once('_')
        && !rest.is_empty()
        && Uuid::parse_str(prefix).is_ok()
    {
        return rest.to_string();
    }
    relative_path.to_string()
}

/// Copies `source_path` into `media_folder` under `<uuidv7>_<sanitized_name>.<ext>` using an
/// atomic temp-file write + rename, returning the portable [`ImageAttachment`] metadata.
pub fn ingest_image_file(
    source_path: &Path,
    media_folder: &Path,
) -> Result<ImageAttachment, ImageIngestError> {
    let bytes = fs::read(source_path)?;
    let original_name = source_path
        .file_name()
        .and_then(|name| name.to_str())
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .unwrap_or("image")
        .to_string();
    ingest_image_bytes(&bytes, &original_name, media_folder)
}

/// Writes `bytes` into `media_folder` under `<uuidv7>_<sanitized_name>.<ext>` using an atomic
/// temp-file write + rename, validating image magic bytes first.
pub fn ingest_image_bytes(
    bytes: &[u8],
    original_name: &str,
    media_folder: &Path,
) -> Result<ImageAttachment, ImageIngestError> {
    ensure_media_folder_accessible(media_folder)?;
    let (mime_type, ext) = detect_image_format(bytes)?;
    let cleaned_original = {
        let trimmed = original_name.trim();
        if trimmed.is_empty() {
            format!("image.{ext}")
        } else {
            trimmed.to_string()
        }
    };
    let relative_path = build_relative_path(&cleaned_original, ext);
    let target_path = media_folder.join(&relative_path);
    let temp_path = media_folder.join(format!(".fi_tmp_{}", Uuid::now_v7()));

    let write_result = (|| -> Result<(), std::io::Error> {
        let mut file = fs::File::create(&temp_path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp_path, &target_path)?;
        Ok(())
    })();

    if let Err(err) = write_result {
        let _ = fs::remove_file(&temp_path);
        return Err(ImageIngestError::Io(err));
    }

    Ok(ImageAttachment {
        relative_path,
        original_name: cleaned_original,
        mime_type: mime_type.to_string(),
        size_bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
    })
}

/// Parses a Fi-managed `<uuidv7>_<name>.<ext>` filename and returns its embedded UUIDv7
/// creation timestamp in milliseconds since the Unix epoch.
#[must_use]
pub fn parse_fi_managed_image_created_ms(filename: &str) -> Option<u64> {
    if filename.starts_with(".fi_tmp_") {
        return None;
    }
    let (uuid_str, rest) = filename.split_once('_')?;
    let (stem, _) = rest.rsplit_once('.')?;
    if stem.is_empty() || infer_mime_from_extension(rest).is_none() {
        return None;
    }
    let uuid = Uuid::parse_str(uuid_str).ok()?;
    if uuid.get_version() != Some(uuid::Version::SortRand) {
        return None;
    }
    let ts = uuid.get_timestamp()?;
    let (secs, nanos) = ts.to_unix();
    secs.checked_mul(1_000)?
        .checked_add(u64::from(nanos / 1_000_000))
}

/// Returns the current UTC timestamp in milliseconds since the Unix epoch.
#[must_use]
pub fn current_utc_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
        })
}

fn matches_min_age(created_ms: u64, now_ms: u64, min_age_days: u32) -> bool {
    if min_age_days == 0 {
        return true;
    }
    let threshold_ms = u64::from(min_age_days).saturating_mul(MS_PER_DAY);
    now_ms.saturating_sub(created_ms) >= threshold_ms
}

struct UnusedMediaCandidate {
    path: PathBuf,
    size_bytes: u64,
    created_ms: u64,
}

fn collect_unused_media_candidates(
    media_folder: &Path,
    referenced_paths: &HashSet<String>,
) -> Result<Vec<UnusedMediaCandidate>, ImageIngestError> {
    ensure_media_folder_accessible(media_folder)?;
    let entries = fs::read_dir(media_folder)?;
    let mut candidates = Vec::new();

    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        let Some(created_ms) = parse_fi_managed_image_created_ms(name_str) else {
            continue;
        };
        if referenced_paths.contains(name_str) {
            continue;
        }
        let size_bytes = entry.metadata().map_or(0, |meta| meta.len());
        candidates.push(UnusedMediaCandidate {
            path: entry.path(),
            size_bytes,
            created_ms,
        });
    }

    Ok(candidates)
}

/// Previews how many unused Fi-managed image files in `media_folder` match `min_age_days` at
/// `now_ms`.
pub fn preview_unused_media_cleanup_at(
    media_folder: &Path,
    referenced_paths: &HashSet<String>,
    min_age_days: u32,
    now_ms: u64,
) -> Result<UnusedMediaPreview, ImageIngestError> {
    let candidates = collect_unused_media_candidates(media_folder, referenced_paths)?;
    let mut total_unused_count = 0u64;
    let mut total_unused_bytes = 0u64;
    let mut matching_count = 0u64;
    let mut matching_bytes = 0u64;

    for candidate in candidates {
        total_unused_count = total_unused_count.saturating_add(1);
        total_unused_bytes = total_unused_bytes.saturating_add(candidate.size_bytes);
        if matches_min_age(candidate.created_ms, now_ms, min_age_days) {
            matching_count = matching_count.saturating_add(1);
            matching_bytes = matching_bytes.saturating_add(candidate.size_bytes);
        }
    }

    Ok(UnusedMediaPreview {
        total_unused_count,
        total_unused_bytes,
        matching_count,
        matching_bytes,
    })
}

/// Deletes unused Fi-managed image files in `media_folder` that are at least `min_age_days` old
/// relative to `now_ms`.
pub fn delete_unused_media_at(
    media_folder: &Path,
    referenced_paths: &HashSet<String>,
    min_age_days: u32,
    now_ms: u64,
) -> Result<UnusedMediaCleanupResult, ImageIngestError> {
    let candidates = collect_unused_media_candidates(media_folder, referenced_paths)?;
    let mut deleted_count = 0u64;
    let mut freed_bytes = 0u64;

    for candidate in candidates {
        if !matches_min_age(candidate.created_ms, now_ms, min_age_days) {
            continue;
        }
        match fs::remove_file(&candidate.path) {
            Ok(()) => {
                deleted_count = deleted_count.saturating_add(1);
                freed_bytes = freed_bytes.saturating_add(candidate.size_bytes);
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => return Err(ImageIngestError::Io(err)),
        }
    }

    Ok(UnusedMediaCleanupResult {
        deleted_count,
        freed_bytes,
    })
}

/// Scans `media_folder` for accessibility, local file count & total bytes, how many of
/// `referenced_paths` are missing from disk, and how many Fi-managed image files are unused.
#[must_use]
pub fn scan_media_folder(
    media_folder: &Path,
    referenced_paths: &HashSet<String>,
) -> MediaFolderStatus {
    let Ok(entries) = fs::read_dir(media_folder) else {
        return MediaFolderStatus {
            accessible: false,
            file_count: 0,
            total_bytes: 0,
            missing_referenced_count: u64::try_from(referenced_paths.len()).unwrap_or(u64::MAX),
            unused_file_count: 0,
            unused_total_bytes: 0,
        };
    };

    let mut file_count = 0u64;
    let mut total_bytes = 0u64;
    let mut unused_file_count = 0u64;
    let mut unused_total_bytes = 0u64;
    let mut present_names = HashSet::new();

    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        if name_str.starts_with(".fi_tmp_") {
            continue;
        }
        let size_bytes = entry.metadata().map_or(0, |meta| meta.len());
        file_count = file_count.saturating_add(1);
        total_bytes = total_bytes.saturating_add(size_bytes);
        if parse_fi_managed_image_created_ms(name_str).is_some()
            && !referenced_paths.contains(name_str)
        {
            unused_file_count = unused_file_count.saturating_add(1);
            unused_total_bytes = unused_total_bytes.saturating_add(size_bytes);
        }
        present_names.insert(name_str.to_string());
    }

    let missing_referenced_count = referenced_paths
        .iter()
        .filter(|path| !present_names.contains(path.as_str()))
        .count();

    MediaFolderStatus {
        accessible: true,
        file_count,
        total_bytes,
        missing_referenced_count: u64::try_from(missing_referenced_count).unwrap_or(u64::MAX),
        unused_file_count,
        unused_total_bytes,
    }
}

fn ensure_media_folder_accessible(media_folder: &Path) -> Result<(), ImageIngestError> {
    match fs::metadata(media_folder) {
        Ok(meta) if meta.is_dir() => Ok(()),
        Ok(_) => Err(ImageIngestError::MediaFolderUnavailable {
            path: media_folder.to_path_buf(),
            message: "path is not a directory".into(),
        }),
        Err(err) => Err(ImageIngestError::MediaFolderUnavailable {
            path: media_folder.to_path_buf(),
            message: err.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn synthetic_jpeg() -> Vec<u8> {
        vec![
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00,
        ]
    }

    fn synthetic_png() -> Vec<u8> {
        vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00]
    }

    fn synthetic_webp() -> Vec<u8> {
        let mut bytes = b"RIFF".to_vec();
        bytes.extend_from_slice(&[0x10, 0x00, 0x00, 0x00]);
        bytes.extend_from_slice(b"WEBP");
        bytes.extend_from_slice(b"VP8 ");
        bytes
    }

    fn synthetic_gif() -> Vec<u8> {
        b"GIF89a\x01\x00\x01\x00".to_vec()
    }

    #[test]
    fn sanitize_stem_handles_spaces_punctuation_and_limits() {
        assert_eq!(
            sanitize_filename_stem("My Receipt (2026).JPG"),
            "My_Receipt_2026"
        );
        assert_eq!(sanitize_filename_stem("...///???"), "image");
        assert_eq!(sanitize_filename_stem("  café photo!.png"), "caf_photo");
        let long = format!("{}.png", "a".repeat(80));
        assert_eq!(sanitize_filename_stem(&long).len(), MAX_SANITIZED_STEM_LEN);
    }

    #[test]
    fn detect_supported_magic_bytes_and_reject_non_images() {
        assert_eq!(
            detect_image_format(&synthetic_jpeg()).unwrap(),
            ("image/jpeg", "jpg")
        );
        assert_eq!(
            detect_image_format(&synthetic_png()).unwrap(),
            ("image/png", "png")
        );
        assert_eq!(
            detect_image_format(&synthetic_webp()).unwrap(),
            ("image/webp", "webp")
        );
        assert_eq!(
            detect_image_format(&synthetic_gif()).unwrap(),
            ("image/gif", "gif")
        );
        assert!(matches!(
            detect_image_format(b"%PDF-1.7\n"),
            Err(ImageIngestError::UnsupportedFormat)
        ));
    }

    #[test]
    fn ingest_copies_atomically_and_returns_portable_metadata() {
        let media_dir = TempDir::new().unwrap();
        let src_dir = TempDir::new().unwrap();
        let src_file = src_dir.path().join("My Receipt (2026).JPG");
        let bytes = synthetic_jpeg();
        fs::write(&src_file, &bytes).unwrap();

        let attachment = ingest_image_file(&src_file, media_dir.path()).unwrap();
        assert_eq!(attachment.original_name, "My Receipt (2026).JPG");
        assert_eq!(attachment.mime_type, "image/jpeg");
        assert_eq!(attachment.size_bytes, bytes.len() as u64);
        assert!(attachment.relative_path.ends_with("_My_Receipt_2026.jpg"));
        assert!(ImageAttachment::is_valid_relative_path(
            &attachment.relative_path
        ));

        let copied = fs::read(media_dir.path().join(&attachment.relative_path)).unwrap();
        assert_eq!(copied, bytes);

        // No leftover temp files
        let entries: Vec<_> = fs::read_dir(media_dir.path()).unwrap().collect();
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn ingest_rejects_missing_media_folder_and_invalid_bytes() {
        let missing = PathBuf::from("/nonexistent/fi-media-folder-test");
        assert!(matches!(
            ingest_image_bytes(&synthetic_png(), "a.png", &missing),
            Err(ImageIngestError::MediaFolderUnavailable { .. })
        ));

        let media_dir = TempDir::new().unwrap();
        assert!(matches!(
            ingest_image_bytes(b"not an image", "fake.jpg", media_dir.path()),
            Err(ImageIngestError::UnsupportedFormat)
        ));
    }

    #[test]
    fn scan_reports_local_files_and_missing_references() {
        let media_dir = TempDir::new().unwrap();
        let a = ingest_image_bytes(&synthetic_png(), "one.png", media_dir.path()).unwrap();
        let b = ingest_image_bytes(&synthetic_webp(), "two.webp", media_dir.path()).unwrap();

        let referenced = HashSet::from([
            a.relative_path.clone(),
            "0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_missing.jpg".to_string(),
        ]);
        let status = scan_media_folder(media_dir.path(), &referenced);
        assert!(status.accessible);
        assert_eq!(status.file_count, 2);
        assert_eq!(status.total_bytes, a.size_bytes + b.size_bytes);
        assert_eq!(status.missing_referenced_count, 1);
        assert_eq!(status.unused_file_count, 1);
        assert_eq!(status.unused_total_bytes, b.size_bytes);

        let missing_dir = scan_media_folder(Path::new("/nonexistent/fi-scan-test"), &referenced);
        assert!(!missing_dir.accessible);
        assert_eq!(missing_dir.missing_referenced_count, 2);
        assert_eq!(missing_dir.unused_file_count, 0);
        assert_eq!(missing_dir.unused_total_bytes, 0);
    }

    fn uuidv7_for_unix_ms(ms: u64) -> Uuid {
        let secs = ms / 1_000;
        let subsec_nanos = u32::try_from((ms % 1_000) * 1_000_000).unwrap();
        let ts = uuid::Timestamp::from_unix(uuid::NoContext, secs, subsec_nanos);
        Uuid::new_v7(ts)
    }

    #[test]
    fn parse_fi_managed_image_created_ms_validates_uuidv7_and_extensions() {
        let ts_ms = 1_700_000_123_456u64;
        let id = uuidv7_for_unix_ms(ts_ms);
        assert_eq!(
            parse_fi_managed_image_created_ms(&format!("{id}_receipt.JPG")),
            Some(ts_ms)
        );
        assert_eq!(
            parse_fi_managed_image_created_ms(&format!("{id}_photo.webp")),
            Some(ts_ms)
        );
        // Rejects non-v7 UUID (v4)
        let v4 = Uuid::new_v4();
        assert_eq!(
            parse_fi_managed_image_created_ms(&format!("{v4}_receipt.jpg")),
            None
        );
        // Rejects non-image, temp, plain, or empty stem
        assert_eq!(
            parse_fi_managed_image_created_ms(&format!("{id}_notes.pdf")),
            None
        );
        assert_eq!(
            parse_fi_managed_image_created_ms(&format!("{id}_.jpg")),
            None
        );
        assert_eq!(
            parse_fi_managed_image_created_ms(&format!(".fi_tmp_{id}")),
            None
        );
        assert_eq!(parse_fi_managed_image_created_ms("vacation.jpg"), None);
    }

    #[test]
    fn unused_media_cleanup_protects_referenced_and_non_fi_files() {
        let media_dir = TempDir::new().unwrap();
        let now_ms = 1_800_000_000_000u64;
        let referenced_name = format!("{}_receipt.jpg", uuidv7_for_unix_ms(now_ms - 500 * MS_PER_DAY));
        let unused_name = format!("{}_old.jpg", uuidv7_for_unix_ms(now_ms - 10 * MS_PER_DAY));
        let non_fi_name = "vacation.jpg";
        let temp_name = format!(".fi_tmp_{}", Uuid::now_v7());

        fs::write(media_dir.path().join(&referenced_name), synthetic_jpeg()).unwrap();
        fs::write(media_dir.path().join(&unused_name), vec![1u8; 400]).unwrap();
        fs::write(media_dir.path().join(non_fi_name), vec![2u8; 900]).unwrap();
        fs::write(media_dir.path().join(&temp_name), vec![3u8; 100]).unwrap();
        fs::create_dir(media_dir.path().join(".stfolder")).unwrap();
        fs::write(media_dir.path().join(".stfolder").join(&unused_name), vec![4u8; 50]).unwrap();

        let referenced = HashSet::from([referenced_name.clone()]);
        let status = scan_media_folder(media_dir.path(), &referenced);
        assert_eq!(status.unused_file_count, 1);
        assert_eq!(status.unused_total_bytes, 400);

        let preview = preview_unused_media_cleanup_at(media_dir.path(), &referenced, 0, now_ms)
            .unwrap();
        assert_eq!(
            preview,
            UnusedMediaPreview {
                total_unused_count: 1,
                total_unused_bytes: 400,
                matching_count: 1,
                matching_bytes: 400,
            }
        );

        let result = delete_unused_media_at(media_dir.path(), &referenced, 0, now_ms).unwrap();
        assert_eq!(
            result,
            UnusedMediaCleanupResult {
                deleted_count: 1,
                freed_bytes: 400,
            }
        );

        assert!(!media_dir.path().join(&unused_name).exists());
        assert!(media_dir.path().join(&referenced_name).exists());
        assert!(media_dir.path().join(non_fi_name).exists());
        assert!(media_dir.path().join(&temp_name).exists());
        assert!(media_dir.path().join(".stfolder").join(&unused_name).exists());
    }

    #[test]
    fn unused_media_cleanup_filters_by_uuidv7_age_and_handles_clock_skew() {
        let media_dir = TempDir::new().unwrap();
        let now_ms = 1_800_000_000_000u64;
        let old_name = format!("{}_old.jpg", uuidv7_for_unix_ms(now_ms - 400 * MS_PER_DAY));
        let recent_name = format!("{}_recent.jpg", uuidv7_for_unix_ms(now_ms - 10 * MS_PER_DAY));
        let future_name = format!("{}_skew.jpg", uuidv7_for_unix_ms(now_ms + 60_000));

        fs::write(media_dir.path().join(&old_name), vec![0u8; 400]).unwrap();
        fs::write(media_dir.path().join(&recent_name), vec![0u8; 1_200]).unwrap();
        fs::write(media_dir.path().join(&future_name), vec![0u8; 200]).unwrap();

        let referenced = HashSet::new();
        let preview_365 =
            preview_unused_media_cleanup_at(media_dir.path(), &referenced, 365, now_ms).unwrap();
        assert_eq!(
            preview_365,
            UnusedMediaPreview {
                total_unused_count: 3,
                total_unused_bytes: 1_800,
                matching_count: 1,
                matching_bytes: 400,
            }
        );

        let preview_any =
            preview_unused_media_cleanup_at(media_dir.path(), &referenced, 0, now_ms).unwrap();
        assert_eq!(preview_any.matching_count, 3);
        assert_eq!(preview_any.matching_bytes, 1_800);

        let result = delete_unused_media_at(media_dir.path(), &referenced, 365, now_ms).unwrap();
        assert_eq!(
            result,
            UnusedMediaCleanupResult {
                deleted_count: 1,
                freed_bytes: 400,
            }
        );
        assert!(!media_dir.path().join(&old_name).exists());
        assert!(media_dir.path().join(&recent_name).exists());
        assert!(media_dir.path().join(&future_name).exists());
    }

    #[test]
    fn derive_original_name_strips_uuid_prefix() {
        assert_eq!(
            derive_original_name_from_relative_path(
                "0195f3a0-7c4b-7d20-8a1e-4b92c8103f1a_receipt.jpg"
            ),
            "receipt.jpg"
        );
        assert_eq!(
            derive_original_name_from_relative_path("plain_receipt.jpg"),
            "plain_receipt.jpg"
        );
    }
}
