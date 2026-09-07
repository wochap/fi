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
use automerge::Automerge;
use automerge_repo::{
    BootstrapRecord, DocumentId, PeerId,
    error::{NetworkError, StorageError},
    network::{NetworkEvent, NetworkTransport},
    storage::{ControlStore, StorageAdapter},
};
use bytes::Bytes;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use tokio::sync::mpsc;

use crate::{
    control::{LocalIdentityRecord, PeerConnectionMetadata, PeerTrustRecord, TrustState},
    identity::{DeviceId, PublicDeviceKey},
    routing::{ConnectionFailure, PeerConnectionState},
};

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

/// Private complete-snapshot adapter rooted exactly at `automerge/documents`.
#[derive(Clone, Debug)]
pub(crate) struct FileDocumentStore {
    directory: Arc<PathBuf>,
    closed: Arc<AtomicBool>,
    nonce: Arc<AtomicU64>,
}

impl FileDocumentStore {
    pub async fn open(directory: PathBuf) -> Result<Self, StorageError> {
        let path = directory.clone();
        blocking("open", None, path.clone(), move || {
            ensure_private_dir(&path)
        })
        .await?;
        Ok(Self {
            directory: Arc::new(directory),
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
                let bytes = fs::read(entry.path())?;
                Automerge::load(&bytes)
                    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
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
        let store = FileDocumentStore::open(directory.path().join("documents"))
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
    }
}
