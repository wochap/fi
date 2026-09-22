//! Complete-snapshot and bootstrap-control persistence ports and filesystem adapter.
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use async_trait::async_trait;

use crate::{
    BootstrapRecord, DocumentId,
    error::StorageError,
    recovery::{QuarantineEntry, QuarantineReason},
};

#[async_trait]
/// Atomic complete-snapshot storage. `store` installs bytes atomically; `flush`
/// is the explicit crash-durability barrier for preceding operations.
pub trait StorageAdapter: Send + Sync + 'static {
    /// Lists stored snapshot IDs without validating their contents; strict
    /// validation and classification happen in `Repo::open`.
    async fn list(&self) -> Result<Vec<DocumentId>, StorageError>;
    async fn load(&self, id: DocumentId) -> Result<Option<Vec<u8>>, StorageError>;
    async fn store(&self, id: DocumentId, snapshot: Vec<u8>) -> Result<(), StorageError>;
    async fn remove(&self, id: DocumentId) -> Result<(), StorageError>;
    async fn flush(&self) -> Result<(), StorageError>;
    async fn close(&self) -> Result<(), StorageError>;
    /// Moves (never copies or deletes) one stored snapshot into quarantine,
    /// keeping the document ID and reason determinable. Returns the location
    /// when the adapter has one, or `Ok(None)` when no snapshot was present,
    /// which makes re-entry after an interrupted quarantine idempotent.
    async fn quarantine(
        &self,
        id: DocumentId,
        reason: QuarantineReason,
    ) -> Result<Option<PathBuf>, StorageError>;
    /// Lists quarantined snapshots in deterministic order.
    async fn quarantined(&self) -> Result<Vec<QuarantineEntry>, StorageError>;
    async fn load_quarantined(&self, key: &str) -> Result<Option<Vec<u8>>, StorageError>;
    async fn discard_quarantined(&self, key: &str) -> Result<(), StorageError>;
}

#[async_trait]
/// Storage for bootstrap records, deliberately independent of document bytes.
/// A successful transition is durable only after the following `flush`.
pub trait ControlStore: Send + Sync + 'static {
    async fn load(&self) -> Result<Option<BootstrapRecord>, StorageError>;
    async fn store(&self, record: BootstrapRecord) -> Result<(), StorageError>;
    async fn flush(&self) -> Result<(), StorageError>;
    async fn close(&self) -> Result<(), StorageError>;
    /// Durable count of root-snapshot recoveries started for `root`. It is
    /// never reset by a successful recovery, so a store that keeps losing the
    /// same root escalates instead of looping.
    async fn recovery_attempts(&self, root: DocumentId) -> Result<u32, StorageError>;
    /// Increments and returns the durable recovery count for `root`.
    async fn record_recovery_attempt(&self, root: DocumentId) -> Result<u32, StorageError>;
}

/// Crash-safe filesystem implementation of both repository persistence ports.
///
/// Documents live in `automerge/<uuid>.automerge`; bootstrap state lives in
/// `control/bootstrap-v1.bin`; quarantined snapshots live in
/// `quarantine/<uuid>.<reason>[.<n>].automerge`. Files not ending in
/// `.automerge` are unrelated and ignored, except recognizable `.tmp-<hex>`
/// sibling files left by an interrupted adapter write, which are removed
/// during listing.
#[derive(Clone, Debug)]
pub struct FilesystemStorage {
    root: Arc<PathBuf>,
    documents_closed: Arc<AtomicBool>,
    control_closed: Arc<AtomicBool>,
    nonce: Arc<AtomicU64>,
}

impl FilesystemStorage {
    #[must_use]
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            root: Arc::new(path.into()),
            documents_closed: Arc::new(AtomicBool::new(false)),
            control_closed: Arc::new(AtomicBool::new(false)),
            nonce: Arc::new(AtomicU64::new(0)),
        }
    }

    pub async fn open(path: impl Into<PathBuf>) -> Result<Self, StorageError> {
        let storage = Self::new(path);
        let root = storage.root.as_ref().clone();
        blocking("open", None, None, move || {
            ensure_directory(&root)?;
            ensure_directory(&root.join("automerge"))?;
            ensure_directory(&root.join("control"))
        })
        .await?;
        Ok(storage)
    }

    #[must_use]
    pub fn root(&self) -> &Path {
        self.root.as_ref()
    }

    fn documents_dir(&self) -> PathBuf {
        self.root.join("automerge")
    }

    fn control_path(&self) -> PathBuf {
        self.root.join("control").join("bootstrap-v1.bin")
    }

    fn quarantine_dir(&self) -> PathBuf {
        self.root.join("quarantine")
    }

    fn recovery_attempts_path(&self, root: DocumentId) -> PathBuf {
        self.root
            .join("control")
            .join(format!("recovery-{root}.txt"))
    }

    fn ensure_open(
        &self,
        operation: &'static str,
        document: Option<DocumentId>,
    ) -> Result<(), StorageError> {
        let closed = if operation.starts_with("control_") {
            self.control_closed.load(Ordering::Acquire)
        } else {
            self.documents_closed.load(Ordering::Acquire)
        };
        if closed {
            Err(StorageError::new(operation, document, "adapter is closed"))
        } else {
            Ok(())
        }
    }

    fn document_path(&self, id: DocumentId) -> PathBuf {
        self.documents_dir().join(format!("{id}.automerge"))
    }

    async fn replace(
        &self,
        operation: &'static str,
        document: Option<DocumentId>,
        path: PathBuf,
        bytes: Vec<u8>,
    ) -> Result<(), StorageError> {
        self.ensure_open(operation, document)?;
        let nonce = self.nonce.fetch_add(1, Ordering::Relaxed);
        blocking(operation, document, Some(path.clone()), move || {
            atomic_replace(&path, &bytes, nonce)
        })
        .await
    }
}

async fn blocking<T: Send + 'static>(
    operation: &'static str,
    document: Option<DocumentId>,
    path: Option<PathBuf>,
    job: impl FnOnce() -> std::io::Result<T> + Send + 'static,
) -> Result<T, StorageError> {
    tokio::task::spawn_blocking(job)
        .await
        .map_err(|error| StorageError::new(operation, document, error.to_string()))?
        .map_err(|error| {
            let storage = StorageError::new(operation, document, error.to_string());
            path.map_or(storage.clone(), |path| storage.with_path(path))
        })
}

fn ensure_directory(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn atomic_replace(path: &Path, bytes: &[u8], nonce: u64) -> std::io::Result<()> {
    atomic_replace_with(path, bytes, nonce, |_| Ok(()))
}

fn atomic_replace_with(
    path: &Path,
    bytes: &[u8],
    nonce: u64,
    before_replace: impl FnOnce(&Path) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let parent = path.parent().expect("repository files have parents");
    ensure_directory(parent)?;
    let name = path
        .file_name()
        .expect("repository files have names")
        .to_string_lossy();
    let mut attempt = nonce;
    let (temporary, mut file) = loop {
        let candidate = parent.join(format!(".{name}.tmp-{attempt:016x}"));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&candidate) {
            Ok(file) => break (candidate, file),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                attempt = attempt.wrapping_add(1);
            }
            Err(error) => return Err(error),
        }
    };
    let result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        before_replace(&temporary)?;
        fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn is_stale_temp(name: &str) -> bool {
    let Some((prefix, suffix)) = name.rsplit_once(".tmp-") else {
        return false;
    };
    prefix.starts_with('.')
        && (prefix.ends_with(".automerge") || prefix == ".bootstrap-v1.bin")
        && suffix.len() == 16
        && suffix.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn encode_record(record: &BootstrapRecord) -> [u8; 24] {
    let mut bytes = [0_u8; 24];
    bytes[..4].copy_from_slice(b"FIBC");
    bytes[4..6].copy_from_slice(&1_u16.to_be_bytes());
    bytes[6] = match record {
        BootstrapRecord::Creating { .. } => 0,
        BootstrapRecord::Joining { .. } => 1,
        BootstrapRecord::Ready { .. } => 2,
    };
    bytes[8..].copy_from_slice(&record.root().to_bytes());
    bytes
}

fn decode_record(path: &Path, bytes: &[u8]) -> Result<BootstrapRecord, StorageError> {
    let invalid = |field: &str| {
        StorageError::new("control_load", None, format!("invalid bootstrap {field}"))
            .with_path(path)
    };
    if bytes.len() != 24 {
        return Err(invalid("length"));
    }
    if &bytes[..4] != b"FIBC" {
        return Err(invalid("magic"));
    }
    if u16::from_be_bytes([bytes[4], bytes[5]]) != 1 {
        return Err(invalid("version"));
    }
    if bytes[7] != 0 {
        return Err(invalid("reserved byte"));
    }
    let mut id = [0_u8; 16];
    id.copy_from_slice(&bytes[8..]);
    let root = DocumentId::from_bytes(id);
    match bytes[6] {
        0 => Ok(BootstrapRecord::Creating { root }),
        1 => Ok(BootstrapRecord::Joining { root }),
        2 => Ok(BootstrapRecord::Ready { root }),
        _ => Err(invalid("state")),
    }
}

#[async_trait]
impl StorageAdapter for FilesystemStorage {
    async fn list(&self) -> Result<Vec<DocumentId>, StorageError> {
        self.ensure_open("list", None)?;
        let directory = self.documents_dir();
        blocking("list", None, Some(directory.clone()), move || {
            ensure_directory(&directory)?;
            let mut ids = Vec::new();
            for entry in fs::read_dir(&directory)? {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if is_stale_temp(&name) {
                    if entry.file_type()?.is_file() {
                        fs::remove_file(entry.path())?;
                    }
                    continue;
                }
                if !name.ends_with(".automerge") {
                    continue;
                }
                let stem = name.strip_suffix(".automerge").unwrap();
                let id: DocumentId = stem.parse().map_err(|_| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!("malformed snapshot filename: {}", entry.path().display()),
                    )
                })?;
                if id.to_string() != stem {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!("noncanonical snapshot filename: {}", entry.path().display()),
                    ));
                }
                ids.push(id);
            }
            ids.sort();
            Ok(ids)
        })
        .await
    }

    async fn load(&self, id: DocumentId) -> Result<Option<Vec<u8>>, StorageError> {
        self.ensure_open("load", Some(id))?;
        let path = self.document_path(id);
        blocking(
            "load",
            Some(id),
            Some(path.clone()),
            move || match fs::read(&path) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error),
            },
        )
        .await
    }

    async fn store(&self, id: DocumentId, snapshot: Vec<u8>) -> Result<(), StorageError> {
        self.replace("store", Some(id), self.document_path(id), snapshot)
            .await
    }

    async fn remove(&self, id: DocumentId) -> Result<(), StorageError> {
        self.ensure_open("remove", Some(id))?;
        let path = self.document_path(id);
        blocking(
            "remove",
            Some(id),
            Some(path.clone()),
            move || match fs::remove_file(path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error),
            },
        )
        .await
    }

    async fn quarantine(
        &self,
        id: DocumentId,
        reason: QuarantineReason,
    ) -> Result<Option<PathBuf>, StorageError> {
        self.ensure_open("quarantine", Some(id))?;
        let source = self.document_path(id);
        let directory = self.quarantine_dir();
        blocking("quarantine", Some(id), Some(source.clone()), move || {
            quarantine_file(&source, &directory, id, reason)
        })
        .await
    }

    async fn quarantined(&self) -> Result<Vec<QuarantineEntry>, StorageError> {
        self.ensure_open("quarantine_list", None)?;
        let directory = self.quarantine_dir();
        blocking(
            "quarantine_list",
            None,
            Some(directory.clone()),
            move || list_quarantine(&directory),
        )
        .await
    }

    async fn load_quarantined(&self, key: &str) -> Result<Option<Vec<u8>>, StorageError> {
        self.ensure_open("quarantine_load", None)?;
        let path = quarantine_key_path(&self.quarantine_dir(), key)
            .map_err(|error| StorageError::new("quarantine_load", None, error.to_string()))?;
        blocking(
            "quarantine_load",
            None,
            Some(path.clone()),
            move || match fs::read(&path) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error),
            },
        )
        .await
    }

    async fn discard_quarantined(&self, key: &str) -> Result<(), StorageError> {
        self.ensure_open("quarantine_discard", None)?;
        let path = quarantine_key_path(&self.quarantine_dir(), key)
            .map_err(|error| StorageError::new("quarantine_discard", None, error.to_string()))?;
        blocking(
            "quarantine_discard",
            None,
            Some(path.clone()),
            move || match fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(error),
            },
        )
        .await
    }

    async fn flush(&self) -> Result<(), StorageError> {
        self.ensure_open("document_flush", None)?;
        let path = self.documents_dir();
        blocking("document_flush", None, Some(path.clone()), move || {
            ensure_directory(&path)?;
            File::open(path)?.sync_all()
        })
        .await
    }

    async fn close(&self) -> Result<(), StorageError> {
        // The same cloneable concrete value may back both repository ports;
        // closing either view is therefore deliberately idempotent and does
        // not invalidate the other view while shutdown is still progressing.
        self.documents_closed.store(true, Ordering::Release);
        Ok(())
    }
}

#[async_trait]
impl ControlStore for FilesystemStorage {
    async fn load(&self) -> Result<Option<BootstrapRecord>, StorageError> {
        self.ensure_open("control_load", None)?;
        let path = self.control_path();
        let loaded = blocking(
            "control_load",
            None,
            Some(path.clone()),
            move || match fs::read(&path) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(error),
            },
        )
        .await?;
        loaded
            .map(|bytes| decode_record(&self.control_path(), &bytes))
            .transpose()
    }

    async fn store(&self, record: BootstrapRecord) -> Result<(), StorageError> {
        self.replace(
            "control_store",
            None,
            self.control_path(),
            encode_record(&record).to_vec(),
        )
        .await
    }

    async fn flush(&self) -> Result<(), StorageError> {
        self.ensure_open("control_flush", None)?;
        let path = self.root.join("control");
        blocking("control_flush", None, Some(path.clone()), move || {
            ensure_directory(&path)?;
            File::open(path)?.sync_all()
        })
        .await
    }

    async fn close(&self) -> Result<(), StorageError> {
        self.control_closed.store(true, Ordering::Release);
        Ok(())
    }

    async fn recovery_attempts(&self, root: DocumentId) -> Result<u32, StorageError> {
        self.ensure_open("control_recovery_load", Some(root))?;
        let path = self.recovery_attempts_path(root);
        blocking(
            "control_recovery_load",
            Some(root),
            Some(path.clone()),
            move || read_recovery_attempts(&path),
        )
        .await
    }

    async fn record_recovery_attempt(&self, root: DocumentId) -> Result<u32, StorageError> {
        self.ensure_open("control_recovery_store", Some(root))?;
        let path = self.recovery_attempts_path(root);
        let nonce = self.nonce.fetch_add(1, Ordering::Relaxed);
        blocking(
            "control_recovery_store",
            Some(root),
            Some(path.clone()),
            move || {
                let next = read_recovery_attempts(&path)?.saturating_add(1);
                atomic_replace(&path, next.to_string().as_bytes(), nonce)?;
                Ok(next)
            },
        )
        .await
    }
}

fn read_recovery_attempts(path: &Path) -> std::io::Result<u32> {
    match fs::read_to_string(path) {
        Ok(text) => text.trim().parse().map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("malformed recovery counter {}", path.display()),
            )
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(error) => Err(error),
    }
}

/// Quarantine file names are `<uuid>.<reason>[.<n>].automerge`; the key is the
/// file name. Only names inside `directory` are ever resolved.
pub fn quarantine_key_path(directory: &Path, key: &str) -> std::io::Result<PathBuf> {
    if parse_quarantine_name(key).is_none() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("malformed quarantine key {key}"),
        ));
    }
    Ok(directory.join(key))
}

fn parse_quarantine_name(name: &str) -> Option<(DocumentId, QuarantineReason)> {
    let stem = name.strip_suffix(".automerge")?;
    let mut parts = stem.split('.');
    let id: DocumentId = parts.next()?.parse().ok()?;
    let reason = QuarantineReason::parse(parts.next()?)?;
    if let Some(counter) = parts.next()
        && (counter.is_empty() || !counter.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return None;
    }
    if parts.next().is_some() {
        return None;
    }
    Some((id, reason))
}

/// Moves `source` into `directory` under a unique quarantine name. A rename
/// within the application directory is atomic, so an interruption leaves the
/// bytes at exactly one of the two locations.
pub fn quarantine_file(
    source: &Path,
    directory: &Path,
    id: DocumentId,
    reason: QuarantineReason,
) -> std::io::Result<Option<PathBuf>> {
    if !source.exists() {
        return Ok(None);
    }
    ensure_directory(directory)?;
    let mut counter = 0_u32;
    let destination = loop {
        let name = if counter == 0 {
            format!("{id}.{reason}.automerge")
        } else {
            format!("{id}.{reason}.{counter}.automerge")
        };
        let candidate = directory.join(name);
        if !candidate.exists() {
            break candidate;
        }
        counter += 1;
    };
    fs::rename(source, &destination)?;
    File::open(directory)?.sync_all()?;
    if let Some(parent) = source.parent() {
        File::open(parent)?.sync_all()?;
    }
    Ok(Some(destination))
}

/// Lists `directory` as quarantine entries, ignoring unrelated files. A
/// missing directory is an empty quarantine.
pub fn list_quarantine(directory: &Path) -> std::io::Result<Vec<QuarantineEntry>> {
    let mut entries = Vec::new();
    let read = match fs::read_dir(directory) {
        Ok(read) => read,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(entries),
        Err(error) => return Err(error),
    };
    for entry in read {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some((document, reason)) = parse_quarantine_name(&name) else {
            continue;
        };
        entries.push(QuarantineEntry {
            key: name,
            document,
            reason,
            location: Some(entry.path()),
        });
    }
    entries.sort_by(|a, b| (a.document, a.reason, &a.key).cmp(&(b.document, b.reason, &b.key)));
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failure_before_rename_preserves_destination_and_cleans_temp() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("value.automerge");
        fs::write(&path, b"old").unwrap();
        let result = atomic_replace_with(&path, b"new", 0, |temporary| {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(fs::metadata(temporary)?.permissions().mode() & 0o777, 0o600);
            }
            Err(std::io::Error::other("injected before rename"))
        });
        assert!(result.is_err());
        assert_eq!(fs::read(&path).unwrap(), b"old");
        assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn control_codec_rejects_every_reserved_field() {
        let root = DocumentId::new();
        let path = Path::new("bootstrap-v1.bin");
        let record = BootstrapRecord::Ready { root };
        let valid = encode_record(&record);
        assert_eq!(decode_record(path, &valid).unwrap(), record);
        for index in [0_usize, 4, 6, 7] {
            let mut invalid = valid;
            invalid[index] ^= 0xff;
            assert!(decode_record(path, &invalid).is_err());
        }
        assert!(decode_record(path, &valid[..23]).is_err());
    }
}
