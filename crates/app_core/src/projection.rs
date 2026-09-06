use std::{
    fs,
    path::{Path, PathBuf},
    str::FromStr,
    sync::{Arc, Mutex},
};

use automerge::ChangeHash;
use automerge_repo::{DocHandle, DocumentId, Repo};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};

use crate::{
    domain::{
        CategoryId, CategoryView, FinanceSnapshot, TransactionFilter, TransactionId,
        TransactionView, decode_finance,
    },
    error::{AppError, ProjectionError, Result},
};

pub const PROJECTION_SCHEMA_VERSION: i64 = 1;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectionCheckpoint {
    pub root: DocumentId,
    pub schema_version: i64,
    pub heads: String,
}

impl ProjectionCheckpoint {
    #[must_use]
    pub fn from_heads(root: DocumentId, heads: &[ChangeHash]) -> Self {
        let mut heads = heads.to_vec();
        heads.sort_unstable();
        Self {
            root,
            schema_version: PROJECTION_SCHEMA_VERSION,
            heads: format!(
                "v1:{}",
                heads
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",")
            ),
        }
    }

    pub fn validate(&self) -> std::result::Result<(), ProjectionError> {
        let Some(encoded) = self.heads.strip_prefix("v1:") else {
            return Err(ProjectionError::Checkpoint("unsupported encoding".into()));
        };
        let mut prior = None::<&str>;
        for value in encoded.split(',').filter(|value| !value.is_empty()) {
            ChangeHash::from_str(value)
                .map_err(|_| ProjectionError::Checkpoint("invalid change hash".into()))?;
            if prior.is_some_and(|previous| previous >= value) {
                return Err(ProjectionError::Checkpoint(
                    "heads are not strictly sorted".into(),
                ));
            }
            prior = Some(value);
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct AggregateView {
    pub balance_minor: i64,
    pub income_minor: i64,
    pub expense_minor: i64,
    pub transaction_count: i64,
}

#[derive(Clone)]
pub(crate) struct ReadModel {
    path: Arc<PathBuf>,
    connection: Arc<Mutex<Connection>>,
}

impl std::fmt::Debug for ReadModel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReadModel")
            .field("path", &self.path)
            .finish_non_exhaustive()
    }
}

impl ReadModel {
    pub fn open_disposable(path: PathBuf) -> Result<Self> {
        match Self::open(path.clone()) {
            Ok(model) if model.integrity_ok() && model.schema_compatible() => Ok(model),
            Ok(_) | Err(_) => {
                remove_database_files(&path)?;
                Self::open(path)
            }
        }
    }

    fn open(path: PathBuf) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| projection_db(&path, e))?;
        }
        let connection = Connection::open(&path).map_err(|e| projection_db(&path, e))?;
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .map_err(|e| projection_db(&path, e))?;
        connection
            .pragma_update(None, "synchronous", "FULL")
            .map_err(|e| projection_db(&path, e))?;
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS categories (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                deleted INTEGER NOT NULL CHECK(deleted IN (0,1))
             ) STRICT;
             CREATE TABLE IF NOT EXISTS transactions (
                id TEXT PRIMARY KEY NOT NULL,
                occurred_at_ms INTEGER NOT NULL,
                category_id TEXT NOT NULL,
                amount_minor INTEGER NOT NULL,
                description TEXT NOT NULL,
                deleted INTEGER NOT NULL CHECK(deleted IN (0,1))
             ) STRICT;
             CREATE INDEX IF NOT EXISTS transactions_date_id ON transactions(occurred_at_ms DESC, id ASC);
             CREATE INDEX IF NOT EXISTS transactions_category_date ON transactions(category_id, occurred_at_ms DESC, id ASC);
             CREATE TABLE IF NOT EXISTS projection_metadata (
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                root_id TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                heads TEXT NOT NULL
             ) STRICT;"
        ).map_err(|e| projection_db(&path, e))?;
        Ok(Self {
            path: Arc::new(path),
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    fn integrity_ok(&self) -> bool {
        self.connection
            .lock()
            .ok()
            .and_then(|connection| {
                connection
                    .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
                    .ok()
            })
            .is_some_and(|value| value == "ok")
    }

    fn schema_compatible(&self) -> bool {
        let Ok(connection) = self.connection.lock() else {
            return false;
        };
        fn columns(connection: &Connection, table: &str) -> rusqlite::Result<Vec<String>> {
            let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
            statement.query_map([], |row| row.get(1))?.collect()
        }
        columns(&connection, "categories").ok().as_deref()
            == Some(&["id".into(), "name".into(), "deleted".into()])
            && columns(&connection, "transactions").ok().as_deref()
                == Some(&[
                    "id".into(),
                    "occurred_at_ms".into(),
                    "category_id".into(),
                    "amount_minor".into(),
                    "description".into(),
                    "deleted".into(),
                ])
            && columns(&connection, "projection_metadata").ok().as_deref()
                == Some(&[
                    "singleton".into(),
                    "root_id".into(),
                    "schema_version".into(),
                    "heads".into(),
                ])
    }

    pub fn checkpoint(&self) -> Result<Option<ProjectionCheckpoint>> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| projection_db(&self.path, "connection lock poisoned"))?;
        let row: Option<(String, i64, String)> = connection
            .query_row(
                "SELECT root_id, schema_version, heads FROM projection_metadata WHERE singleton=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|e| projection_db(&self.path, e))?;
        row.map(|(root, schema_version, heads)| {
            let root = root
                .parse()
                .map_err(|_| ProjectionError::Checkpoint("invalid root id".into()))?;
            let checkpoint = ProjectionCheckpoint {
                root,
                schema_version,
                heads,
            };
            checkpoint.validate()?;
            Ok::<ProjectionCheckpoint, ProjectionError>(checkpoint)
        })
        .transpose()
        .map_err(AppError::from)
    }

    pub fn replace(
        &self,
        snapshot: &FinanceSnapshot,
        checkpoint: &ProjectionCheckpoint,
    ) -> Result<()> {
        checkpoint.validate()?;
        let mut connection = self
            .connection
            .lock()
            .map_err(|_| projection_db(&self.path, "connection lock poisoned"))?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| projection_db(&self.path, e))?;
        transaction
            .execute("DELETE FROM transactions", [])
            .map_err(|e| projection_db(&self.path, e))?;
        transaction
            .execute("DELETE FROM categories", [])
            .map_err(|e| projection_db(&self.path, e))?;
        for category in &snapshot.categories {
            transaction
                .execute(
                    "INSERT INTO categories(id,name,deleted) VALUES(?1,?2,?3)",
                    params![category.id.to_string(), category.name, category.deleted],
                )
                .map_err(|e| projection_db(&self.path, e))?;
        }
        for item in &snapshot.transactions {
            transaction.execute("INSERT INTO transactions(id,occurred_at_ms,category_id,amount_minor,description,deleted) VALUES(?1,?2,?3,?4,?5,?6)", params![item.id.to_string(), item.occurred_at_ms, item.category_id.to_string(), item.amount_minor, item.description, item.deleted]).map_err(|e| projection_db(&self.path, e))?;
        }
        // Checkpoint is intentionally the final write in the transaction.
        transaction.execute("INSERT INTO projection_metadata(singleton,root_id,schema_version,heads) VALUES(1,?1,?2,?3) ON CONFLICT(singleton) DO UPDATE SET root_id=excluded.root_id,schema_version=excluded.schema_version,heads=excluded.heads", params![checkpoint.root.to_string(), checkpoint.schema_version, checkpoint.heads]).map_err(|e| projection_db(&self.path, e))?;
        transaction
            .commit()
            .map_err(|e| projection_db(&self.path, e))?;
        connection
            .execute_batch("PRAGMA wal_checkpoint(FULL);")
            .map_err(|e| projection_db(&self.path, e))?;
        Ok(())
    }

    pub fn categories(&self) -> Result<Vec<CategoryView>> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| projection_db(&self.path, "connection lock poisoned"))?;
        let mut statement = connection.prepare("SELECT id,name FROM categories WHERE deleted=0 ORDER BY name COLLATE NOCASE ASC,id ASC").map_err(|e| projection_db(&self.path, e))?;
        let rows = statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| projection_db(&self.path, e))?;
        rows.map(|row| {
            let (id, name) = row.map_err(|e| projection_db(&self.path, e))?;
            Ok(CategoryView {
                id: id.parse()?,
                name,
            })
        })
        .collect()
    }

    pub fn transactions(&self, filter: &TransactionFilter) -> Result<Vec<TransactionView>> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| projection_db(&self.path, "connection lock poisoned"))?;
        let mut statement = connection
            .prepare(
                "SELECT t.id,t.occurred_at_ms,t.category_id,c.name,t.amount_minor,t.description
             FROM transactions t LEFT JOIN categories c ON c.id=t.category_id AND c.deleted=0
             WHERE t.deleted=0
               AND (?1 IS NULL OR instr(lower(t.description),lower(?1)) > 0)
               AND (?2 IS NULL OR t.category_id=?2)
               AND (?3 IS NULL OR t.occurred_at_ms>=?3)
               AND (?4 IS NULL OR t.occurred_at_ms<=?4)
             ORDER BY t.occurred_at_ms DESC,t.id ASC",
            )
            .map_err(|e| projection_db(&self.path, e))?;
        let category = filter.category_id.map(|id| id.to_string());
        let rows = statement
            .query_map(
                params![filter.text, category, filter.from_ms, filter.through_ms],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, String>(5)?,
                    ))
                },
            )
            .map_err(|e| projection_db(&self.path, e))?;
        rows.map(|row| {
            let (id, occurred_at_ms, category_id, category_name, amount_minor, description) =
                row.map_err(|e| projection_db(&self.path, e))?;
            Ok(TransactionView {
                id: TransactionId::from_str(&id)?,
                occurred_at_ms,
                category_id: CategoryId::from_str(&category_id)?,
                category_available: category_name.is_some(),
                category_name,
                amount_minor,
                description,
            })
        })
        .collect()
    }

    pub fn aggregates(&self) -> Result<AggregateView> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| projection_db(&self.path, "connection lock poisoned"))?;
        connection.query_row("SELECT COALESCE(SUM(amount_minor),0),COALESCE(SUM(CASE WHEN amount_minor>0 THEN amount_minor ELSE 0 END),0),COALESCE(SUM(CASE WHEN amount_minor<0 THEN amount_minor ELSE 0 END),0),COUNT(*) FROM transactions WHERE deleted=0", [], |row| Ok(AggregateView { balance_minor: row.get(0)?, income_minor: row.get(1)?, expense_minor: row.get(2)?, transaction_count: row.get(3)? })).map_err(|e| projection_db(&self.path, e))
    }
}

pub(crate) async fn capture(handle: &DocHandle) -> Result<(FinanceSnapshot, Vec<ChangeHash>)> {
    handle
        .read(|doc| {
            let snapshot = decode_finance(doc);
            let mut heads = doc.get_heads();
            heads.sort_unstable();
            (snapshot, heads)
        })
        .await
        .map_err(AppError::from)
        .and_then(|(snapshot, heads)| Ok((snapshot?, heads)))
}

pub(crate) async fn project(
    repo: &Repo,
    handle: &DocHandle,
    read_model: &ReadModel,
) -> Result<ProjectionCheckpoint> {
    // Capture precedes the repository-wide durability barrier by design.
    let (snapshot, heads) = capture(handle).await?;
    repo.flush().await?;
    let checkpoint = ProjectionCheckpoint::from_heads(handle.id(), &heads);
    read_model.replace(&snapshot, &checkpoint)?;
    Ok(checkpoint)
}

pub(crate) async fn reconcile(
    repo: &Repo,
    handle: &DocHandle,
    read_model: &ReadModel,
) -> Result<ProjectionCheckpoint> {
    let (_, heads) = capture(handle).await?;
    let expected = ProjectionCheckpoint::from_heads(handle.id(), &heads);
    match read_model.checkpoint() {
        Ok(Some(current))
            if current == expected && current.schema_version == PROJECTION_SCHEMA_VERSION =>
        {
            Ok(current)
        }
        _ => project(repo, handle, read_model).await,
    }
}

fn remove_database_files(path: &Path) -> Result<()> {
    for candidate in [
        path.to_path_buf(),
        PathBuf::from(format!("{}-wal", path.display())),
        PathBuf::from(format!("{}-shm", path.display())),
    ] {
        match fs::remove_file(&candidate) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(projection_db(path, error)),
        }
    }
    Ok(())
}

fn projection_db(path: &Path, error: impl std::fmt::Display) -> AppError {
    ProjectionError::Database {
        path: path.to_path_buf(),
        message: error.to_string(),
    }
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checkpoint_encoding_is_canonical() {
        let root = DocumentId::new();
        let a = ChangeHash([2; 32]);
        let b = ChangeHash([1; 32]);
        assert_eq!(
            ProjectionCheckpoint::from_heads(root, &[a, b]),
            ProjectionCheckpoint::from_heads(root, &[b, a])
        );
    }
}
