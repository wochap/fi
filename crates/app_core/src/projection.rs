use std::{
    fs,
    path::{Path, PathBuf},
    str::FromStr,
    sync::{Arc, Mutex},
};

use automerge::ChangeHash;
use automerge_repo::{DocHandle, DocumentId, Repo};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params, types::Value};

use crate::{
    error::{AppError, ProjectionError, Result},
    generic::{CollectionView, GenericDiagnostic, GenericSnapshot, RecordView, decode_generic},
    query::{
        CollectionQuery, ComparisonOperator, ComputedFieldDefinition, Expression, FieldReference,
        NullOrder, QueryDefinition, SortDirection, TypedValue,
    },
    records::{GenericRecord, RecordId},
    schema::{CollectionSchema, CollectionSchemaId, FieldDefinition, FieldId},
    values::FieldValue,
    widgets::{WidgetDefinition, WidgetId},
};

pub const PROJECTION_SCHEMA_VERSION: i64 = 4;

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

#[derive(Clone)]
pub(crate) struct ReadModel {
    path: Arc<PathBuf>,
    connection: Arc<Mutex<Connection>>,
}
impl std::fmt::Debug for ReadModel {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ReadModel")
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
            fs::create_dir_all(parent).map_err(|error| projection_db(&path, error))?;
        }
        let connection = Connection::open(&path).map_err(|error| projection_db(&path, error))?;
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .map_err(|error| projection_db(&path, error))?;
        connection
            .pragma_update(None, "synchronous", "FULL")
            .map_err(|error| projection_db(&path, error))?;
        connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS collections (
                id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL,
                deleted INTEGER NOT NULL CHECK(deleted IN (0,1))
             ) STRICT;
             CREATE TABLE IF NOT EXISTS fields (
                id TEXT PRIMARY KEY NOT NULL, collection_id TEXT NOT NULL, name TEXT NOT NULL,
                value_kind TEXT NOT NULL, decimal_scale INTEGER, required INTEGER NOT NULL CHECK(required IN (0,1)),
                order_value INTEGER NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), definition_json TEXT NOT NULL,
                FOREIGN KEY(collection_id) REFERENCES collections(id)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS enum_options (
                id TEXT PRIMARY KEY NOT NULL, field_id TEXT NOT NULL, label TEXT NOT NULL,
                order_value INTEGER NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
                FOREIGN KEY(field_id) REFERENCES fields(id)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS records (
                id TEXT PRIMARY KEY NOT NULL, collection_id TEXT NOT NULL,
                deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), FOREIGN KEY(collection_id) REFERENCES collections(id)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS computed_fields (
                id TEXT PRIMARY KEY NOT NULL, collection_id TEXT NOT NULL, name TEXT NOT NULL,
                order_value INTEGER NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
                definition_json TEXT NOT NULL, FOREIGN KEY(collection_id) REFERENCES collections(id)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS query_definitions (
                id TEXT PRIMARY KEY NOT NULL, collection_id TEXT NOT NULL, name TEXT NOT NULL,
                order_value INTEGER NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
                definition_json TEXT NOT NULL, FOREIGN KEY(collection_id) REFERENCES collections(id)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS widgets (
                id TEXT PRIMARY KEY NOT NULL, collection_id TEXT NOT NULL, widget_type TEXT NOT NULL,
                query_id TEXT NOT NULL, title TEXT NOT NULL,
                order_value INTEGER NOT NULL, deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
                definition_json TEXT NOT NULL, FOREIGN KEY(collection_id) REFERENCES collections(id)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS record_values (
                record_id TEXT NOT NULL, collection_id TEXT NOT NULL, field_id TEXT NOT NULL,
                value_kind TEXT NOT NULL, integer_value INTEGER, text_value TEXT, boolean_value INTEGER,
                physical_time_ms INTEGER NOT NULL, logical_counter INTEGER NOT NULL, node_id TEXT NOT NULL,
                PRIMARY KEY(record_id,field_id), FOREIGN KEY(record_id) REFERENCES records(id), FOREIGN KEY(field_id) REFERENCES fields(id),
                CHECK(boolean_value IS NULL OR boolean_value IN (0,1)),
                CHECK((value_kind='null' AND integer_value IS NULL AND text_value IS NULL AND boolean_value IS NULL)
                   OR (value_kind IN ('integer','fixed_decimal','date','date_time','duration') AND integer_value IS NOT NULL AND text_value IS NULL AND boolean_value IS NULL)
                   OR (value_kind IN ('text','enum') AND integer_value IS NULL AND text_value IS NOT NULL AND boolean_value IS NULL)
                   OR (value_kind='boolean' AND integer_value IS NULL AND text_value IS NULL AND boolean_value IS NOT NULL))
             ) STRICT;
             CREATE TABLE IF NOT EXISTS projection_diagnostics (
                kind TEXT NOT NULL, entity_id TEXT NOT NULL, field_id TEXT NOT NULL, message TEXT NOT NULL,
                PRIMARY KEY(kind,entity_id,field_id,message)
             ) STRICT;
             CREATE TABLE IF NOT EXISTS projection_metadata (
                singleton INTEGER PRIMARY KEY CHECK(singleton=1), root_id TEXT NOT NULL,
                schema_version INTEGER NOT NULL, heads TEXT NOT NULL
             ) STRICT;
             CREATE INDEX IF NOT EXISTS fields_collection_order ON fields(collection_id,deleted,order_value,id);
             CREATE INDEX IF NOT EXISTS enum_options_field_order ON enum_options(field_id,deleted,order_value,id);
             CREATE INDEX IF NOT EXISTS records_collection_id ON records(collection_id,deleted,id);
             CREATE INDEX IF NOT EXISTS computed_fields_collection_order ON computed_fields(collection_id,deleted,order_value,id);
             CREATE INDEX IF NOT EXISTS query_definitions_collection_order ON query_definitions(collection_id,deleted,order_value,id);
             CREATE INDEX IF NOT EXISTS widgets_collection_order ON widgets(collection_id,deleted,order_value,id);
             CREATE INDEX IF NOT EXISTS record_values_integer ON record_values(collection_id,field_id,integer_value,record_id);
             CREATE INDEX IF NOT EXISTS record_values_text ON record_values(collection_id,field_id,text_value,record_id);"
        ).map_err(|error| projection_db(&path, error))?;
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
        for (table, expected) in [
            ("collections", &["id", "name", "description", "deleted"][..]),
            (
                "fields",
                &[
                    "id",
                    "collection_id",
                    "name",
                    "value_kind",
                    "decimal_scale",
                    "required",
                    "order_value",
                    "deleted",
                    "definition_json",
                ][..],
            ),
            (
                "enum_options",
                &["id", "field_id", "label", "order_value", "deleted"][..],
            ),
            ("records", &["id", "collection_id", "deleted"][..]),
            (
                "computed_fields",
                &[
                    "id",
                    "collection_id",
                    "name",
                    "order_value",
                    "deleted",
                    "definition_json",
                ][..],
            ),
            (
                "query_definitions",
                &[
                    "id",
                    "collection_id",
                    "name",
                    "order_value",
                    "deleted",
                    "definition_json",
                ][..],
            ),
            (
                "widgets",
                &[
                    "id",
                    "collection_id",
                    "widget_type",
                    "query_id",
                    "title",
                    "order_value",
                    "deleted",
                    "definition_json",
                ][..],
            ),
            (
                "record_values",
                &[
                    "record_id",
                    "collection_id",
                    "field_id",
                    "value_kind",
                    "integer_value",
                    "text_value",
                    "boolean_value",
                    "physical_time_ms",
                    "logical_counter",
                    "node_id",
                ][..],
            ),
            (
                "projection_diagnostics",
                &["kind", "entity_id", "field_id", "message"][..],
            ),
            (
                "projection_metadata",
                &["singleton", "root_id", "schema_version", "heads"][..],
            ),
        ] {
            let Ok(mut statement) = connection.prepare(&format!("PRAGMA table_info({table})"))
            else {
                return false;
            };
            let Ok(rows) = statement.query_map([], |row| row.get::<_, String>(1)) else {
                return false;
            };
            let Ok(columns) = rows.collect::<rusqlite::Result<Vec<_>>>() else {
                return false;
            };
            if columns.iter().map(String::as_str).collect::<Vec<_>>() != expected {
                return false;
            }
        }
        true
    }

    pub fn checkpoint(&self) -> Result<Option<ProjectionCheckpoint>> {
        let connection = self.lock()?;
        let row: Option<(String, i64, String)> = connection
            .query_row(
                "SELECT root_id,schema_version,heads FROM projection_metadata WHERE singleton=1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|error| projection_db(&self.path, error))?;
        row.map(|(root, schema_version, heads)| {
            let checkpoint = ProjectionCheckpoint {
                root: root
                    .parse()
                    .map_err(|_| ProjectionError::Checkpoint("invalid root id".into()))?,
                schema_version,
                heads,
            };
            checkpoint.validate()?;
            Ok::<_, ProjectionError>(checkpoint)
        })
        .transpose()
        .map_err(AppError::from)
    }

    pub fn replace(
        &self,
        snapshot: &GenericSnapshot,
        checkpoint: &ProjectionCheckpoint,
    ) -> Result<()> {
        checkpoint.validate()?;
        let mut connection = self.lock()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|error| projection_db(&self.path, error))?;
        transaction.execute_batch("DELETE FROM record_values; DELETE FROM projection_diagnostics; DELETE FROM widgets; DELETE FROM query_definitions; DELETE FROM computed_fields; DELETE FROM records; DELETE FROM enum_options; DELETE FROM fields; DELETE FROM collections;").map_err(|error| projection_db(&self.path, error))?;
        for schema in &snapshot.collections {
            transaction
                .execute(
                    "INSERT INTO collections(id,name,description,deleted) VALUES(?1,?2,?3,?4)",
                    params![
                        schema.id.to_string(),
                        schema.name,
                        schema.description,
                        schema.deleted
                    ],
                )
                .map_err(|error| projection_db(&self.path, error))?;
            for field in &schema.fields {
                let (kind, scale) = field_kind(&field.field_type);
                let encoded = serde_json::to_string(field)
                    .map_err(|error| projection_db(&self.path, error))?;
                transaction.execute("INSERT INTO fields(id,collection_id,name,value_kind,decimal_scale,required,order_value,deleted,definition_json) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)", params![field.id.to_string(), schema.id.to_string(), field.name, kind, scale, field.required, field.order, field.deleted, encoded]).map_err(|error| projection_db(&self.path, error))?;
                for option in &field.enum_options {
                    transaction.execute("INSERT INTO enum_options(id,field_id,label,order_value,deleted) VALUES(?1,?2,?3,?4,?5)", params![option.id.to_string(), field.id.to_string(), option.label, option.order, option.deleted]).map_err(|error| projection_db(&self.path, error))?;
                }
            }
        }
        for record in &snapshot.records {
            transaction
                .execute(
                    "INSERT INTO records(id,collection_id,deleted) VALUES(?1,?2,?3)",
                    params![
                        record.id.to_string(),
                        record.collection_id.to_string(),
                        record.deleted
                    ],
                )
                .map_err(|error| projection_db(&self.path, error))?;
            for (field, value) in &record.values {
                let stamp = record
                    .stamps
                    .get(field)
                    .ok_or_else(|| projection_db(&self.path, "record value has no HLC stamp"))?;
                let (kind, integer, text, boolean) = sql_value(value);
                transaction.execute("INSERT INTO record_values(record_id,collection_id,field_id,value_kind,integer_value,text_value,boolean_value,physical_time_ms,logical_counter,node_id) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)", params![record.id.to_string(), record.collection_id.to_string(), field.to_string(), kind, integer, text, boolean, stamp.physical_time_ms, i64::from(stamp.logical_counter), stamp.node_id.to_string()]).map_err(|error| projection_db(&self.path, error))?;
            }
        }
        for definition in &snapshot.computed_fields {
            let encoded = serde_json::to_string(definition)
                .map_err(|error| projection_db(&self.path, error))?;
            transaction.execute("INSERT INTO computed_fields(id,collection_id,name,order_value,deleted,definition_json) VALUES(?1,?2,?3,?4,?5,?6)", params![definition.id.to_string(), definition.collection_id.to_string(), definition.name, definition.order, definition.deleted, encoded]).map_err(|error| projection_db(&self.path, error))?;
        }
        for definition in &snapshot.query_definitions {
            let encoded = serde_json::to_string(definition)
                .map_err(|error| projection_db(&self.path, error))?;
            transaction.execute("INSERT INTO query_definitions(id,collection_id,name,order_value,deleted,definition_json) VALUES(?1,?2,?3,?4,?5,?6)", params![definition.id.to_string(), definition.collection_id.to_string(), definition.name, definition.order, definition.deleted, encoded]).map_err(|error| projection_db(&self.path, error))?;
        }
        // The complete definition stays in `definition_json` so unknown widget types and unknown
        // configuration keys survive a read-model rebuild byte for byte.
        for widget in &snapshot.widgets {
            let encoded =
                serde_json::to_string(widget).map_err(|error| projection_db(&self.path, error))?;
            transaction.execute("INSERT INTO widgets(id,collection_id,widget_type,query_id,title,order_value,deleted,definition_json) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)", params![widget.id.to_string(), widget.collection_id.to_string(), widget.widget_type.to_string(), widget.query_id.to_string(), widget.title, widget.order, widget.deleted, encoded]).map_err(|error| projection_db(&self.path, error))?;
        }
        for diagnostic in &snapshot.diagnostics {
            // `field_id` participates in the STRICT primary key, so an entity-level diagnostic
            // without a field is stored as an empty string rather than NULL.
            transaction.execute("INSERT INTO projection_diagnostics(kind,entity_id,field_id,message) VALUES(?1,?2,?3,?4)", params![diagnostic.kind, diagnostic.entity_id, diagnostic.field_id.map_or_else(String::new, |id| id.to_string()), diagnostic.message]).map_err(|error| projection_db(&self.path, error))?;
        }
        transaction.execute("INSERT INTO projection_metadata(singleton,root_id,schema_version,heads) VALUES(1,?1,?2,?3) ON CONFLICT(singleton) DO UPDATE SET root_id=excluded.root_id,schema_version=excluded.schema_version,heads=excluded.heads", params![checkpoint.root.to_string(), checkpoint.schema_version, checkpoint.heads]).map_err(|error| projection_db(&self.path, error))?;
        transaction
            .commit()
            .map_err(|error| projection_db(&self.path, error))?;
        connection
            .execute_batch("PRAGMA wal_checkpoint(FULL);")
            .map_err(|error| projection_db(&self.path, error))?;
        Ok(())
    }

    pub fn collections(&self) -> Result<Vec<CollectionView>> {
        let connection = self.lock()?;
        let mut statement = connection.prepare("SELECT id,name,description FROM collections WHERE deleted=0 ORDER BY name COLLATE NOCASE,id").map_err(|error| projection_db(&self.path, error))?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get(1)?, row.get(2)?))
            })
            .map_err(|error| projection_db(&self.path, error))?
            .map(|row| {
                let (id, name, description) =
                    row.map_err(|error| projection_db(&self.path, error))?;
                Ok(CollectionView {
                    id: id.parse()?,
                    name,
                    description,
                })
            })
            .collect()
    }

    pub fn schema(&self, id: CollectionSchemaId) -> Result<Option<CollectionSchema>> {
        let connection = self.lock()?;
        let header: Option<(String, String, bool)> = connection
            .query_row(
                "SELECT name,description,deleted FROM collections WHERE id=?1",
                [id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|error| projection_db(&self.path, error))?;
        let Some((name, description, deleted)) = header else {
            return Ok(None);
        };
        let mut statement = connection
            .prepare(
                "SELECT definition_json FROM fields WHERE collection_id=?1 ORDER BY order_value,id",
            )
            .map_err(|error| projection_db(&self.path, error))?;
        let fields = statement
            .query_map([id.to_string()], |row| row.get::<_, String>(0))
            .map_err(|error| projection_db(&self.path, error))?
            .map(|row| {
                serde_json::from_str::<FieldDefinition>(
                    &row.map_err(|error| projection_db(&self.path, error))?,
                )
                .map_err(|error| projection_db(&self.path, error))
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Some(CollectionSchema {
            id,
            name,
            description,
            fields,
            deleted,
        }))
    }

    pub fn records(&self, collection_id: CollectionSchemaId) -> Result<Vec<RecordView>> {
        let connection = self.lock()?;
        let mut statement = connection
            .prepare("SELECT id FROM records WHERE collection_id=?1 AND deleted=0 ORDER BY id")
            .map_err(|error| projection_db(&self.path, error))?;
        let ids = statement
            .query_map([collection_id.to_string()], |row| row.get::<_, String>(0))
            .map_err(|error| projection_db(&self.path, error))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| projection_db(&self.path, error))?;
        ids.into_iter()
            .map(|id| load_record(&connection, &self.path, &id))
            .collect()
    }

    /// Selects candidate records through fixed SQL fragments and bound values only.
    /// Rust still re-evaluates the complete query semantic contract afterward.
    pub fn query_candidates(&self, query: &CollectionQuery) -> Result<Vec<RecordView>> {
        let plan = compile_sqlite_plan(query);
        let connection = self.lock()?;
        let mut statement = connection
            .prepare(&plan.sql)
            .map_err(|error| projection_db(&self.path, error))?;
        let ids = statement
            .query_map(rusqlite::params_from_iter(plan.parameters), |row| {
                row.get::<_, String>(0)
            })
            .map_err(|error| projection_db(&self.path, error))?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(|error| projection_db(&self.path, error))?;
        ids.into_iter()
            .map(|id| load_record(&connection, &self.path, &id))
            .collect()
    }

    pub fn record(&self, id: RecordId) -> Result<Option<RecordView>> {
        let connection = self.lock()?;
        let exists: bool = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM records WHERE id=?1 AND deleted=0)",
                [id.to_string()],
                |row| row.get(0),
            )
            .map_err(|error| projection_db(&self.path, error))?;
        exists
            .then(|| load_record(&connection, &self.path, &id.to_string()))
            .transpose()
    }
    pub fn computed_fields(
        &self,
        collection_id: CollectionSchemaId,
    ) -> Result<Vec<ComputedFieldDefinition>> {
        self.load_definitions(
            "SELECT definition_json FROM computed_fields WHERE collection_id=?1 AND deleted=0 ORDER BY order_value,id",
            collection_id,
        )
    }
    pub fn query_definitions(
        &self,
        collection_id: CollectionSchemaId,
    ) -> Result<Vec<QueryDefinition>> {
        self.load_definitions(
            "SELECT definition_json FROM query_definitions WHERE collection_id=?1 AND deleted=0 ORDER BY order_value,id",
            collection_id,
        )
    }
    /// Active widgets in deterministic order: explicit order first, stable ID as tie breaker.
    pub fn widgets(&self, collection_id: CollectionSchemaId) -> Result<Vec<WidgetDefinition>> {
        self.load_definitions(
            "SELECT definition_json FROM widgets WHERE collection_id=?1 AND deleted=0 ORDER BY order_value,id",
            collection_id,
        )
    }
    /// Projected validation diagnostics for one entity, including merged widget definitions this
    /// device would have rejected locally.
    pub fn entity_diagnostics(&self, entity_id: &str) -> Result<Vec<GenericDiagnostic>> {
        let connection = self.lock()?;
        diagnostics(&connection, &self.path, entity_id)
    }
    /// One widget regardless of tombstone, so an unsupported definition can be read back and
    /// edited through safe metadata changes only.
    pub fn widget(&self, id: WidgetId) -> Result<Option<WidgetDefinition>> {
        let connection = self.lock()?;
        connection
            .query_row(
                "SELECT definition_json FROM widgets WHERE id=?1",
                [id.to_string()],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(|error| projection_db(&self.path, error))?
            .map(|encoded| {
                serde_json::from_str(&encoded).map_err(|error| projection_db(&self.path, error))
            })
            .transpose()
    }
    fn load_definitions<T: serde::de::DeserializeOwned>(
        &self,
        sql: &str,
        collection_id: CollectionSchemaId,
    ) -> Result<Vec<T>> {
        let connection = self.lock()?;
        let mut statement = connection
            .prepare(sql)
            .map_err(|error| projection_db(&self.path, error))?;
        statement
            .query_map([collection_id.to_string()], |row| row.get::<_, String>(0))
            .map_err(|error| projection_db(&self.path, error))?
            .map(|row| {
                serde_json::from_str(&row.map_err(|error| projection_db(&self.path, error))?)
                    .map_err(|error| projection_db(&self.path, error))
            })
            .collect()
    }
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>> {
        self.connection
            .lock()
            .map_err(|_| projection_db(&self.path, "connection lock poisoned"))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct SqliteQueryPlan {
    pub sql: String,
    pub parameters: Vec<Value>,
}

pub(crate) fn compile_sqlite_plan(query: &CollectionQuery) -> SqliteQueryPlan {
    let mut sql = "SELECT r.id FROM records r WHERE r.collection_id=?1 AND r.deleted=0".to_owned();
    let mut parameters = vec![Value::Text(query.collection_id.to_string())];
    let filter_equivalent = query
        .filter
        .as_ref()
        .is_none_or(|filter| push_filter(filter, &mut sql, &mut parameters));
    let mut sort_equivalent = query.sorting.is_empty();
    if let Some(sort) = query.sorting.first()
        && let Expression::Field {
            field: FieldReference::Source(field),
        } = &sort.expression
    {
        sort_equivalent = query.sorting.len() == 1;
        parameters.push(Value::Text(field.to_string()));
        let index = parameters.len();
        let null_direction = match sort.null_order {
            NullOrder::First => "DESC",
            NullOrder::Last => "ASC",
        };
        let direction = match sort.direction {
            SortDirection::Ascending => "ASC",
            SortDirection::Descending => "DESC",
        };
        sql.push_str(&format!(
            " ORDER BY ((SELECT value_kind FROM record_values WHERE record_id=r.id AND field_id=?{index}) IS NULL) {null_direction}, (SELECT COALESCE(integer_value,text_value) FROM record_values WHERE record_id=r.id AND field_id=?{index}) {direction}, r.id ASC"
        ));
    } else {
        sql.push_str(" ORDER BY r.id ASC");
    }
    if filter_equivalent
        && sort_equivalent
        && matches!(
            query.shape,
            crate::query::QueryShape::RecordSet { .. } | crate::query::QueryShape::Series { .. }
        )
        && let Some(limit) = query.limit
    {
        parameters.push(Value::Integer(i64::from(limit)));
        sql.push_str(&format!(" LIMIT ?{}", parameters.len()));
    }
    SqliteQueryPlan { sql, parameters }
}

fn push_filter(expression: &Expression, sql: &mut String, parameters: &mut Vec<Value>) -> bool {
    let Expression::Compare {
        operator,
        left,
        right,
    } = expression
    else {
        return false;
    };
    let (
        Expression::Field {
            field: FieldReference::Source(field),
        },
        Expression::Constant { value },
    ) = (&**left, &**right)
    else {
        return false;
    };
    let Some((column, value)) = sql_typed_value(value) else {
        return false;
    };
    let operator = match operator {
        ComparisonOperator::Equal => "=",
        ComparisonOperator::NotEqual => "!=",
        ComparisonOperator::GreaterThan => ">",
        ComparisonOperator::GreaterThanOrEqual => ">=",
        ComparisonOperator::LessThan => "<",
        ComparisonOperator::LessThanOrEqual => "<=",
    };
    parameters.push(Value::Text(field.to_string()));
    let field_index = parameters.len();
    parameters.push(value);
    let value_index = parameters.len();
    sql.push_str(&format!(
        " AND EXISTS (SELECT 1 FROM record_values rv WHERE rv.record_id=r.id AND rv.field_id=?{field_index} AND rv.{column} {operator} ?{value_index})"
    ));
    true
}

fn sql_typed_value(value: &TypedValue) -> Option<(&'static str, Value)> {
    match value {
        TypedValue::Text(value) => Some(("text_value", Value::Text(value.clone()))),
        TypedValue::Integer(value)
        | TypedValue::Date(value)
        | TypedValue::DateTime(value)
        | TypedValue::Duration(value) => Some(("integer_value", Value::Integer(*value))),
        TypedValue::FixedDecimal { representation, .. } => {
            Some(("integer_value", Value::Integer(*representation)))
        }
        TypedValue::Boolean(value) => Some(("boolean_value", Value::Integer(i64::from(*value)))),
        TypedValue::Enum(value) => Some(("text_value", Value::Text(value.to_string()))),
        TypedValue::Null => None,
    }
}

fn load_record(connection: &Connection, path: &Path, id: &str) -> Result<RecordView> {
    let (record_id, collection_id): (String, String) = connection
        .query_row(
            "SELECT id,collection_id FROM records WHERE id=?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|error| projection_db(path, error))?;
    let mut values = std::collections::BTreeMap::new();
    let mut stamps = std::collections::BTreeMap::new();
    let mut statement = connection.prepare("SELECT field_id,value_kind,integer_value,text_value,boolean_value,physical_time_ms,logical_counter,node_id FROM record_values WHERE record_id=?1 ORDER BY field_id").map_err(|error| projection_db(path, error))?;
    let rows = statement
        .query_map([id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<i64>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<bool>>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, i64>(6)?,
                row.get::<_, String>(7)?,
            ))
        })
        .map_err(|error| projection_db(path, error))?;
    for row in rows {
        let (field, kind, integer, text, boolean, physical, logical, node) =
            row.map_err(|error| projection_db(path, error))?;
        let field = FieldId::from_str(&field)?;
        values.insert(field, decode_sql_value(&kind, integer, text, boolean)?);
        let node = hex::decode(node).map_err(|error| projection_db(path, error))?;
        stamps.insert(
            field,
            crate::hlc::HlcStamp {
                physical_time_ms: physical,
                logical_counter: u32::try_from(logical)
                    .map_err(|error| projection_db(path, error))?,
                node_id: crate::hlc::HlcNodeId(
                    node.try_into()
                        .map_err(|_| projection_db(path, "invalid HLC node id"))?,
                ),
            },
        );
    }
    let diagnostics = diagnostics(connection, path, id)?;
    Ok(RecordView {
        record: GenericRecord {
            id: record_id
                .parse()
                .map_err(|error: crate::records::RecordValidationError| {
                    projection_db(path, error)
                })?,
            collection_id: collection_id.parse()?,
            values,
            stamps,
            deleted: false,
        },
        valid: diagnostics.is_empty(),
        diagnostics,
    })
}
fn diagnostics(
    connection: &Connection,
    path: &Path,
    entity: &str,
) -> Result<Vec<GenericDiagnostic>> {
    let mut statement = connection.prepare("SELECT kind,entity_id,field_id,message FROM projection_diagnostics WHERE entity_id=?1 ORDER BY kind,field_id,message").map_err(|error| projection_db(path, error))?;
    statement
        .query_map([entity], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .map_err(|error| projection_db(path, error))?
        .map(|row| {
            let (kind, entity_id, field_id, message) =
                row.map_err(|error| projection_db(path, error))?;
            Ok(GenericDiagnostic {
                kind,
                entity_id,
                field_id: (!field_id.is_empty())
                    .then(|| field_id.parse())
                    .transpose()?,
                message,
            })
        })
        .collect()
}
fn field_kind(field: &crate::schema::FieldType) -> (&'static str, Option<i64>) {
    use crate::schema::FieldType::*;
    match field {
        Text => ("text", None),
        Integer => ("integer", None),
        FixedDecimal { scale } => ("fixed_decimal", Some(i64::from(*scale))),
        Boolean => ("boolean", None),
        Date => ("date", None),
        DateTime => ("date_time", None),
        Duration => ("duration", None),
        Enum => ("enum", None),
    }
}
fn sql_value(value: &FieldValue) -> (&'static str, Option<i64>, Option<String>, Option<bool>) {
    match value {
        FieldValue::Null => ("null", None, None, None),
        FieldValue::Text(value) => ("text", None, Some(value.clone()), None),
        FieldValue::Integer(value) => ("integer", Some(*value), None, None),
        FieldValue::FixedDecimal(value) => ("fixed_decimal", Some(*value), None, None),
        FieldValue::Boolean(value) => ("boolean", None, None, Some(*value)),
        FieldValue::Date(value) => ("date", Some(*value), None, None),
        FieldValue::DateTime(value) => ("date_time", Some(*value), None, None),
        FieldValue::Duration(value) => ("duration", Some(*value), None, None),
        FieldValue::Enum(value) => ("enum", None, Some(value.to_string()), None),
    }
}
fn decode_sql_value(
    kind: &str,
    integer: Option<i64>,
    text: Option<String>,
    boolean: Option<bool>,
) -> Result<FieldValue> {
    Ok(match kind {
        "null" => FieldValue::Null,
        "text" => {
            FieldValue::Text(text.ok_or_else(|| AppError::Storage("missing text payload".into()))?)
        }
        "integer" => FieldValue::Integer(
            integer.ok_or_else(|| AppError::Storage("missing integer payload".into()))?,
        ),
        "fixed_decimal" => FieldValue::FixedDecimal(
            integer.ok_or_else(|| AppError::Storage("missing decimal payload".into()))?,
        ),
        "boolean" => FieldValue::Boolean(
            boolean.ok_or_else(|| AppError::Storage("missing boolean payload".into()))?,
        ),
        "date" => FieldValue::Date(
            integer.ok_or_else(|| AppError::Storage("missing date payload".into()))?,
        ),
        "date_time" => FieldValue::DateTime(
            integer.ok_or_else(|| AppError::Storage("missing datetime payload".into()))?,
        ),
        "duration" => FieldValue::Duration(
            integer.ok_or_else(|| AppError::Storage("missing duration payload".into()))?,
        ),
        "enum" => FieldValue::Enum(
            text.ok_or_else(|| AppError::Storage("missing enum payload".into()))?
                .parse()?,
        ),
        _ => return Err(AppError::Storage("unsupported projected value kind".into())),
    })
}

pub(crate) async fn capture(handle: &DocHandle) -> Result<(GenericSnapshot, Vec<ChangeHash>)> {
    handle
        .read(|doc| {
            let snapshot = decode_generic(doc);
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
    use crate::{
        APP_SCHEMA_VERSION, QueryId,
        hlc::{HlcNodeId, HlcStamp},
        query::{
            CalendarPolicy, CollectionQuery, ComparisonOperator, Expression, FieldReference,
            QueryShape, TypedValue,
        },
        records::{GenericRecord, RecordId},
        schema::{
            CollectionSchema, CollectionSchemaId, DisplayMetadata, FieldDefinition, FieldId,
            FieldType, ValidationMetadata,
        },
        widgets::{
            StructuredValue, WidgetConfiguration, WidgetDefinition, WidgetId, WidgetLayout,
            WidgetType,
        },
    };
    use std::collections::BTreeMap;
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
    #[test]
    fn corrupt_or_legacy_database_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("read-model.sqlite");
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch("CREATE TABLE categories(id TEXT);")
                .unwrap();
        }
        let model = ReadModel::open_disposable(path).unwrap();
        assert!(model.schema_compatible());
    }

    #[test]
    fn sqlite_planner_whitelists_syntax_and_binds_adversarial_text() {
        let collection_id = CollectionSchemaId::new();
        let field_id = FieldId::new();
        let attack = "x' OR 1=1; DROP TABLE records; --";
        let plan = compile_sqlite_plan(&CollectionQuery {
            collection_id,
            filter: Some(Expression::Compare {
                operator: ComparisonOperator::Equal,
                left: Box::new(Expression::Field {
                    field: FieldReference::Source(field_id),
                }),
                right: Box::new(Expression::Constant {
                    value: TypedValue::Text(attack.into()),
                }),
            }),
            grouping: None,
            shape: QueryShape::RecordSet {
                fields: vec![FieldReference::Source(field_id)],
            },
            sorting: vec![],
            limit: Some(10),
            calendar: CalendarPolicy::default(),
        });
        assert!(!plan.sql.contains(attack));
        assert!(plan.parameters.contains(&Value::Text(attack.into())));
        assert!(plan.sql.contains("rv.text_value = ?3"));
    }

    #[test]
    fn replacement_queries_match_snapshot_and_checkpoint_is_committed_last() {
        let dir = tempfile::tempdir().unwrap();
        let model = ReadModel::open_disposable(dir.path().join("read-model.sqlite")).unwrap();
        let collection_id = CollectionSchemaId::new();
        let field_id = FieldId::new();
        let record_id = RecordId::new();
        let field = FieldDefinition {
            id: field_id,
            name: "Value".into(),
            field_type: FieldType::Integer,
            required: true,
            default: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order: 0,
            deleted: false,
            enum_options: vec![],
        };
        let diagnostic = GenericDiagnostic {
            kind: "record_validation".into(),
            entity_id: record_id.to_string(),
            field_id: Some(field_id),
            message: "repairable conflict".into(),
        };
        let widget_id = WidgetId::new();
        let unknown_widget = WidgetDefinition {
            id: widget_id,
            collection_id,
            widget_type: WidgetType::preserved("com.example.future-widget".into()),
            query_id: QueryId::new(),
            title: "Future".into(),
            configuration: WidgetConfiguration {
                version: 9,
                body: StructuredValue::Map(BTreeMap::from([(
                    "opaque".into(),
                    StructuredValue::List(vec![
                        StructuredValue::Integer(-2350),
                        StructuredValue::Null,
                    ]),
                )])),
            },
            layout: WidgetLayout::default(),
            order: 3,
            deleted: false,
        };
        let snapshot = GenericSnapshot {
            schema_version: APP_SCHEMA_VERSION,
            collections: vec![CollectionSchema {
                id: collection_id,
                name: "Numbers".into(),
                description: String::new(),
                fields: vec![field.clone()],
                deleted: false,
            }],
            records: vec![GenericRecord {
                id: record_id,
                collection_id,
                values: BTreeMap::from([(field_id, FieldValue::Integer(42))]),
                stamps: BTreeMap::from([(
                    field_id,
                    HlcStamp {
                        physical_time_ms: 10,
                        logical_counter: 2,
                        node_id: HlcNodeId([3; 32]),
                    },
                )]),
                deleted: false,
            }],
            computed_fields: vec![],
            query_definitions: vec![],
            widgets: vec![unknown_widget.clone()],
            diagnostics: vec![
                diagnostic.clone(),
                GenericDiagnostic {
                    kind: "widget_validation".into(),
                    entity_id: widget_id.to_string(),
                    field_id: None,
                    message: "query_id: query was not found".into(),
                },
            ],
            max_stamp: None,
        };
        let checkpoint =
            ProjectionCheckpoint::from_heads(DocumentId::new(), &[ChangeHash([7; 32])]);
        model.replace(&snapshot, &checkpoint).unwrap();
        assert_eq!(model.collections().unwrap()[0].id, collection_id);
        assert_eq!(
            model.schema(collection_id).unwrap().unwrap().fields,
            vec![field]
        );
        let projected = model.record(record_id).unwrap().unwrap();
        assert_eq!(projected.record.values[&field_id], FieldValue::Integer(42));
        assert_eq!(projected.diagnostics, vec![diagnostic]);
        assert!(!projected.valid);
        assert_eq!(model.checkpoint().unwrap(), Some(checkpoint.clone()));
        // An unrecognized widget type and its opaque configuration survive the read model intact.
        assert_eq!(model.widgets(collection_id).unwrap(), vec![unknown_widget]);
        assert_eq!(
            model.widget(widget_id).unwrap().unwrap().widget_type,
            WidgetType::preserved("com.example.future-widget".into())
        );
        assert!(
            model
                .entity_diagnostics(&widget_id.to_string())
                .unwrap()
                .iter()
                .any(|item| item.kind == "widget_validation")
        );

        let empty = GenericSnapshot {
            schema_version: APP_SCHEMA_VERSION,
            collections: vec![],
            records: vec![],
            computed_fields: vec![],
            query_definitions: vec![],
            widgets: vec![],
            diagnostics: vec![],
            max_stamp: None,
        };
        let next = ProjectionCheckpoint::from_heads(checkpoint.root, &[ChangeHash([8; 32])]);
        model.replace(&empty, &next).unwrap();
        assert!(model.collections().unwrap().is_empty());
        assert_eq!(model.checkpoint().unwrap(), Some(next));
    }
}
