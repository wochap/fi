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
        connection.execute_batch("CREATE TABLE IF NOT EXISTS app_control (key TEXT PRIMARY KEY, version INTEGER NOT NULL, state TEXT NOT NULL, root TEXT NOT NULL) STRICT;")
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
