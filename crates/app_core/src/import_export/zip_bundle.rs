//! Minimal, zero-dependency PKZIP (Stored / method 0) reader and writer for Fi `.zip` media
//! bundles containing `collections.json` and referenced image files at their single-segment
//! `relative_path`.

use std::{collections::BTreeSet, fs, io::Write, path::Path};

use uuid::Uuid;

use super::{Envelope, ImportAbort};
use crate::{
    error::DomainError,
    values::{FieldValue, ImageAttachment},
};

const LOCAL_FILE_HEADER_SIG: u32 = 0x0403_4b50;
const CENTRAL_DIR_HEADER_SIG: u32 = 0x0201_4b50;
const EOCD_SIG: u32 = 0x0605_4b50;
const UTF8_FLAG: u16 = 0x0800;

/// Summary of unique image files referenced by an [`Envelope`] compared against the local Media
/// Folder.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ReferencedMediaSummary {
    pub total_referenced: usize,
    pub present_count: usize,
    pub present_bytes: u64,
    pub missing_count: usize,
}

/// Decoded contents of a Fi `.zip` media bundle prior to committing or extracting files.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParsedZipBundle {
    pub envelope: Envelope,
    pub media_entries: Vec<(String, Vec<u8>)>,
}

/// Collects all unique `relative_path` values referenced by `Images` fields in `envelope`.
#[must_use]
pub fn collect_envelope_media_paths(envelope: &Envelope) -> BTreeSet<String> {
    let mut paths = BTreeSet::new();
    for collection in &envelope.collections {
        for record in &collection.records {
            for value in record.values.values() {
                if let FieldValue::Images(attachments) = value {
                    for attachment in attachments {
                        paths.insert(attachment.relative_path.clone());
                    }
                }
            }
        }
    }
    paths
}

/// Counts referenced image files in `envelope` that are present vs. missing in `media_folder`.
#[must_use]
pub fn summarize_envelope_media(
    envelope: &Envelope,
    media_folder: Option<&Path>,
) -> ReferencedMediaSummary {
    let paths = collect_envelope_media_paths(envelope);
    let mut summary = ReferencedMediaSummary {
        total_referenced: paths.len(),
        present_count: 0,
        present_bytes: 0,
        missing_count: 0,
    };
    for path in paths {
        if let Some(dir) = media_folder
            && ImageAttachment::is_valid_relative_path(&path)
            && let Ok(meta) = fs::metadata(dir.join(&path))
            && meta.is_file()
        {
            summary.present_count += 1;
            summary.present_bytes = summary.present_bytes.saturating_add(meta.len());
        } else {
            summary.missing_count += 1;
        }
    }
    summary
}

/// Builds a `.zip` media bundle containing `collections.json` plus every locally present
/// referenced image file from `media_folder`. Returns `(zip_bytes, media_included, media_missing)`.
pub fn build_zip_bundle(
    envelope: &Envelope,
    media_folder: Option<&Path>,
) -> Result<(Vec<u8>, usize, usize), DomainError> {
    let json = envelope.to_json()?;
    let paths = collect_envelope_media_paths(envelope);

    let mut owned_entries: Vec<(String, Vec<u8>)> = Vec::with_capacity(1 + paths.len());
    owned_entries.push(("collections.json".to_string(), json.into_bytes()));

    let mut media_included = 0usize;
    let mut media_missing = 0usize;

    for path in paths {
        if let Some(dir) = media_folder
            && ImageAttachment::is_valid_relative_path(&path)
            && let Ok(bytes) = fs::read(dir.join(&path))
        {
            owned_entries.push((path, bytes));
            media_included += 1;
        } else {
            media_missing += 1;
        }
    }

    let refs: Vec<(&str, &[u8])> = owned_entries
        .iter()
        .map(|(name, data)| (name.as_str(), data.as_slice()))
        .collect();
    let zip_bytes = write_zip_stored(&refs)?;
    Ok((zip_bytes, media_included, media_missing))
}

/// Parses and validates a Fi `.zip` media bundle without touching the filesystem.
/// Rejects zip-slip paths or archives missing a valid `collections.json`.
pub fn parse_zip_bundle(zip_bytes: &[u8]) -> Result<ParsedZipBundle, ImportAbort> {
    let entries = read_zip_stored(zip_bytes)?;
    let mut collections_json: Option<String> = None;
    let mut media_entries = Vec::new();

    for (name, data) in entries {
        if name == "collections.json" {
            let text = String::from_utf8(data).map_err(|_| {
                ImportAbort::envelope("collections.json inside .zip is not valid UTF-8")
            })?;
            collections_json = Some(text);
        } else {
            if !ImageAttachment::is_valid_relative_path(&name) {
                return Err(ImportAbort::envelope(format!(
                    "unsafe or unsupported media entry \"{name}\" in .zip archive"
                )));
            }
            media_entries.push((name, data));
        }
    }

    let json = collections_json
        .ok_or_else(|| ImportAbort::envelope("missing collections.json in .zip archive"))?;
    let envelope = Envelope::parse(&json)?;

    Ok(ParsedZipBundle {
        envelope,
        media_entries,
    })
}

/// Extracts bundled media entries into `media_folder` without overwriting existing files.
/// Returns the number of newly written files.
pub fn extract_bundle_media(
    media_entries: &[(String, Vec<u8>)],
    media_folder: &Path,
) -> Result<usize, std::io::Error> {
    let mut extracted = 0usize;
    for (name, data) in media_entries {
        if !ImageAttachment::is_valid_relative_path(name) {
            continue;
        }
        let target = media_folder.join(name);
        if target.exists() {
            continue;
        }
        let temp = media_folder.join(format!(".fi_tmp_{}", Uuid::now_v7()));
        let write_result = (|| -> Result<(), std::io::Error> {
            let mut file = fs::File::create(&temp)?;
            file.write_all(data)?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temp, &target)?;
            Ok(())
        })();
        if let Err(err) = write_result {
            let _ = fs::remove_file(&temp);
            return Err(err);
        }
        extracted += 1;
    }
    Ok(extracted)
}

fn write_zip_stored(entries: &[(&str, &[u8])]) -> Result<Vec<u8>, DomainError> {
    if entries.len() > usize::from(u16::MAX) {
        return Err(DomainError::Invalid {
            field: "export",
            message: "too many files for a single .zip archive".into(),
        });
    }

    let mut out = Vec::new();
    let mut central_records: Vec<(&[u8], u32, u32, u32)> = Vec::with_capacity(entries.len());

    for &(name, data) in entries {
        let name_bytes = name.as_bytes();
        let name_len = u16::try_from(name_bytes.len()).map_err(|_| DomainError::Invalid {
            field: "export",
            message: "filename too long for .zip archive".into(),
        })?;
        let data_len = u32::try_from(data.len()).map_err(|_| DomainError::Invalid {
            field: "export",
            message: "file exceeds 4 GiB .zip entry limit".into(),
        })?;
        let local_offset = u32::try_from(out.len()).map_err(|_| DomainError::Invalid {
            field: "export",
            message: "archive exceeds 4 GiB .zip limit".into(),
        })?;
        let checksum = crc32(data);

        // Local file header (30 bytes + name)
        out.extend_from_slice(&LOCAL_FILE_HEADER_SIG.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed (2.0)
        out.extend_from_slice(&UTF8_FLAG.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // compression method 0 (Stored)
        out.extend_from_slice(&0u16.to_le_bytes()); // mod time
        out.extend_from_slice(&0u16.to_le_bytes()); // mod date
        out.extend_from_slice(&checksum.to_le_bytes());
        out.extend_from_slice(&data_len.to_le_bytes());
        out.extend_from_slice(&data_len.to_le_bytes());
        out.extend_from_slice(&name_len.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra field length
        out.extend_from_slice(name_bytes);
        out.extend_from_slice(data);

        central_records.push((name_bytes, checksum, data_len, local_offset));
    }

    let central_start = u32::try_from(out.len()).map_err(|_| DomainError::Invalid {
        field: "export",
        message: "archive exceeds 4 GiB .zip limit".into(),
    })?;

    for (name_bytes, checksum, data_len, local_offset) in &central_records {
        let name_len = u16::try_from(name_bytes.len()).unwrap_or(0);
        // Central directory header (46 bytes + name)
        out.extend_from_slice(&CENTRAL_DIR_HEADER_SIG.to_le_bytes());
        out.extend_from_slice(&20u16.to_le_bytes()); // version made by
        out.extend_from_slice(&20u16.to_le_bytes()); // version needed
        out.extend_from_slice(&UTF8_FLAG.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // Stored
        out.extend_from_slice(&0u16.to_le_bytes()); // mod time
        out.extend_from_slice(&0u16.to_le_bytes()); // mod date
        out.extend_from_slice(&checksum.to_le_bytes());
        out.extend_from_slice(&data_len.to_le_bytes());
        out.extend_from_slice(&data_len.to_le_bytes());
        out.extend_from_slice(&name_len.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes()); // extra len
        out.extend_from_slice(&0u16.to_le_bytes()); // comment len
        out.extend_from_slice(&0u16.to_le_bytes()); // disk number start
        out.extend_from_slice(&0u16.to_le_bytes()); // internal attrs
        out.extend_from_slice(&0u32.to_le_bytes()); // external attrs
        out.extend_from_slice(&local_offset.to_le_bytes());
        out.extend_from_slice(name_bytes);
    }

    let central_size = u32::try_from(out.len()).map_err(|_| DomainError::Invalid {
        field: "export",
        message: "archive exceeds 4 GiB .zip limit".into(),
    })? - central_start;
    let count = u16::try_from(central_records.len()).unwrap_or(u16::MAX);

    // End of central directory record (22 bytes)
    out.extend_from_slice(&EOCD_SIG.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // disk number
    out.extend_from_slice(&0u16.to_le_bytes()); // start disk
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&count.to_le_bytes());
    out.extend_from_slice(&central_size.to_le_bytes());
    out.extend_from_slice(&central_start.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes()); // comment length

    Ok(out)
}

fn read_zip_stored(bytes: &[u8]) -> Result<Vec<(String, Vec<u8>)>, ImportAbort> {
    if bytes.len() < 22 {
        return Err(ImportAbort::envelope("not a valid .zip archive"));
    }
    // Search backwards for End of Central Directory signature within the last 65557 bytes.
    let search_start = bytes.len().saturating_sub(22 + usize::from(u16::MAX));
    let mut eocd_pos = None;
    for pos in (search_start..=bytes.len() - 22).rev() {
        if read_u32(bytes, pos) == Some(EOCD_SIG) {
            let comment_len = usize::from(read_u16(bytes, pos + 20).unwrap_or(0));
            if pos + 22 + comment_len == bytes.len() {
                eocd_pos = Some(pos);
                break;
            }
        }
    }
    let eocd = eocd_pos.ok_or_else(|| ImportAbort::envelope("not a valid .zip archive"))?;
    let entry_count = usize::from(read_u16(bytes, eocd + 10).unwrap_or(0));
    let cd_size = read_u32(bytes, eocd + 12).unwrap_or(0) as usize;
    let cd_offset = read_u32(bytes, eocd + 16).unwrap_or(0) as usize;
    if cd_offset.checked_add(cd_size).is_none_or(|end| end > eocd) {
        return Err(ImportAbort::envelope("corrupt .zip central directory"));
    }

    let mut out = Vec::with_capacity(entry_count);
    let mut cursor = cd_offset;
    for _ in 0..entry_count {
        if cursor + 46 > cd_offset + cd_size
            || read_u32(bytes, cursor) != Some(CENTRAL_DIR_HEADER_SIG)
        {
            return Err(ImportAbort::envelope(
                "corrupt .zip central directory entry",
            ));
        }
        let method = read_u16(bytes, cursor + 10).unwrap_or(u16::MAX);
        let expected_crc = read_u32(bytes, cursor + 16).unwrap_or(0);
        let comp_size = read_u32(bytes, cursor + 20).unwrap_or(0) as usize;
        let uncomp_size = read_u32(bytes, cursor + 24).unwrap_or(0) as usize;
        let name_len = usize::from(read_u16(bytes, cursor + 28).unwrap_or(0));
        let extra_len = usize::from(read_u16(bytes, cursor + 30).unwrap_or(0));
        let comment_len = usize::from(read_u16(bytes, cursor + 32).unwrap_or(0));
        let local_offset = read_u32(bytes, cursor + 42).unwrap_or(0) as usize;

        let name_start = cursor + 46;
        let name_end = name_start + name_len;
        if name_end + extra_len + comment_len > cd_offset + cd_size {
            return Err(ImportAbort::envelope(
                "truncated .zip central directory entry",
            ));
        }
        let name = std::str::from_utf8(&bytes[name_start..name_end])
            .map_err(|_| ImportAbort::envelope("non-UTF-8 filename in .zip archive"))?
            .to_string();
        cursor = name_end + extra_len + comment_len;

        if method != 0 {
            return Err(ImportAbort::envelope(format!(
                "unsupported .zip compression method {method} for \"{name}\"; only Stored (uncompressed) Fi bundles are supported"
            )));
        }
        if comp_size != uncomp_size {
            return Err(ImportAbort::envelope("corrupt .zip entry size"));
        }

        if local_offset + 30 > bytes.len()
            || read_u32(bytes, local_offset) != Some(LOCAL_FILE_HEADER_SIG)
        {
            return Err(ImportAbort::envelope("corrupt .zip local file header"));
        }
        let local_name_len = usize::from(read_u16(bytes, local_offset + 26).unwrap_or(0));
        let local_extra_len = usize::from(read_u16(bytes, local_offset + 28).unwrap_or(0));
        let data_start = local_offset + 30 + local_name_len + local_extra_len;
        let Some(data_end) = data_start.checked_add(comp_size) else {
            return Err(ImportAbort::envelope("corrupt .zip entry offset"));
        };
        if data_end > bytes.len() {
            return Err(ImportAbort::envelope("truncated .zip entry data"));
        }
        let data = bytes[data_start..data_end].to_vec();
        if crc32(&data) != expected_crc {
            return Err(ImportAbort::envelope(format!(
                "checksum mismatch for \"{name}\" in .zip archive"
            )));
        }
        out.push((name, data));
    }

    Ok(out)
}

fn read_u16(bytes: &[u8], offset: usize) -> Option<u16> {
    let slice: [u8; 2] = bytes.get(offset..offset + 2)?.try_into().ok()?;
    Some(u16::from_le_bytes(slice))
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    let slice: [u8; 4] = bytes.get(offset..offset + 4)?.try_into().ok()?;
    Some(u32::from_le_bytes(slice))
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}
