use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    str::FromStr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

use async_trait::async_trait;
use automerge_repo::{
    BootstrapRecord, DocumentId, PeerId, QuarantineEntry, QuarantineReason,
    error::{NetworkError, StorageError},
    network::{NetworkEvent, NetworkTransport},
    storage::{
        ControlStore, StorageAdapter, list_quarantine, quarantine_file, quarantine_key_path,
    },
};
use bytes::Bytes;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use tokio::sync::mpsc;

use crate::{
    control::{
        DiscoveryGroupMetadata, DiscoveryRotationJournal, DiscoveryRotationStage,
        LocalIdentityRecord, PairingJournalRecord, PairingJournalStage, PeerConnectionMetadata,
        PeerTrustRecord, ResetIntent, TrustState, TrustedDeviceRecord,
    },
    identity::{DeviceId, PublicDeviceKey},
    routing::{ConnectionFailure, PeerConnectionState},
};

type TrustedDeviceRow = (Vec<u8>, String, i64, Option<i64>, Option<i64>, String);

fn storage_error(
    operation: &'static str,
    document: Option<DocumentId>,
    path: &Path,
    error: impl std::fmt::Display,
) -> StorageError {
    StorageError::new(operation, document, error.to_string()).with_path(path)
}

async fn blocking<T: Send + 'static>(
    operation: &'static str,
    document: Option<DocumentId>,
    path: PathBuf,
    job: impl FnOnce() -> std::io::Result<T> + Send + 'static,
) -> Result<T, StorageError> {
    tokio::task::spawn_blocking(job)
        .await
        .map_err(|e| storage_error(operation, document, &path, e))?
        .map_err(|e| storage_error(operation, document, &path, e))
}

fn ensure_private_dir(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Private complete-snapshot adapter rooted exactly at `automerge/documents`,
/// with quarantine at the sibling `quarantine` directory. The quarantine
/// directory is created lazily on first use.
#[derive(Clone, Debug)]
pub(crate) struct FileDocumentStore {
    directory: Arc<PathBuf>,
    quarantine: Arc<PathBuf>,
    closed: Arc<AtomicBool>,
    nonce: Arc<AtomicU64>,
}

impl FileDocumentStore {
    pub async fn open(directory: PathBuf, quarantine: PathBuf) -> Result<Self, StorageError> {
        let path = directory.clone();
        blocking("open", None, path.clone(), move || {
            ensure_private_dir(&path)
        })
        .await?;
        Ok(Self {
            directory: Arc::new(directory),
            quarantine: Arc::new(quarantine),
            closed: Arc::new(AtomicBool::new(false)),
            nonce: Arc::new(AtomicU64::new(0)),
        })
    }
    fn path(&self, id: DocumentId) -> PathBuf {
        self.directory.join(format!("{id}.automerge"))
    }
    fn ensure_open(
        &self,
        operation: &'static str,
        id: Option<DocumentId>,
    ) -> Result<(), StorageError> {
        if self.closed.load(Ordering::Acquire) {
            Err(storage_error(
                operation,
                id,
                &self.directory,
                "adapter is closed",
            ))
        } else {
            Ok(())
        }
    }
}

#[async_trait]
impl StorageAdapter for FileDocumentStore {
    async fn list(&self) -> Result<Vec<DocumentId>, StorageError> {
        self.ensure_open("list", None)?;
        let directory = self.directory.as_ref().clone();
        blocking("list", None, directory.clone(), move || {
            ensure_private_dir(&directory)?;
            let mut ids = Vec::new();
            for entry in fs::read_dir(&directory)? {
                let entry = entry?;
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') && name.contains(".tmp-") {
                    if entry.file_type()?.is_file() {
                        fs::remove_file(entry.path())?;
                    }
                    continue;
                }
                let Some(stem) = name.strip_suffix(".automerge") else {
                    continue;
                };
                let id = DocumentId::from_str(stem)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
                if id.to_string() != stem {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "noncanonical snapshot filename",
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
        let path = self.path(id);
        blocking("load", Some(id), path.clone(), move || {
            match fs::read(&path) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(e),
            }
        })
        .await
    }

    async fn store(&self, id: DocumentId, snapshot: Vec<u8>) -> Result<(), StorageError> {
        self.ensure_open("store", Some(id))?;
        let path = self.path(id);
        let nonce = self.nonce.fetch_add(1, Ordering::Relaxed);
        blocking("store", Some(id), path.clone(), move || {
            let parent = path.parent().expect("snapshot has parent");
            ensure_private_dir(parent)?;
            let temporary = parent.join(format!(
                ".{}.tmp-{nonce:016x}",
                path.file_name().unwrap().to_string_lossy()
            ));
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let result = (|| {
                let mut file = options.open(&temporary)?;
                file.write_all(&snapshot)?;
                file.sync_all()?;
                drop(file);
                fs::rename(&temporary, &path)?;
                File::open(parent)?.sync_all()
            })();
            if result.is_err() {
                let _ = fs::remove_file(&temporary);
            }
            result
        })
        .await
    }

    async fn remove(&self, id: DocumentId) -> Result<(), StorageError> {
        self.ensure_open("remove", Some(id))?;
        let path = self.path(id);
        blocking(
            "remove",
            Some(id),
            path.clone(),
            move || match fs::remove_file(path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e),
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
        let source = self.path(id);
        let directory = self.quarantine.as_ref().clone();
        blocking("quarantine", Some(id), source.clone(), move || {
            quarantine_file(&source, &directory, id, reason)
        })
        .await
    }

    async fn quarantined(&self) -> Result<Vec<QuarantineEntry>, StorageError> {
        self.ensure_open("quarantine_list", None)?;
        let directory = self.quarantine.as_ref().clone();
        blocking("quarantine_list", None, directory.clone(), move || {
            list_quarantine(&directory)
        })
        .await
    }

    async fn load_quarantined(&self, key: &str) -> Result<Option<Vec<u8>>, StorageError> {
        self.ensure_open("quarantine_load", None)?;
        let path = quarantine_key_path(&self.quarantine, key)
            .map_err(|e| storage_error("quarantine_load", None, &self.quarantine, e))?;
        blocking(
            "quarantine_load",
            None,
            path.clone(),
            move || match fs::read(&path) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(e),
            },
        )
        .await
    }

    async fn discard_quarantined(&self, key: &str) -> Result<(), StorageError> {
        self.ensure_open("quarantine_discard", None)?;
        let path = quarantine_key_path(&self.quarantine, key)
            .map_err(|e| storage_error("quarantine_discard", None, &self.quarantine, e))?;
        blocking(
            "quarantine_discard",
            None,
            path.clone(),
            move || match fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e),
            },
        )
        .await
    }

    async fn flush(&self) -> Result<(), StorageError> {
        self.ensure_open("document_flush", None)?;
        let directory = self.directory.as_ref().clone();
        blocking("document_flush", None, directory.clone(), move || {
            ensure_private_dir(&directory)?;
            File::open(directory)?.sync_all()
        })
        .await
    }

    async fn close(&self) -> Result<(), StorageError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

/// SQLite implementation of the repository bootstrap-control port.
pub struct SqliteControlStore {
    path: PathBuf,
    connection: Mutex<Connection>,
    closed: AtomicBool,
}

impl std::fmt::Debug for SqliteControlStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SqliteControlStore")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

/// One pairing-journal row as SQLite returns it: the key column (session id or
/// peer id, depending on the query), stage, joining root, failure reason and
/// timestamp.
type PairingJournalRow<Key> = (Key, String, Option<String>, Option<String>, i64);

impl SqliteControlStore {
    pub fn open(path: PathBuf) -> Result<Self, StorageError> {
        if let Some(parent) = path.parent() {
            ensure_private_dir(parent)
                .map_err(|e| storage_error("control_open", None, &path, e))?;
        }
        let connection =
            Connection::open(&path).map_err(|e| storage_error("control_open", None, &path, e))?;
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| storage_error("control_open", None, &path, e))?;
        connection
            .pragma_update(None, "synchronous", "FULL")
            .map_err(|e| storage_error("control_open", None, &path, e))?;
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS app_control (
                key TEXT PRIMARY KEY, version INTEGER NOT NULL, state TEXT NOT NULL, root TEXT NOT NULL
             ) STRICT;
             CREATE TABLE IF NOT EXISTS local_identity (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                device_id TEXT NOT NULL UNIQUE, public_key BLOB NOT NULL CHECK(length(public_key) = 32),
                created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS trusted_peers (
                device_id TEXT PRIMARY KEY, public_key BLOB NOT NULL CHECK(length(public_key) = 32),
                trust_state TEXT NOT NULL CHECK(trust_state IN ('trusted', 'revoked')),
                updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0), last_seen_ms INTEGER
             ) STRICT;
             CREATE TABLE IF NOT EXISTS peer_connections (
                device_id TEXT PRIMARY KEY, state TEXT NOT NULL, error_category TEXT,
                endpoint TEXT, updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS trusted_devices (
                device_id TEXT PRIMARY KEY, public_key BLOB NOT NULL CHECK(length(public_key) = 32),
                friendly_name TEXT NOT NULL, paired_at_ms INTEGER NOT NULL CHECK(paired_at_ms >= 0),
                last_seen_ms INTEGER, last_sync_ms INTEGER,
                trust_state TEXT NOT NULL CHECK(trust_state IN ('trusted', 'revoked'))
             ) STRICT;
             CREATE TABLE IF NOT EXISTS pairing_journal (
                session_id BLOB PRIMARY KEY CHECK(length(session_id) = 16),
                peer_device_id TEXT NOT NULL, stage TEXT NOT NULL,
                joining_root TEXT, failure_reason TEXT,
                updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS discovery_group (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                version INTEGER NOT NULL CHECK(version = 1), epoch INTEGER NOT NULL CHECK(epoch > 0),
                updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS discovery_rotation (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                version INTEGER NOT NULL CHECK(version = 1),
                previous_epoch INTEGER NOT NULL CHECK(previous_epoch > 0),
                target_epoch INTEGER NOT NULL CHECK(target_epoch > previous_epoch),
                retain_until_ms INTEGER NOT NULL CHECK(retain_until_ms >= 0),
                stage TEXT NOT NULL CHECK(stage IN ('prepared', 'active')),
                updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS reset_intent (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                version INTEGER NOT NULL CHECK(version = 1),
                requested_at_ms INTEGER NOT NULL CHECK(requested_at_ms >= 0)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS recovery_attempts (
                root TEXT PRIMARY KEY, attempts INTEGER NOT NULL CHECK(attempts >= 0)
             ) STRICT;",
        )
            .map_err(|e| storage_error("control_open", None, &path, e))?;
        Ok(Self {
            path,
            connection: Mutex::new(connection),
            closed: AtomicBool::new(false),
        })
    }
    fn ensure_open(&self, operation: &'static str) -> Result<(), StorageError> {
        if self.closed.load(Ordering::Acquire) {
            Err(storage_error(
                operation,
                None,
                &self.path,
                "adapter is closed",
            ))
        } else {
            Ok(())
        }
    }

    pub fn store_local_identity(&self, record: &LocalIdentityRecord) -> Result<(), StorageError> {
        self.ensure_open("identity_store")?;
        if DeviceId::from_public_key(record.public_key.as_bytes()) != record.device_id {
            return Err(storage_error(
                "identity_store",
                None,
                &self.path,
                "public key does not match device id",
            ));
        }
        let created_at_ms = i64::try_from(record.created_at_ms).map_err(|_| {
            storage_error(
                "identity_store",
                None,
                &self.path,
                "timestamp is out of range",
            )
        })?;
        self.connection.lock().map_err(|_| storage_error("identity_store", None, &self.path, "connection lock poisoned"))?
            .execute(
                "INSERT INTO local_identity(singleton, device_id, public_key, created_at_ms) VALUES(1, ?1, ?2, ?3)
                 ON CONFLICT(singleton) DO UPDATE SET device_id=excluded.device_id, public_key=excluded.public_key, created_at_ms=excluded.created_at_ms",
                params![record.device_id.to_string(), record.public_key.as_bytes().as_slice(), created_at_ms],
            )
            .map(|_| ())
            .map_err(|error| storage_error("identity_store", None, &self.path, error))
    }

    pub fn load_local_identity(&self) -> Result<Option<LocalIdentityRecord>, StorageError> {
        self.ensure_open("identity_load")?;
        let row: Option<(String, Vec<u8>, i64)> = self
            .connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "identity_load",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .query_row(
                "SELECT device_id, public_key, created_at_ms FROM local_identity WHERE singleton=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|error| storage_error("identity_load", None, &self.path, error))?;
        row.map(|(id, key, created)| {
            let device_id = id.parse().map_err(|_| {
                storage_error("identity_load", None, &self.path, "malformed device id")
            })?;
            let bytes: [u8; 32] = key.try_into().map_err(|_| {
                storage_error(
                    "identity_load",
                    None,
                    &self.path,
                    "malformed public key length",
                )
            })?;
            let public_key = PublicDeviceKey::from_bytes(bytes).map_err(|_| {
                storage_error("identity_load", None, &self.path, "malformed public key")
            })?;
            if DeviceId::from_public_key(public_key.as_bytes()) != device_id {
                return Err(storage_error(
                    "identity_load",
                    None,
                    &self.path,
                    "public key does not match device id",
                ));
            }
            Ok(LocalIdentityRecord {
                device_id,
                public_key,
                created_at_ms: u64::try_from(created).map_err(|_| {
                    storage_error("identity_load", None, &self.path, "negative timestamp")
                })?,
            })
        })
        .transpose()
    }

    pub fn upsert_peer_trust(&self, record: &PeerTrustRecord) -> Result<(), StorageError> {
        self.ensure_open("trust_store")?;
        if DeviceId::from_public_key(record.public_key.as_bytes()) != record.device_id {
            return Err(storage_error(
                "trust_store",
                None,
                &self.path,
                "public key does not match device id",
            ));
        }
        let updated = i64::try_from(record.updated_at_ms).map_err(|_| {
            storage_error("trust_store", None, &self.path, "timestamp is out of range")
        })?;
        let last_seen = record
            .last_seen_ms
            .map(i64::try_from)
            .transpose()
            .map_err(|_| {
                storage_error("trust_store", None, &self.path, "timestamp is out of range")
            })?;
        self.connection.lock().map_err(|_| storage_error("trust_store", None, &self.path, "connection lock poisoned"))?
            .execute(
                "INSERT INTO trusted_peers(device_id, public_key, trust_state, updated_at_ms, last_seen_ms) VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(device_id) DO UPDATE SET public_key=excluded.public_key, trust_state=excluded.trust_state, updated_at_ms=excluded.updated_at_ms, last_seen_ms=excluded.last_seen_ms",
                params![record.device_id.to_string(), record.public_key.as_bytes().as_slice(), record.state.as_str(), updated, last_seen],
            ).map(|_| ()).map_err(|error| storage_error("trust_store", None, &self.path, error))
    }

    pub fn peer_trust(&self, device: DeviceId) -> Result<Option<PeerTrustRecord>, StorageError> {
        self.ensure_open("trust_load")?;
        let row: Option<(Vec<u8>, String, i64, Option<i64>)> = self.connection.lock()
            .map_err(|_| storage_error("trust_load", None, &self.path, "connection lock poisoned"))?
            .query_row("SELECT public_key, trust_state, updated_at_ms, last_seen_ms FROM trusted_peers WHERE device_id=?1", [device.to_string()], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))
            .optional().map_err(|error| storage_error("trust_load", None, &self.path, error))?;
        row.map(|(key, state, updated, seen)| {
            let bytes: [u8; 32] = key.try_into().map_err(|_| {
                storage_error(
                    "trust_load",
                    None,
                    &self.path,
                    "malformed public key length",
                )
            })?;
            let public_key = PublicDeviceKey::from_bytes(bytes).map_err(|_| {
                storage_error("trust_load", None, &self.path, "malformed public key")
            })?;
            Ok(PeerTrustRecord {
                device_id: device,
                public_key,
                state: TrustState::parse(&state).ok_or_else(|| {
                    storage_error("trust_load", None, &self.path, "malformed trust state")
                })?,
                updated_at_ms: u64::try_from(updated).map_err(|_| {
                    storage_error("trust_load", None, &self.path, "negative timestamp")
                })?,
                last_seen_ms: seen.map(u64::try_from).transpose().map_err(|_| {
                    storage_error("trust_load", None, &self.path, "negative timestamp")
                })?,
            })
        })
        .transpose()
    }

    pub fn store_peer_connection(
        &self,
        metadata: &PeerConnectionMetadata,
    ) -> Result<(), StorageError> {
        self.ensure_open("connection_store")?;
        let (state, error_category) = encode_connection_state(&metadata.state);
        let updated = i64::try_from(metadata.updated_at_ms).map_err(|_| {
            storage_error(
                "connection_store",
                None,
                &self.path,
                "timestamp is out of range",
            )
        })?;
        self.connection.lock().map_err(|_| storage_error("connection_store", None, &self.path, "connection lock poisoned"))?
            .execute(
                "INSERT INTO peer_connections(device_id, state, error_category, endpoint, updated_at_ms) VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(device_id) DO UPDATE SET state=excluded.state, error_category=excluded.error_category, endpoint=excluded.endpoint, updated_at_ms=excluded.updated_at_ms",
                params![metadata.device_id.to_string(), state, error_category, metadata.endpoint.map(|item| item.to_string()), updated],
            ).map(|_| ()).map_err(|error| storage_error("connection_store", None, &self.path, error))
    }

    pub fn peer_connection(
        &self,
        device: DeviceId,
    ) -> Result<Option<PeerConnectionMetadata>, StorageError> {
        self.ensure_open("connection_load")?;
        let row: Option<(String, Option<String>, Option<String>, i64)> = self.connection.lock()
            .map_err(|_| storage_error("connection_load", None, &self.path, "connection lock poisoned"))?
            .query_row("SELECT state, error_category, endpoint, updated_at_ms FROM peer_connections WHERE device_id=?1", [device.to_string()], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))
            .optional().map_err(|error| storage_error("connection_load", None, &self.path, error))?;
        row.map(|(state, category, endpoint, updated)| {
            let endpoint = endpoint
                .map(|value| value.parse())
                .transpose()
                .map_err(|_| {
                    storage_error("connection_load", None, &self.path, "malformed endpoint")
                })?;
            let state = decode_connection_state(&state, category.as_deref(), endpoint).ok_or_else(
                || {
                    storage_error(
                        "connection_load",
                        None,
                        &self.path,
                        "malformed connection state",
                    )
                },
            )?;
            Ok(PeerConnectionMetadata {
                device_id: device,
                state,
                endpoint,
                updated_at_ms: u64::try_from(updated).map_err(|_| {
                    storage_error("connection_load", None, &self.path, "negative timestamp")
                })?,
            })
        })
        .transpose()
    }

    pub fn upsert_trusted_device(&self, record: &TrustedDeviceRecord) -> Result<(), StorageError> {
        self.ensure_open("trusted_device_store")?;
        validate_trusted_device(record, &self.path)?;
        let paired = checked_timestamp(record.paired_at_ms, "trusted_device_store", &self.path)?;
        let seen = optional_timestamp(record.last_seen_ms, "trusted_device_store", &self.path)?;
        let sync = optional_timestamp(record.last_sync_ms, "trusted_device_store", &self.path)?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "trusted_device_store",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| storage_error("trusted_device_store", None, &self.path, error))?;
        transaction.execute(
            "INSERT INTO trusted_devices(device_id,public_key,friendly_name,paired_at_ms,last_seen_ms,last_sync_ms,trust_state)
             VALUES(?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(device_id) DO UPDATE SET public_key=excluded.public_key,friendly_name=excluded.friendly_name,
             paired_at_ms=MIN(trusted_devices.paired_at_ms,excluded.paired_at_ms),last_seen_ms=excluded.last_seen_ms,
             last_sync_ms=excluded.last_sync_ms,trust_state=excluded.trust_state",
            params![record.device_id.to_string(), record.public_key.as_bytes().as_slice(), record.friendly_name, paired, seen, sync, record.state.as_str()],
        ).map_err(|error| storage_error("trusted_device_store", None, &self.path, error))?;
        transaction.execute(
            "INSERT INTO trusted_peers(device_id,public_key,trust_state,updated_at_ms,last_seen_ms) VALUES(?1,?2,?3,?4,?5)
             ON CONFLICT(device_id) DO UPDATE SET public_key=excluded.public_key,trust_state=excluded.trust_state,updated_at_ms=excluded.updated_at_ms,last_seen_ms=excluded.last_seen_ms",
            params![record.device_id.to_string(),record.public_key.as_bytes().as_slice(),record.state.as_str(),paired,seen],
        ).map_err(|error| storage_error("trusted_device_store", None, &self.path, error))?;
        transaction
            .commit()
            .map_err(|error| storage_error("trusted_device_store", None, &self.path, error))
    }

    pub fn trusted_device(
        &self,
        device: DeviceId,
    ) -> Result<Option<TrustedDeviceRecord>, StorageError> {
        self.ensure_open("trusted_device_load")?;
        let connection = self.connection.lock().map_err(|_| {
            storage_error(
                "trusted_device_load",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let row: Option<TrustedDeviceRow> = connection
            .query_row(
                "SELECT public_key,friendly_name,paired_at_ms,last_seen_ms,last_sync_ms,trust_state FROM trusted_devices WHERE device_id=?1",
                [device.to_string()],
                |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?,row.get(5)?)),
            )
            .optional()
            .map_err(|error| storage_error("trusted_device_load", None, &self.path, error))?;
        row.map(|(key, friendly_name, paired, seen, sync, state)| {
            let public_key = decode_public_key(key, "trusted_device_load", &self.path)?;
            if DeviceId::from_public_key(public_key.as_bytes()) != device {
                return Err(storage_error(
                    "trusted_device_load",
                    None,
                    &self.path,
                    "device ID/key mismatch",
                ));
            }
            Ok(TrustedDeviceRecord {
                device_id: device,
                public_key,
                friendly_name,
                paired_at_ms: decode_timestamp(paired, "trusted_device_load", &self.path)?,
                last_seen_ms: decode_optional_timestamp(seen, "trusted_device_load", &self.path)?,
                last_sync_ms: decode_optional_timestamp(sync, "trusted_device_load", &self.path)?,
                state: TrustState::parse(&state).ok_or_else(|| {
                    storage_error(
                        "trusted_device_load",
                        None,
                        &self.path,
                        "malformed trust state",
                    )
                })?,
            })
        })
        .transpose()
    }

    pub fn trusted_devices(&self) -> Result<Vec<TrustedDeviceRecord>, StorageError> {
        self.ensure_open("trusted_devices_list")?;
        let ids = {
            let connection = self.connection.lock().map_err(|_| {
                storage_error(
                    "trusted_devices_list",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?;
            let mut query = connection
                .prepare("SELECT device_id FROM trusted_devices ORDER BY paired_at_ms,device_id")
                .map_err(|error| storage_error("trusted_devices_list", None, &self.path, error))?;
            query
                .query_map([], |row| row.get::<_, String>(0))
                .map_err(|error| storage_error("trusted_devices_list", None, &self.path, error))?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|error| storage_error("trusted_devices_list", None, &self.path, error))?
        };
        ids.into_iter()
            .map(|id| {
                let device = id.parse().map_err(|_| {
                    storage_error(
                        "trusted_devices_list",
                        None,
                        &self.path,
                        "malformed device ID",
                    )
                })?;
                self.trusted_device(device)?.ok_or_else(|| {
                    storage_error(
                        "trusted_devices_list",
                        None,
                        &self.path,
                        "device disappeared",
                    )
                })
            })
            .collect()
    }

    pub fn rename_trusted_device(
        &self,
        device: DeviceId,
        name: &str,
    ) -> Result<bool, StorageError> {
        self.ensure_open("trusted_device_rename")?;
        if name.trim().is_empty() || name.len() > 64 {
            return Err(storage_error(
                "trusted_device_rename",
                None,
                &self.path,
                "friendly name must contain 1..64 bytes",
            ));
        }
        self.connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "trusted_device_rename",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .execute(
                "UPDATE trusted_devices SET friendly_name=?1 WHERE device_id=?2",
                params![name, device.to_string()],
            )
            .map(|changed| changed == 1)
            .map_err(|error| storage_error("trusted_device_rename", None, &self.path, error))
    }

    /// Touches only the activity timestamps, leaving any `None` unchanged.
    /// Deliberately not load-then-upsert: that would overwrite a rename or
    /// revocation committed between the load and the write.
    pub fn record_trusted_device_activity(
        &self,
        device: DeviceId,
        last_seen_ms: Option<u64>,
        last_sync_ms: Option<u64>,
    ) -> Result<bool, StorageError> {
        self.ensure_open("trusted_device_activity")?;
        let seen = optional_timestamp(last_seen_ms, "trusted_device_activity", &self.path)?;
        let sync = optional_timestamp(last_sync_ms, "trusted_device_activity", &self.path)?;
        self.connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "trusted_device_activity",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .execute(
                "UPDATE trusted_devices SET last_seen_ms=COALESCE(?2,last_seen_ms),
                 last_sync_ms=COALESCE(?3,last_sync_ms) WHERE device_id=?1",
                params![device.to_string(), seen, sync],
            )
            .map(|changed| changed == 1)
            .map_err(|error| storage_error("trusted_device_activity", None, &self.path, error))
    }

    pub fn revoke_trusted_device(
        &self,
        device: DeviceId,
        now_ms: u64,
    ) -> Result<bool, StorageError> {
        self.ensure_open("trusted_device_revoke")?;
        let now = checked_timestamp(now_ms, "trusted_device_revoke", &self.path)?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "trusted_device_revoke",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| storage_error("trusted_device_revoke", None, &self.path, error))?;
        let changed = transaction
            .execute(
                "UPDATE trusted_devices SET trust_state='revoked' WHERE device_id=?1 AND trust_state<>'revoked'",
                [device.to_string()],
            )
            .map_err(|error| storage_error("trusted_device_revoke", None, &self.path, error))?;
        transaction.execute("UPDATE trusted_peers SET trust_state='revoked',updated_at_ms=?1 WHERE device_id=?2", params![now, device.to_string()])
            .map_err(|error| storage_error("trusted_device_revoke", None, &self.path, error))?;
        transaction
            .commit()
            .map_err(|error| storage_error("trusted_device_revoke", None, &self.path, error))?;
        Ok(changed == 1)
    }

    /// Permanently removes a revoked record from both trust tables. The
    /// `trust_state='revoked'` predicate keeps a concurrently re-paired
    /// (trusted) record from being deleted.
    pub fn delete_revoked_device(&self, device: DeviceId) -> Result<bool, StorageError> {
        self.ensure_open("trusted_device_delete")?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "trusted_device_delete",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| storage_error("trusted_device_delete", None, &self.path, error))?;
        let changed = transaction
            .execute(
                "DELETE FROM trusted_devices WHERE device_id=?1 AND trust_state='revoked'",
                [device.to_string()],
            )
            .map_err(|error| storage_error("trusted_device_delete", None, &self.path, error))?;
        if changed == 1 {
            transaction
                .execute(
                    "DELETE FROM trusted_peers WHERE device_id=?1",
                    [device.to_string()],
                )
                .map_err(|error| storage_error("trusted_device_delete", None, &self.path, error))?;
        }
        transaction
            .commit()
            .map_err(|error| storage_error("trusted_device_delete", None, &self.path, error))?;
        Ok(changed == 1)
    }

    pub fn store_pairing_journal(&self, record: &PairingJournalRecord) -> Result<(), StorageError> {
        self.ensure_open("pairing_journal_store")?;
        let updated = checked_timestamp(record.updated_at_ms, "pairing_journal_store", &self.path)?;
        let connection = self.connection.lock().map_err(|_| {
            storage_error(
                "pairing_journal_store",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let existing: Option<(String, Option<String>)> = connection
            .query_row(
                "SELECT peer_device_id,joining_root FROM pairing_journal WHERE session_id=?1",
                [record.session_id.as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| storage_error("pairing_journal_store", None, &self.path, error))?;
        if let Some((peer, root)) = existing
            && (peer != record.peer_device_id.to_string()
                || root.is_some() && record.joining_root.is_some() && root != record.joining_root)
        {
            return Err(storage_error(
                "pairing_journal_store",
                None,
                &self.path,
                "session conflicts with durable pairing journal",
            ));
        }
        connection.execute(
                "INSERT INTO pairing_journal(session_id,peer_device_id,stage,joining_root,failure_reason,updated_at_ms) VALUES(?1,?2,?3,?4,?5,?6)
                 ON CONFLICT(session_id) DO UPDATE SET stage=excluded.stage,joining_root=COALESCE(pairing_journal.joining_root,excluded.joining_root),failure_reason=excluded.failure_reason,updated_at_ms=excluded.updated_at_ms",
                params![record.session_id.as_slice(),record.peer_device_id.to_string(),record.stage.as_str(),record.joining_root,record.failure_reason,updated],
            ).map(|_| ()).map_err(|error| storage_error("pairing_journal_store", None, &self.path, error))
    }

    /// Records why the commit for `session_id` failed without moving the stage
    /// back: the stage is what already succeeded durably, the reason is why the
    /// session never reached `Complete`.
    pub fn record_pairing_journal_failure(
        &self,
        session_id: [u8; 16],
        reason: &str,
        updated_at_ms: u64,
    ) -> Result<bool, StorageError> {
        self.ensure_open("pairing_journal_fail")?;
        let updated = checked_timestamp(updated_at_ms, "pairing_journal_fail", &self.path)?;
        let changed = self
            .connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "pairing_journal_fail",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .execute(
                "UPDATE pairing_journal SET failure_reason=?2,updated_at_ms=?3 WHERE session_id=?1",
                params![session_id.as_slice(), reason, updated],
            )
            .map_err(|error| storage_error("pairing_journal_fail", None, &self.path, error))?;
        Ok(changed == 1)
    }

    /// The most recently touched incomplete journal entry for `peer`, if any.
    pub fn incomplete_pairing_journal_for_peer(
        &self,
        peer: DeviceId,
    ) -> Result<Option<PairingJournalRecord>, StorageError> {
        self.ensure_open("pairing_journal_peer")?;
        let row: Option<PairingJournalRow<Vec<u8>>> = self
            .connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "pairing_journal_peer",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .query_row(
                "SELECT session_id,stage,joining_root,failure_reason,updated_at_ms FROM pairing_journal
                 WHERE peer_device_id=?1 AND stage<>'complete' ORDER BY updated_at_ms DESC LIMIT 1",
                [peer.to_string()],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| storage_error("pairing_journal_peer", None, &self.path, error))?;
        row.map(
            |(session_id, stage, joining_root, failure_reason, updated)| {
                Ok(PairingJournalRecord {
                    session_id: session_id.try_into().map_err(|_| {
                        storage_error(
                            "pairing_journal_peer",
                            None,
                            &self.path,
                            "malformed session id",
                        )
                    })?,
                    peer_device_id: peer,
                    stage: PairingJournalStage::parse(&stage).ok_or_else(|| {
                        storage_error("pairing_journal_peer", None, &self.path, "malformed stage")
                    })?,
                    joining_root,
                    failure_reason,
                    updated_at_ms: decode_timestamp(updated, "pairing_journal_peer", &self.path)?,
                })
            },
        )
        .transpose()
    }

    pub fn pairing_journal(
        &self,
        session_id: [u8; 16],
    ) -> Result<Option<PairingJournalRecord>, StorageError> {
        self.ensure_open("pairing_journal_load")?;
        let row: Option<PairingJournalRow<String>> = self.connection.lock().map_err(|_| storage_error("pairing_journal_load", None, &self.path, "connection lock poisoned"))?
            .query_row("SELECT peer_device_id,stage,joining_root,failure_reason,updated_at_ms FROM pairing_journal WHERE session_id=?1", [session_id.as_slice()], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?)))
            .optional().map_err(|error| storage_error("pairing_journal_load", None, &self.path, error))?;
        row.map(|(peer, stage, joining_root, failure_reason, updated)| {
            Ok(PairingJournalRecord {
                session_id,
                peer_device_id: peer.parse().map_err(|_| {
                    storage_error(
                        "pairing_journal_load",
                        None,
                        &self.path,
                        "malformed peer ID",
                    )
                })?,
                stage: PairingJournalStage::parse(&stage).ok_or_else(|| {
                    storage_error("pairing_journal_load", None, &self.path, "malformed stage")
                })?,
                joining_root,
                failure_reason,
                updated_at_ms: decode_timestamp(updated, "pairing_journal_load", &self.path)?,
            })
        })
        .transpose()
    }

    pub fn store_discovery_metadata(
        &self,
        value: DiscoveryGroupMetadata,
    ) -> Result<(), StorageError> {
        self.ensure_open("discovery_metadata_store")?;
        let epoch = i64::try_from(value.epoch).map_err(|_| {
            storage_error(
                "discovery_metadata_store",
                None,
                &self.path,
                "epoch out of range",
            )
        })?;
        let updated =
            checked_timestamp(value.updated_at_ms, "discovery_metadata_store", &self.path)?;
        self.connection.lock().map_err(|_| storage_error("discovery_metadata_store", None, &self.path, "connection lock poisoned"))?
            .execute("INSERT INTO discovery_group(singleton,version,epoch,updated_at_ms) VALUES(1,1,?1,?2) ON CONFLICT(singleton) DO UPDATE SET version=1,epoch=excluded.epoch,updated_at_ms=excluded.updated_at_ms", params![epoch,updated])
            .map(|_| ()).map_err(|error| storage_error("discovery_metadata_store", None, &self.path, error))
    }

    pub fn discovery_metadata(&self) -> Result<Option<DiscoveryGroupMetadata>, StorageError> {
        self.ensure_open("discovery_metadata_load")?;
        let row: Option<(i64, i64, i64)> = self
            .connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "discovery_metadata_load",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .query_row(
                "SELECT version,epoch,updated_at_ms FROM discovery_group WHERE singleton=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|error| storage_error("discovery_metadata_load", None, &self.path, error))?;
        row.map(|(version, epoch, updated)| {
            if version != 1 || epoch <= 0 {
                return Err(storage_error(
                    "discovery_metadata_load",
                    None,
                    &self.path,
                    "unsupported metadata",
                ));
            }
            Ok(DiscoveryGroupMetadata {
                epoch: u64::try_from(epoch).map_err(|_| {
                    storage_error("discovery_metadata_load", None, &self.path, "invalid epoch")
                })?,
                updated_at_ms: decode_timestamp(updated, "discovery_metadata_load", &self.path)?,
            })
        })
        .transpose()
    }

    pub fn store_discovery_rotation(
        &self,
        value: DiscoveryRotationJournal,
    ) -> Result<(), StorageError> {
        self.ensure_open("discovery_rotation_store")?;
        let previous = i64::try_from(value.previous_epoch).map_err(|_| {
            storage_error(
                "discovery_rotation_store",
                None,
                &self.path,
                "epoch out of range",
            )
        })?;
        let target = i64::try_from(value.target_epoch).map_err(|_| {
            storage_error(
                "discovery_rotation_store",
                None,
                &self.path,
                "epoch out of range",
            )
        })?;
        let retain = checked_timestamp(
            value.retain_until_ms,
            "discovery_rotation_store",
            &self.path,
        )?;
        let updated =
            checked_timestamp(value.updated_at_ms, "discovery_rotation_store", &self.path)?;
        self.connection.lock().map_err(|_| storage_error("discovery_rotation_store", None, &self.path, "connection lock poisoned"))?
            .execute(
                "INSERT INTO discovery_rotation(singleton,version,previous_epoch,target_epoch,retain_until_ms,stage,updated_at_ms) VALUES(1,1,?1,?2,?3,?4,?5) ON CONFLICT(singleton) DO UPDATE SET previous_epoch=excluded.previous_epoch,target_epoch=excluded.target_epoch,retain_until_ms=excluded.retain_until_ms,stage=excluded.stage,updated_at_ms=excluded.updated_at_ms",
                params![previous, target, retain, value.stage.as_str(), updated],
            )
            .map(|_| ())
            .map_err(|error| storage_error("discovery_rotation_store", None, &self.path, error))
    }

    pub fn discovery_rotation(&self) -> Result<Option<DiscoveryRotationJournal>, StorageError> {
        self.ensure_open("discovery_rotation_load")?;
        let row: Option<(i64, i64, i64, String, i64)> = self.connection.lock()
            .map_err(|_| storage_error("discovery_rotation_load", None, &self.path, "connection lock poisoned"))?
            .query_row(
                "SELECT previous_epoch,target_epoch,retain_until_ms,stage,updated_at_ms FROM discovery_rotation WHERE singleton=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
            )
            .optional()
            .map_err(|error| storage_error("discovery_rotation_load", None, &self.path, error))?;
        row.map(|(previous, target, retain, stage, updated)| {
            Ok(DiscoveryRotationJournal {
                previous_epoch: u64::try_from(previous).map_err(|_| {
                    storage_error(
                        "discovery_rotation_load",
                        None,
                        &self.path,
                        "invalid previous epoch",
                    )
                })?,
                target_epoch: u64::try_from(target).map_err(|_| {
                    storage_error(
                        "discovery_rotation_load",
                        None,
                        &self.path,
                        "invalid target epoch",
                    )
                })?,
                retain_until_ms: decode_timestamp(retain, "discovery_rotation_load", &self.path)?,
                stage: DiscoveryRotationStage::parse(&stage).ok_or_else(|| {
                    storage_error("discovery_rotation_load", None, &self.path, "invalid stage")
                })?,
                updated_at_ms: decode_timestamp(updated, "discovery_rotation_load", &self.path)?,
            })
        })
        .transpose()
    }

    pub fn clear_discovery_rotation(&self) -> Result<(), StorageError> {
        self.ensure_open("discovery_rotation_clear")?;
        self.connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "discovery_rotation_clear",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .execute("DELETE FROM discovery_rotation", [])
            .map(|_| ())
            .map_err(|error| storage_error("discovery_rotation_clear", None, &self.path, error))
    }

    /// Durably records that a dataset reset has begun. Its own committed
    /// transaction, so the marker is on disk before any destructive step runs.
    pub fn store_reset_intent(&self, intent: ResetIntent) -> Result<(), StorageError> {
        self.ensure_open("reset_intent_store")?;
        let requested =
            checked_timestamp(intent.requested_at_ms, "reset_intent_store", &self.path)?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "reset_intent_store",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| storage_error("reset_intent_store", None, &self.path, error))?;
        transaction
            .execute(
                "INSERT INTO reset_intent(singleton,version,requested_at_ms) VALUES(1,1,?1)
                 ON CONFLICT(singleton) DO UPDATE SET version=1,requested_at_ms=excluded.requested_at_ms",
                params![requested],
            )
            .map_err(|error| storage_error("reset_intent_store", None, &self.path, error))?;
        transaction
            .commit()
            .map_err(|error| storage_error("reset_intent_store", None, &self.path, error))
    }

    pub fn load_reset_intent(&self) -> Result<Option<ResetIntent>, StorageError> {
        self.ensure_open("reset_intent_load")?;
        let row: Option<(i64, i64)> = self
            .connection
            .lock()
            .map_err(|_| {
                storage_error(
                    "reset_intent_load",
                    None,
                    &self.path,
                    "connection lock poisoned",
                )
            })?
            .query_row(
                "SELECT version,requested_at_ms FROM reset_intent WHERE singleton=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| storage_error("reset_intent_load", None, &self.path, error))?;
        row.map(|(version, requested)| {
            if version != 1 {
                return Err(storage_error(
                    "reset_intent_load",
                    None,
                    &self.path,
                    "unsupported reset intent version",
                ));
            }
            Ok(ResetIntent {
                requested_at_ms: decode_timestamp(requested, "reset_intent_load", &self.path)?,
            })
        })
        .transpose()
    }

    /// Final step of a dataset reset: removes every root-scoped row and the
    /// reset intent in one transaction. `local_identity` is deliberately kept so
    /// the installation's `DeviceId` survives. A no-op when nothing is set.
    pub fn complete_reset(&self) -> Result<(), StorageError> {
        self.ensure_open("reset_complete")?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "reset_complete",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| storage_error("reset_complete", None, &self.path, error))?;
        transaction
            .execute_batch(
                "DELETE FROM app_control;
                 DELETE FROM trusted_peers;
                 DELETE FROM peer_connections;
                 DELETE FROM trusted_devices;
                 DELETE FROM pairing_journal;
                 DELETE FROM discovery_group;
                 DELETE FROM discovery_rotation;
                 DELETE FROM reset_intent;
                 DELETE FROM recovery_attempts;",
            )
            .map_err(|error| storage_error("reset_complete", None, &self.path, error))?;
        transaction
            .commit()
            .map_err(|error| storage_error("reset_complete", None, &self.path, error))
    }
}

fn validate_trusted_device(record: &TrustedDeviceRecord, path: &Path) -> Result<(), StorageError> {
    if DeviceId::from_public_key(record.public_key.as_bytes()) != record.device_id {
        return Err(storage_error(
            "trusted_device_store",
            None,
            path,
            "device ID/key mismatch",
        ));
    }
    if record.friendly_name.trim().is_empty() || record.friendly_name.len() > 64 {
        return Err(storage_error(
            "trusted_device_store",
            None,
            path,
            "friendly name must contain 1..64 bytes",
        ));
    }
    Ok(())
}

fn checked_timestamp(
    value: u64,
    operation: &'static str,
    path: &Path,
) -> Result<i64, StorageError> {
    i64::try_from(value)
        .map_err(|_| storage_error(operation, None, path, "timestamp is out of range"))
}
fn optional_timestamp(
    value: Option<u64>,
    operation: &'static str,
    path: &Path,
) -> Result<Option<i64>, StorageError> {
    value
        .map(|v| checked_timestamp(v, operation, path))
        .transpose()
}
fn decode_timestamp(value: i64, operation: &'static str, path: &Path) -> Result<u64, StorageError> {
    u64::try_from(value).map_err(|_| storage_error(operation, None, path, "negative timestamp"))
}
fn decode_optional_timestamp(
    value: Option<i64>,
    operation: &'static str,
    path: &Path,
) -> Result<Option<u64>, StorageError> {
    value
        .map(|v| decode_timestamp(v, operation, path))
        .transpose()
}
fn decode_public_key(
    value: Vec<u8>,
    operation: &'static str,
    path: &Path,
) -> Result<PublicDeviceKey, StorageError> {
    let bytes: [u8; 32] = value
        .try_into()
        .map_err(|_| storage_error(operation, None, path, "malformed public key length"))?;
    PublicDeviceKey::from_bytes(bytes)
        .map_err(|_| storage_error(operation, None, path, "malformed public key"))
}

fn encode_connection_state(state: &PeerConnectionState) -> (&'static str, Option<&'static str>) {
    match state {
        PeerConnectionState::Disconnected => ("disconnected", None),
        PeerConnectionState::Connecting { .. } => ("connecting", None),
        PeerConnectionState::Authenticating { .. } => ("authenticating", None),
        PeerConnectionState::Connected => ("connected", None),
        PeerConnectionState::Syncing => ("syncing", None),
        PeerConnectionState::Synced => ("synced", None),
        PeerConnectionState::Failed(error) => (
            "failed",
            Some(match error {
                ConnectionFailure::NoRoute => "no_route",
                ConnectionFailure::Route(_) => "route",
                ConnectionFailure::Tls(_) => "tls",
                ConnectionFailure::Trust(_) => "trust",
                ConnectionFailure::Stream(_) => "stream",
                ConnectionFailure::Transport(_) => "transport",
            }),
        ),
    }
}

fn decode_connection_state(
    state: &str,
    category: Option<&str>,
    endpoint: Option<std::net::SocketAddr>,
) -> Option<PeerConnectionState> {
    Some(match state {
        "disconnected" => PeerConnectionState::Disconnected,
        "connecting" => PeerConnectionState::Connecting {
            endpoint: endpoint?,
        },
        "authenticating" => PeerConnectionState::Authenticating {
            endpoint: endpoint?,
        },
        "connected" => PeerConnectionState::Connected,
        "syncing" => PeerConnectionState::Syncing,
        "synced" => PeerConnectionState::Synced,
        "failed" => PeerConnectionState::Failed(match category? {
            "no_route" => ConnectionFailure::NoRoute,
            "route" => ConnectionFailure::Route("previous attempt failed".into()),
            "tls" => ConnectionFailure::Tls("previous attempt failed".into()),
            "trust" => ConnectionFailure::Trust("previous attempt failed".into()),
            "stream" => ConnectionFailure::Stream("previous attempt failed".into()),
            "transport" => ConnectionFailure::Transport("previous attempt failed".into()),
            _ => return None,
        }),
        _ => return None,
    })
}

#[async_trait]
impl ControlStore for SqliteControlStore {
    async fn load(&self) -> Result<Option<BootstrapRecord>, StorageError> {
        self.ensure_open("control_load")?;
        let connection = self.connection.lock().map_err(|_| {
            storage_error("control_load", None, &self.path, "connection lock poisoned")
        })?;
        let row: Option<(i64, String, String)> = connection
            .query_row(
                "SELECT version, state, root FROM app_control WHERE key = 'bootstrap'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|e| storage_error("control_load", None, &self.path, e))?;
        row.map(|(version, state, root)| {
            if version != 1 {
                return Err(storage_error(
                    "control_load",
                    None,
                    &self.path,
                    "unsupported bootstrap version",
                ));
            }
            let root = DocumentId::from_str(&root).map_err(|_| {
                storage_error("control_load", None, &self.path, "malformed root id")
            })?;
            match state.as_str() {
                "creating" => Ok(BootstrapRecord::Creating { root }),
                "joining" => Ok(BootstrapRecord::Joining { root }),
                "ready" => Ok(BootstrapRecord::Ready { root }),
                _ => Err(storage_error(
                    "control_load",
                    None,
                    &self.path,
                    "unsupported bootstrap state",
                )),
            }
        })
        .transpose()
    }

    async fn store(&self, record: BootstrapRecord) -> Result<(), StorageError> {
        self.ensure_open("control_store")?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "control_store",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| storage_error("control_store", None, &self.path, e))?;
        let state = match record {
            BootstrapRecord::Creating { .. } => "creating",
            BootstrapRecord::Joining { .. } => "joining",
            BootstrapRecord::Ready { .. } => "ready",
        };
        transaction.execute("INSERT INTO app_control(key, version, state, root) VALUES('bootstrap', 1, ?1, ?2) ON CONFLICT(key) DO UPDATE SET version=excluded.version,state=excluded.state,root=excluded.root", params![state, record.root().to_string()])
            .map_err(|e| storage_error("control_store", None, &self.path, e))?;
        transaction
            .commit()
            .map_err(|e| storage_error("control_store", None, &self.path, e))
    }

    async fn flush(&self) -> Result<(), StorageError> {
        self.ensure_open("control_flush")?;
        let connection = self.connection.lock().map_err(|_| {
            storage_error(
                "control_flush",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        connection
            .execute_batch("PRAGMA wal_checkpoint(FULL);")
            .map_err(|e| storage_error("control_flush", None, &self.path, e))
    }

    async fn close(&self) -> Result<(), StorageError> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }

    async fn recovery_attempts(&self, root: DocumentId) -> Result<u32, StorageError> {
        self.ensure_open("control_recovery_load")?;
        let connection = self.connection.lock().map_err(|_| {
            storage_error(
                "control_recovery_load",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let attempts: Option<i64> = connection
            .query_row(
                "SELECT attempts FROM recovery_attempts WHERE root = ?1",
                params![root.to_string()],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| storage_error("control_recovery_load", Some(root), &self.path, e))?;
        Ok(attempts.unwrap_or(0).try_into().map_err(|_| {
            storage_error(
                "control_recovery_load",
                Some(root),
                &self.path,
                "malformed recovery counter",
            )
        })?)
    }

    async fn record_recovery_attempt(&self, root: DocumentId) -> Result<u32, StorageError> {
        self.ensure_open("control_recovery_store")?;
        let mut connection = self.connection.lock().map_err(|_| {
            storage_error(
                "control_recovery_store",
                None,
                &self.path,
                "connection lock poisoned",
            )
        })?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| storage_error("control_recovery_store", Some(root), &self.path, e))?;
        transaction
            .execute(
                "INSERT INTO recovery_attempts(root, attempts) VALUES(?1, 1)
                 ON CONFLICT(root) DO UPDATE SET attempts = attempts + 1",
                params![root.to_string()],
            )
            .map_err(|e| storage_error("control_recovery_store", Some(root), &self.path, e))?;
        let attempts: i64 = transaction
            .query_row(
                "SELECT attempts FROM recovery_attempts WHERE root = ?1",
                params![root.to_string()],
                |row| row.get(0),
            )
            .map_err(|e| storage_error("control_recovery_store", Some(root), &self.path, e))?;
        transaction
            .commit()
            .map_err(|e| storage_error("control_recovery_store", Some(root), &self.path, e))?;
        attempts.try_into().map_err(|_| {
            storage_error(
                "control_recovery_store",
                Some(root),
                &self.path,
                "malformed recovery counter",
            )
        })
    }
}

/// Transport with no peers, used by the standalone local application core.
pub(crate) struct LocalTransport {
    events: Mutex<Option<mpsc::Receiver<NetworkEvent>>>,
}
impl LocalTransport {
    pub fn new() -> Arc<Self> {
        let (_tx, rx) = mpsc::channel(1);
        Arc::new(Self {
            events: Mutex::new(Some(rx)),
        })
    }
}
#[async_trait]
impl NetworkTransport for LocalTransport {
    fn take_events(&self) -> Result<mpsc::Receiver<NetworkEvent>, NetworkError> {
        self.events
            .lock()
            .unwrap()
            .take()
            .ok_or(NetworkError::EventsAlreadyTaken)
    }
    async fn send(&self, _peer: &PeerId, _frame: Bytes) -> Result<(), NetworkError> {
        Err(NetworkError::Closed)
    }
    async fn close_peer(&self, _peer: &PeerId) -> Result<(), NetworkError> {
        Ok(())
    }
    async fn close(&self) -> Result<(), NetworkError> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::PrivateDeviceKey;
    use automerge::Automerge;

    #[test]
    fn sqlite_control_stores_only_public_identity_and_typed_trust() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sqlite");
        let store = SqliteControlStore::open(path.clone()).unwrap();
        let public_key = PrivateDeviceKey::from_seed(&[7; 32]).unwrap().public_key();
        let device_id = DeviceId::from_public_key(public_key.as_bytes());
        let local = LocalIdentityRecord {
            device_id,
            public_key,
            created_at_ms: 10,
        };
        store.store_local_identity(&local).unwrap();
        assert_eq!(store.load_local_identity().unwrap(), Some(local));
        let trust = PeerTrustRecord {
            device_id,
            public_key,
            state: TrustState::Trusted,
            updated_at_ms: 11,
            last_seen_ms: None,
        };
        store.upsert_peer_trust(&trust).unwrap();
        assert_eq!(store.peer_trust(device_id).unwrap(), Some(trust));
        let connection = PeerConnectionMetadata {
            device_id,
            state: PeerConnectionState::Connecting {
                endpoint: "127.0.0.1:42".parse().unwrap(),
            },
            endpoint: Some("127.0.0.1:42".parse().unwrap()),
            updated_at_ms: 12,
        };
        store.store_peer_connection(&connection).unwrap();
        assert_eq!(store.peer_connection(device_id).unwrap(), Some(connection));
        let bytes = std::fs::read(path).unwrap();
        assert!(!bytes.windows(32).any(|window| window == [7; 32]));
    }

    // Pins "Last sync never" and the rename race: the activity write touches
    // only the two timestamps, so a rename landing between the sync bridge's
    // observation and its write survives, and the timestamp survives too.
    #[test]
    fn activity_timestamps_and_concurrent_rename_both_persist() {
        let directory = tempfile::tempdir().unwrap();
        let store =
            Arc::new(SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap());
        let key = PrivateDeviceKey::from_seed(&[18; 32]).unwrap().public_key();
        let device = DeviceId::from_public_key(key.as_bytes());
        store
            .upsert_trusted_device(&TrustedDeviceRecord {
                device_id: device,
                public_key: key,
                friendly_name: "Phone".into(),
                paired_at_ms: 10,
                last_seen_ms: Some(10),
                last_sync_ms: None,
                state: TrustState::Trusted,
            })
            .unwrap();
        let renamer = {
            let store = store.clone();
            std::thread::spawn(move || store.rename_trusted_device(device, "Pocket phone").unwrap())
        };
        assert!(
            store
                .record_trusted_device_activity(device, Some(40), Some(40))
                .unwrap()
        );
        assert!(renamer.join().unwrap());
        // A seen-only write leaves the recorded sync time alone.
        store
            .record_trusted_device_activity(device, Some(50), None)
            .unwrap();
        let record = store.trusted_device(device).unwrap().unwrap();
        assert_eq!(record.friendly_name, "Pocket phone");
        assert_eq!(record.last_sync_ms, Some(40));
        assert_eq!(record.last_seen_ms, Some(50));
        let unknown = DeviceId::from_public_key(&[19; 32]);
        assert!(
            !store
                .record_trusted_device_activity(unknown, Some(1), Some(1))
                .unwrap(),
            "never creates a row"
        );
    }

    #[test]
    fn trusted_devices_journal_and_discovery_metadata_are_restartable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sqlite");
        let key = PrivateDeviceKey::from_seed(&[17; 32]).unwrap().public_key();
        let device = DeviceId::from_public_key(key.as_bytes());
        {
            let store = SqliteControlStore::open(path.clone()).unwrap();
            let trusted = TrustedDeviceRecord {
                device_id: device,
                public_key: key,
                friendly_name: "Laptop".into(),
                paired_at_ms: 10,
                last_seen_ms: Some(11),
                last_sync_ms: Some(12),
                state: TrustState::Trusted,
            };
            store.upsert_trusted_device(&trusted).unwrap();
            assert!(
                store
                    .rename_trusted_device(device, "Travel laptop")
                    .unwrap()
            );
            store
                .store_pairing_journal(&PairingJournalRecord {
                    session_id: [3; 16],
                    peer_device_id: device,
                    stage: PairingJournalStage::RootJoining,
                    joining_root: Some(DocumentId::new().to_string()),
                    failure_reason: None,
                    updated_at_ms: 13,
                })
                .unwrap();
            let recovery_root = DocumentId::new().to_string();
            for (index, stage) in [
                PairingJournalStage::Confirmed,
                PairingJournalStage::ProvisioningStored,
                PairingJournalStage::RootJoining,
                PairingJournalStage::TrustStored,
                PairingJournalStage::AwaitingAcknowledgement,
                PairingJournalStage::Complete,
            ]
            .into_iter()
            .enumerate()
            {
                store
                    .store_pairing_journal(&PairingJournalRecord {
                        session_id: [4; 16],
                        peer_device_id: device,
                        stage,
                        joining_root: Some(recovery_root.clone()),
                        failure_reason: None,
                        updated_at_ms: 20 + index as u64,
                    })
                    .unwrap();
            }
            assert!(
                store
                    .store_pairing_journal(&PairingJournalRecord {
                        session_id: [4; 16],
                        peer_device_id: device,
                        stage: PairingJournalStage::Complete,
                        joining_root: Some(DocumentId::new().to_string()),
                        failure_reason: None,
                        updated_at_ms: 30,
                    })
                    .is_err()
            );
            store
                .store_discovery_metadata(DiscoveryGroupMetadata {
                    epoch: 1,
                    updated_at_ms: 14,
                })
                .unwrap();
        }
        let reopened = SqliteControlStore::open(path).unwrap();
        let trusted = reopened.trusted_device(device).unwrap().unwrap();
        assert_eq!(trusted.friendly_name, "Travel laptop");
        assert_eq!(
            reopened.peer_trust(device).unwrap().unwrap().state,
            TrustState::Trusted
        );
        assert_eq!(
            reopened.pairing_journal([3; 16]).unwrap().unwrap().stage,
            PairingJournalStage::RootJoining
        );
        assert_eq!(reopened.discovery_metadata().unwrap().unwrap().epoch, 1);
        assert_eq!(
            reopened.pairing_journal([4; 16]).unwrap().unwrap().stage,
            PairingJournalStage::Complete
        );
        assert!(reopened.revoke_trusted_device(device, 15).unwrap());
        assert_eq!(
            reopened.peer_trust(device).unwrap().unwrap().state,
            TrustState::Revoked
        );
    }

    fn trusted_record(seed: u8, paired_at_ms: u64) -> TrustedDeviceRecord {
        let key = PrivateDeviceKey::from_seed(&[seed; 32])
            .unwrap()
            .public_key();
        TrustedDeviceRecord {
            device_id: DeviceId::from_public_key(key.as_bytes()),
            public_key: key,
            friendly_name: format!("Device {seed}"),
            paired_at_ms,
            last_seen_ms: None,
            last_sync_ms: None,
            state: TrustState::Trusted,
        }
    }

    #[test]
    fn delete_revoked_device_removes_only_revoked_records() {
        let directory = tempfile::tempdir().unwrap();
        let store = SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap();
        let revoked = trusted_record(31, 10);
        let trusted = trusted_record(32, 11);
        store.upsert_trusted_device(&revoked).unwrap();
        store.upsert_trusted_device(&trusted).unwrap();
        assert!(store.revoke_trusted_device(revoked.device_id, 12).unwrap());

        assert!(store.delete_revoked_device(revoked.device_id).unwrap());
        assert_eq!(store.trusted_device(revoked.device_id).unwrap(), None);
        assert_eq!(store.peer_trust(revoked.device_id).unwrap(), None);

        assert!(!store.delete_revoked_device(trusted.device_id).unwrap());
        assert_eq!(
            store.trusted_device(trusted.device_id).unwrap(),
            Some(trusted.clone())
        );
        assert_eq!(
            store.peer_trust(trusted.device_id).unwrap().unwrap().state,
            TrustState::Trusted
        );

        let unknown = trusted_record(33, 13).device_id;
        assert!(!store.delete_revoked_device(unknown).unwrap());
        assert!(!store.delete_revoked_device(revoked.device_id).unwrap());
        assert_eq!(store.trusted_devices().unwrap(), vec![trusted]);
    }

    #[test]
    fn delete_revoked_device_then_repair_gets_fresh_paired_time() {
        let directory = tempfile::tempdir().unwrap();
        let store = SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap();
        let original = trusted_record(34, 10);
        store.upsert_trusted_device(&original).unwrap();
        assert!(store.revoke_trusted_device(original.device_id, 20).unwrap());
        assert!(store.delete_revoked_device(original.device_id).unwrap());

        let repaired = TrustedDeviceRecord {
            paired_at_ms: 500,
            ..original.clone()
        };
        store.upsert_trusted_device(&repaired).unwrap();
        let stored = store.trusted_device(original.device_id).unwrap().unwrap();
        assert_eq!(stored.paired_at_ms, 500);
        assert_eq!(stored.state, TrustState::Trusted);
    }

    #[tokio::test]
    async fn reset_intent_round_trips_and_complete_reset_keeps_only_identity() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sqlite");
        let key = PrivateDeviceKey::from_seed(&[21; 32]).unwrap().public_key();
        let device = DeviceId::from_public_key(key.as_bytes());
        let local = LocalIdentityRecord {
            device_id: device,
            public_key: key,
            created_at_ms: 1,
        };
        {
            let store = SqliteControlStore::open(path.clone()).unwrap();
            assert_eq!(store.load_reset_intent().unwrap(), None);
            // Nothing set: complete_reset is a harmless no-op.
            store.complete_reset().unwrap();
            store.store_local_identity(&local).unwrap();
            ControlStore::store(
                &store,
                BootstrapRecord::Ready {
                    root: DocumentId::new(),
                },
            )
            .await
            .unwrap();
            store
                .upsert_trusted_device(&TrustedDeviceRecord {
                    device_id: device,
                    public_key: key,
                    friendly_name: "Laptop".into(),
                    paired_at_ms: 2,
                    last_seen_ms: None,
                    last_sync_ms: None,
                    state: TrustState::Trusted,
                })
                .unwrap();
            store
                .store_peer_connection(&PeerConnectionMetadata {
                    device_id: device,
                    state: PeerConnectionState::Connected,
                    endpoint: None,
                    updated_at_ms: 3,
                })
                .unwrap();
            store
                .store_pairing_journal(&PairingJournalRecord {
                    session_id: [5; 16],
                    peer_device_id: device,
                    stage: PairingJournalStage::Complete,
                    joining_root: None,
                    failure_reason: None,
                    updated_at_ms: 4,
                })
                .unwrap();
            store
                .store_discovery_metadata(DiscoveryGroupMetadata {
                    epoch: 1,
                    updated_at_ms: 5,
                })
                .unwrap();
            store
                .store_discovery_rotation(DiscoveryRotationJournal {
                    previous_epoch: 1,
                    target_epoch: 2,
                    retain_until_ms: 6,
                    stage: DiscoveryRotationStage::Prepared,
                    updated_at_ms: 6,
                })
                .unwrap();
            store
                .store_reset_intent(ResetIntent { requested_at_ms: 7 })
                .unwrap();
        }
        let reopened = SqliteControlStore::open(path.clone()).unwrap();
        assert_eq!(
            reopened.load_reset_intent().unwrap(),
            Some(ResetIntent { requested_at_ms: 7 })
        );
        reopened.complete_reset().unwrap();
        assert_eq!(reopened.load_reset_intent().unwrap(), None);
        assert_eq!(ControlStore::load(&reopened).await.unwrap(), None);
        assert_eq!(reopened.trusted_devices().unwrap(), vec![]);
        assert_eq!(reopened.peer_trust(device).unwrap(), None);
        assert_eq!(reopened.peer_connection(device).unwrap(), None);
        assert_eq!(reopened.pairing_journal([5; 16]).unwrap(), None);
        assert_eq!(reopened.discovery_metadata().unwrap(), None);
        assert_eq!(reopened.discovery_rotation().unwrap(), None);
        assert_eq!(reopened.load_local_identity().unwrap(), Some(local));
        drop(reopened);
        let again = SqliteControlStore::open(path).unwrap();
        assert_eq!(again.load_reset_intent().unwrap(), None);
    }

    #[tokio::test]
    async fn sqlite_control_round_trips_every_transition() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sqlite");
        let store = SqliteControlStore::open(path).unwrap();
        let root = DocumentId::new();
        for record in [
            BootstrapRecord::Creating { root },
            BootstrapRecord::Joining { root },
            BootstrapRecord::Ready { root },
        ] {
            ControlStore::store(&store, record.clone()).await.unwrap();
            ControlStore::flush(&store).await.unwrap();
            assert_eq!(ControlStore::load(&store).await.unwrap(), Some(record));
        }
    }

    #[tokio::test]
    async fn sqlite_control_rejects_malformed_rows_without_rewriting_them() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sqlite");
        let store = SqliteControlStore::open(path.clone()).unwrap();
        {
            let connection = store.connection.lock().unwrap();
            connection.execute("INSERT INTO app_control(key,version,state,root) VALUES('bootstrap',99,'wrong','not-an-id')", []).unwrap();
        }
        assert!(ControlStore::load(&store).await.is_err());
        let row: (i64, String) = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT version,state FROM app_control WHERE key='bootstrap'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(row, (99, "wrong".into()));
    }

    #[tokio::test]
    async fn document_snapshots_are_complete_and_restartable() {
        let directory = tempfile::tempdir().unwrap();
        let store = FileDocumentStore::open(
            directory.path().join("documents"),
            directory.path().join("quarantine"),
        )
        .await
        .unwrap();
        let id = DocumentId::new();
        let mut document = Automerge::new();
        document.empty_commit(automerge::transaction::CommitOptions::default());
        StorageAdapter::store(&store, id, document.save())
            .await
            .unwrap();
        StorageAdapter::flush(&store).await.unwrap();
        let bytes = StorageAdapter::load(&store, id).await.unwrap().unwrap();
        assert!(Automerge::load(&bytes).is_ok());
        assert_eq!(StorageAdapter::list(&store).await.unwrap(), vec![id]);

        // Quarantine is a move into the sibling directory, created lazily.
        assert!(!directory.path().join("quarantine").exists());
        let location = store
            .quarantine(id, QuarantineReason::Orphaned)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            location,
            directory
                .path()
                .join(format!("quarantine/{id}.orphaned.automerge"))
        );
        assert!(StorageAdapter::list(&store).await.unwrap().is_empty());
        let entries = store.quarantined().await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].document, id);
        assert_eq!(
            store.load_quarantined(&entries[0].key).await.unwrap(),
            Some(document.save())
        );
        assert!(
            store
                .load_quarantined("../documents/x.automerge")
                .await
                .is_err()
        );
        store.discard_quarantined(&entries[0].key).await.unwrap();
        assert!(store.quarantined().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn recovery_attempts_are_durable_and_cleared_by_reset() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("control.sqlite");
        let store = SqliteControlStore::open(path.clone()).unwrap();
        let root = DocumentId::new();
        assert_eq!(
            ControlStore::recovery_attempts(&store, root).await.unwrap(),
            0
        );
        assert_eq!(
            ControlStore::record_recovery_attempt(&store, root)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            ControlStore::record_recovery_attempt(&store, root)
                .await
                .unwrap(),
            2
        );
        drop(store);
        let reopened = SqliteControlStore::open(path).unwrap();
        assert_eq!(
            ControlStore::recovery_attempts(&reopened, root)
                .await
                .unwrap(),
            2
        );
        reopened.complete_reset().unwrap();
        assert_eq!(
            ControlStore::recovery_attempts(&reopened, root)
                .await
                .unwrap(),
            0
        );
    }
}
