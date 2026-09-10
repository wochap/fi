use std::{
    collections::{BTreeMap, HashSet},
    str::FromStr,
};

use automerge::{
    Automerge, ObjId, ObjType, ROOT, ReadDoc,
    transaction::{Transactable, Transaction as AutomergeTransaction},
};
use serde::{Deserialize, Serialize};

use crate::{
    error::DomainError,
    hlc::HlcStamp,
    query::{
        ComputedFieldDefinition, ComputedFieldId, QueryDefinition, QueryId,
        validate_computed_field, validate_query,
    },
    records::{
        GenericRecord, RecordId, read_lww_candidates, read_lww_winner, validate_record,
        write_lww_register,
    },
    schema::{
        CollectionSchema, CollectionSchemaId, EnumOption, EnumOptionId, FieldDefinition, FieldId,
    },
    values::FieldValue,
    widget_registry::{QueryResultShape, descriptor_for, validate_widget_configuration},
    widgets::{
        WidgetConfiguration, WidgetDefinition, WidgetId, WidgetLayout, WidgetType, WidgetUpdate,
        validate_title,
    },
};

pub const APP_SCHEMA_VERSION: i64 = 4;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct GenericDiagnostic {
    pub kind: String,
    pub entity_id: String,
    pub field_id: Option<FieldId>,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GenericSnapshot {
    pub schema_version: i64,
    pub collections: Vec<CollectionSchema>,
    pub records: Vec<GenericRecord>,
    pub computed_fields: Vec<ComputedFieldDefinition>,
    pub query_definitions: Vec<QueryDefinition>,
    pub widgets: Vec<WidgetDefinition>,
    pub diagnostics: Vec<GenericDiagnostic>,
    pub max_stamp: Option<HlcStamp>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollectionView {
    pub id: CollectionSchemaId,
    pub name: String,
    pub description: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordView {
    pub record: GenericRecord,
    pub valid: bool,
    pub diagnostics: Vec<GenericDiagnostic>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GenericCommand {
    CreateCollection(CollectionSchema),
    RenameCollection {
        id: CollectionSchemaId,
        name: String,
    },
    DeleteCollection(CollectionSchemaId),
    AddField {
        collection_id: CollectionSchemaId,
        field: FieldDefinition,
    },
    UpdateField {
        collection_id: CollectionSchemaId,
        field: FieldDefinition,
    },
    RemoveField {
        collection_id: CollectionSchemaId,
        field_id: FieldId,
    },
    ReorderFields {
        collection_id: CollectionSchemaId,
        field_ids: Vec<FieldId>,
    },
    UpsertEnumOption {
        collection_id: CollectionSchemaId,
        field_id: FieldId,
        option: EnumOption,
    },
    RemoveEnumOption {
        collection_id: CollectionSchemaId,
        field_id: FieldId,
        option_id: EnumOptionId,
    },
    CreateRecord(GenericRecord),
    UpdateRecordField {
        record_id: RecordId,
        field_id: FieldId,
        value: FieldValue,
    },
    DeleteRecord(RecordId),
    CreateComputedField(ComputedFieldDefinition),
    UpdateComputedField(ComputedFieldDefinition),
    RemoveComputedField {
        collection_id: CollectionSchemaId,
        id: ComputedFieldId,
    },
    ReorderComputedFields {
        collection_id: CollectionSchemaId,
        ids: Vec<ComputedFieldId>,
    },
    CreateQuery(QueryDefinition),
    UpdateQuery(QueryDefinition),
    RemoveQuery {
        collection_id: CollectionSchemaId,
        id: QueryId,
    },
    ReorderQueries {
        collection_id: CollectionSchemaId,
        ids: Vec<QueryId>,
    },
    CreateWidget(WidgetDefinition),
    UpdateWidget(WidgetUpdate),
    RemoveWidget {
        collection_id: CollectionSchemaId,
        id: WidgetId,
    },
    ReorderWidgets {
        collection_id: CollectionSchemaId,
        ids: Vec<WidgetId>,
    },
}

impl GenericCommand {
    pub fn validate_against(&mut self, snapshot: &GenericSnapshot) -> Result<(), DomainError> {
        match self {
            Self::CreateCollection(schema) => {
                schema.validate()?;
                if snapshot.collections.iter().any(|item| item.id == schema.id) {
                    return Err(invalid("collection_id", "already exists"));
                }
            }
            Self::RenameCollection { id, name } => {
                validate_name(name)?;
                active_collection(snapshot, *id)?;
            }
            Self::DeleteCollection(id) => {
                collection(snapshot, *id)?;
            }
            Self::AddField {
                collection_id,
                field,
            } => {
                field.validate()?;
                let schema = active_collection(snapshot, *collection_id)?;
                if schema.fields.iter().any(|item| item.id == field.id) {
                    return Err(invalid("field_id", "already exists"));
                }
                validate_required_evolution(field, snapshot, schema.id)?;
            }
            Self::UpdateField {
                collection_id,
                field,
            } => {
                field.validate()?;
                let schema = active_collection(snapshot, *collection_id)?;
                let prior = schema
                    .fields
                    .iter()
                    .find(|item| item.id == field.id && !item.deleted)
                    .ok_or_else(|| not_found("field", field.id))?;
                let populated = snapshot.records.iter().any(|record| {
                    !record.deleted
                        && record.collection_id == *collection_id
                        && record.values.contains_key(&field.id)
                });
                if populated && prior.field_type != field.field_type {
                    return Err(invalid(
                        "field_type",
                        "cannot change a populated field type or decimal scale",
                    ));
                }
                validate_required_evolution(field, snapshot, schema.id)?;
            }
            Self::RemoveField {
                collection_id,
                field_id,
            } => {
                let schema = active_collection(snapshot, *collection_id)?;
                schema
                    .fields
                    .iter()
                    .any(|field| field.id == *field_id)
                    .then_some(())
                    .ok_or_else(|| not_found("field", field_id))?;
            }
            Self::ReorderFields {
                collection_id,
                field_ids,
            } => {
                let schema = active_collection(snapshot, *collection_id)?;
                let active: HashSet<_> = schema
                    .fields
                    .iter()
                    .filter(|field| !field.deleted)
                    .map(|field| field.id)
                    .collect();
                let requested: HashSet<_> = field_ids.iter().copied().collect();
                if requested.len() != field_ids.len() || requested != active {
                    return Err(invalid(
                        "field_ids",
                        "must contain every active field exactly once",
                    ));
                }
            }
            Self::UpsertEnumOption {
                collection_id,
                field_id,
                option,
            } => {
                validate_name(&option.label)?;
                let field = active_field(snapshot, *collection_id, *field_id)?;
                if !matches!(field.field_type, crate::schema::FieldType::Enum) {
                    return Err(invalid("field_id", "is not an Enum field"));
                }
            }
            Self::RemoveEnumOption {
                collection_id,
                field_id,
                option_id,
            } => {
                let field = active_field(snapshot, *collection_id, *field_id)?;
                if !field
                    .enum_options
                    .iter()
                    .any(|option| option.id == *option_id)
                {
                    return Err(not_found("enum option", option_id));
                }
                if snapshot.records.iter().any(|record| {
                    !record.deleted
                        && record.collection_id == *collection_id
                        && record.values.get(field_id) == Some(&FieldValue::Enum(*option_id))
                }) {
                    return Err(invalid(
                        "enum_option_id",
                        "cannot remove an option referenced by an active record",
                    ));
                }
            }
            Self::CreateRecord(record) => {
                if snapshot.records.iter().any(|item| item.id == record.id) {
                    return Err(invalid("record_id", "already exists"));
                }
                let schema = active_collection(snapshot, record.collection_id)?;
                validate_record(record, schema, true)
                    .map_err(|error| invalid("record", error.to_string()))?;
            }
            Self::UpdateRecordField {
                record_id,
                field_id,
                value,
            } => {
                let record = active_record(snapshot, *record_id)?;
                let field = active_field(snapshot, record.collection_id, *field_id)?;
                field.validate_value(value, false)?;
            }
            Self::DeleteRecord(id) => {
                record(snapshot, *id)?;
            }
            Self::CreateComputedField(definition) => {
                let schema = active_collection(snapshot, definition.collection_id)?;
                if snapshot
                    .computed_fields
                    .iter()
                    .any(|item| item.id == definition.id)
                {
                    return Err(invalid("computed_field_id", "already exists"));
                }
                validate_computed_field(definition, schema)
                    .map_err(|error| invalid("computed_field", error.to_string()))?;
            }
            Self::UpdateComputedField(definition) => {
                let schema = active_collection(snapshot, definition.collection_id)?;
                active_computed(snapshot, definition.collection_id, definition.id)?;
                validate_computed_field(definition, schema)
                    .map_err(|error| invalid("computed_field", error.to_string()))?;
            }
            Self::RemoveComputedField { collection_id, id } => {
                active_collection(snapshot, *collection_id)?;
                active_computed(snapshot, *collection_id, *id)?;
            }
            Self::ReorderComputedFields { collection_id, ids } => {
                active_collection(snapshot, *collection_id)?;
                validate_reorder(
                    ids,
                    snapshot
                        .computed_fields
                        .iter()
                        .filter(|item| item.collection_id == *collection_id && !item.deleted)
                        .map(|item| item.id),
                    "computed_field_ids",
                )?;
            }
            Self::CreateQuery(definition) => {
                let schema = active_collection(snapshot, definition.collection_id)?;
                if snapshot
                    .query_definitions
                    .iter()
                    .any(|item| item.id == definition.id)
                {
                    return Err(invalid("query_id", "already exists"));
                }
                validate_name(&definition.name)?;
                let query = definition
                    .query
                    .query()
                    .map_err(|error| invalid("query", error.to_string()))?;
                validate_query(&query, schema, &snapshot.computed_fields)
                    .map_err(|error| invalid("query", error.to_string()))?;
            }
            Self::UpdateQuery(definition) => {
                let schema = active_collection(snapshot, definition.collection_id)?;
                active_query(snapshot, definition.collection_id, definition.id)?;
                validate_name(&definition.name)?;
                let query = definition
                    .query
                    .query()
                    .map_err(|error| invalid("query", error.to_string()))?;
                validate_query(&query, schema, &snapshot.computed_fields)
                    .map_err(|error| invalid("query", error.to_string()))?;
            }
            Self::RemoveQuery { collection_id, id } => {
                active_collection(snapshot, *collection_id)?;
                active_query(snapshot, *collection_id, *id)?;
            }
            Self::ReorderQueries { collection_id, ids } => {
                active_collection(snapshot, *collection_id)?;
                validate_reorder(
                    ids,
                    snapshot
                        .query_definitions
                        .iter()
                        .filter(|item| item.collection_id == *collection_id && !item.deleted)
                        .map(|item| item.id),
                    "query_ids",
                )?;
            }
            Self::CreateWidget(definition) => {
                active_collection(snapshot, definition.collection_id)?;
                definition
                    .validate_standalone()
                    .map_err(|error| invalid("widget", error.to_string()))?;
                if definition.deleted {
                    return Err(invalid("widget", "cannot create a removed widget"));
                }
                if snapshot.widgets.iter().any(|item| item.id == definition.id) {
                    return Err(invalid("widget_id", "already exists"));
                }
                validate_widget_query(
                    &snapshot.query_definitions,
                    &definition.widget_type,
                    definition.query_id,
                )?;
            }
            Self::UpdateWidget(update) => {
                active_collection(snapshot, update.collection_id)?;
                let existing = active_widget(snapshot, update.collection_id, update.id)?;
                if update.is_empty() {
                    return Err(invalid("widget", "update changes nothing"));
                }
                if let Some(title) = &update.title {
                    validate_title(title).map_err(|error| invalid("title", error.to_string()))?;
                }
                if let Some(configuration) = &update.configuration {
                    validate_widget_configuration(existing.widget_type.as_str(), configuration)
                        .map_err(|error| invalid("configuration", error.to_string()))?;
                }
                if let Some(layout) = &update.layout {
                    layout
                        .validate()
                        .map_err(|error| invalid("layout", error.to_string()))?;
                }
                if let Some(query_id) = update.query_id {
                    validate_widget_query(
                        &snapshot.query_definitions,
                        &existing.widget_type,
                        query_id,
                    )?;
                }
            }
            Self::RemoveWidget { collection_id, id } => {
                active_collection(snapshot, *collection_id)?;
                active_widget(snapshot, *collection_id, *id)?;
            }
            Self::ReorderWidgets { collection_id, ids } => {
                active_collection(snapshot, *collection_id)?;
                validate_reorder(
                    ids,
                    snapshot
                        .widgets
                        .iter()
                        .filter(|item| item.collection_id == *collection_id && !item.deleted)
                        .map(|item| item.id),
                    "widget_ids",
                )?;
            }
        }
        Ok(())
    }
}

/// Checks that a widget's referenced query exists, decodes, and produces a result shape the
/// widget descriptor accepts. Unknown widget types are valid preserved data and are only checked
/// for query existence, never coerced into a built-in contract.
fn validate_widget_query(
    query_definitions: &[QueryDefinition],
    widget_type: &WidgetType,
    query_id: QueryId,
) -> Result<(), DomainError> {
    let definition = query_definitions
        .iter()
        .find(|item| item.id == query_id && !item.deleted)
        .ok_or_else(|| not_found("query", query_id))?;
    let Some(descriptor) = descriptor_for(widget_type.as_str()) else {
        return Ok(());
    };
    let query = definition
        .query
        .query()
        .map_err(|error| invalid("query_id", error.to_string()))?;
    if query.collection_id != definition.collection_id {
        return Err(invalid(
            "query_id",
            "references a query from another collection",
        ));
    }
    if descriptor.accepts(&query.shape) {
        Ok(())
    } else {
        let accepted = descriptor
            .accepted_shapes
            .iter()
            .copied()
            .map(QueryResultShape::label)
            .collect::<Vec<_>>()
            .join(" or ");
        Err(invalid(
            "query_id",
            format!(
                "returns a {} result but {} accepts {}",
                QueryResultShape::from(&query.shape).label(),
                descriptor.widget_type,
                accepted
            ),
        ))
    }
}

fn widget_diagnostic(
    query_definitions: &[QueryDefinition],
    widget: &WidgetDefinition,
) -> Option<String> {
    if let Err(error) = widget.validate_standalone() {
        return Some(error.to_string());
    }
    validate_widget_query(query_definitions, &widget.widget_type, widget.query_id)
        .err()
        .map(|error| error.to_string())
}

pub fn initialize_generic(tx: &mut AutomergeTransaction<'_>) -> automerge_repo::Result<()> {
    let app = tx
        .put_object(ROOT, "application", ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&app, "schema_version", APP_SCHEMA_VERSION)
        .map_err(repo_change)?;
    tx.put_object(&app, "collections", ObjType::Map)
        .map_err(repo_change)?;
    tx.put_object(&app, "records", ObjType::Map)
        .map_err(repo_change)?;
    Ok(())
}

pub fn apply_generic_command(
    tx: &mut AutomergeTransaction<'_>,
    command: &GenericCommand,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let app = object(tx, &ROOT, "application").map_err(repo_change)?;
    let collections = object(tx, &app, "collections").map_err(repo_change)?;
    let records = object(tx, &app, "records").map_err(repo_change)?;
    match command {
        GenericCommand::CreateCollection(schema) => {
            write_collection(tx, &collections, schema, stamp)?
        }
        GenericCommand::RenameCollection { id, name } => {
            let collection = object(tx, &collections, &id.to_string()).map_err(repo_change)?;
            write_lww_register(
                tx,
                &collection,
                "name",
                &FieldValue::Text(name.trim().into()),
                stamp,
            )?;
        }
        GenericCommand::DeleteCollection(id) => {
            let collection = object(tx, &collections, &id.to_string()).map_err(repo_change)?;
            write_lww_register(
                tx,
                &collection,
                "deleted",
                &FieldValue::Boolean(true),
                stamp,
            )?;
        }
        GenericCommand::AddField {
            collection_id,
            field,
        } => {
            let fields =
                collection_fields(tx, &collections, *collection_id).map_err(repo_change)?;
            write_field(tx, &fields, field, stamp)?;
        }
        GenericCommand::UpdateField {
            collection_id,
            field,
        } => {
            let fields =
                collection_fields(tx, &collections, *collection_id).map_err(repo_change)?;
            let entry = object(tx, &fields, &field.id.to_string()).map_err(repo_change)?;
            write_field_definition(tx, &entry, field, stamp)?;
        }
        GenericCommand::RemoveField {
            collection_id,
            field_id,
        } => {
            let fields =
                collection_fields(tx, &collections, *collection_id).map_err(repo_change)?;
            let entry = object(tx, &fields, &field_id.to_string()).map_err(repo_change)?;
            let mut field = decode_field(tx, &entry).map_err(repo_change)?;
            field.deleted = true;
            write_field_definition(tx, &entry, &field, stamp)?;
        }
        GenericCommand::ReorderFields {
            collection_id,
            field_ids,
        } => {
            let fields =
                collection_fields(tx, &collections, *collection_id).map_err(repo_change)?;
            for (order, id) in field_ids.iter().enumerate() {
                let entry = object(tx, &fields, &id.to_string()).map_err(repo_change)?;
                let mut field = decode_field(tx, &entry).map_err(repo_change)?;
                field.order = order as i64;
                write_field_definition(tx, &entry, &field, stamp)?;
            }
        }
        GenericCommand::UpsertEnumOption {
            collection_id,
            field_id,
            option,
        } => {
            let fields =
                collection_fields(tx, &collections, *collection_id).map_err(repo_change)?;
            let entry = object(tx, &fields, &field_id.to_string()).map_err(repo_change)?;
            let mut field = decode_field(tx, &entry).map_err(repo_change)?;
            if let Some(existing) = field
                .enum_options
                .iter_mut()
                .find(|existing| existing.id == option.id)
            {
                *existing = option.clone();
            } else {
                field.enum_options.push(option.clone());
            }
            write_field_definition(tx, &entry, &field, stamp)?;
        }
        GenericCommand::RemoveEnumOption {
            collection_id,
            field_id,
            option_id,
        } => {
            let fields =
                collection_fields(tx, &collections, *collection_id).map_err(repo_change)?;
            let entry = object(tx, &fields, &field_id.to_string()).map_err(repo_change)?;
            let mut field = decode_field(tx, &entry).map_err(repo_change)?;
            field
                .enum_options
                .iter_mut()
                .find(|option| option.id == *option_id)
                .ok_or_else(|| repo_change("enum option not found"))?
                .deleted = true;
            write_field_definition(tx, &entry, &field, stamp)?;
        }
        GenericCommand::CreateRecord(record) => write_record(tx, &records, record, stamp)?,
        GenericCommand::UpdateRecordField {
            record_id,
            field_id,
            value,
        } => {
            let record = object(tx, &records, &record_id.to_string()).map_err(repo_change)?;
            let values = object(tx, &record, "values").map_err(repo_change)?;
            write_lww_register(tx, &values, &field_id.to_string(), value, stamp)?;
        }
        GenericCommand::DeleteRecord(id) => {
            let record = object(tx, &records, &id.to_string()).map_err(repo_change)?;
            write_lww_register(tx, &record, "deleted", &FieldValue::Boolean(true), stamp)?;
        }
        GenericCommand::CreateComputedField(definition)
        | GenericCommand::UpdateComputedField(definition) => write_definition(
            tx,
            &collections,
            definition.collection_id,
            "computed_fields",
            &definition.id.to_string(),
            definition,
            stamp,
        )?,
        GenericCommand::RemoveComputedField { collection_id, id } => {
            let entry = definition_entry(
                tx,
                &collections,
                *collection_id,
                "computed_fields",
                &id.to_string(),
            )
            .map_err(repo_change)?;
            let mut definition =
                decode_definition::<ComputedFieldDefinition>(tx, &entry).map_err(repo_change)?;
            definition.deleted = true;
            write_definition(
                tx,
                &collections,
                *collection_id,
                "computed_fields",
                &id.to_string(),
                &definition,
                stamp,
            )?;
        }
        GenericCommand::ReorderComputedFields { collection_id, ids } => {
            for (order, id) in ids.iter().enumerate() {
                let entry = definition_entry(
                    tx,
                    &collections,
                    *collection_id,
                    "computed_fields",
                    &id.to_string(),
                )
                .map_err(repo_change)?;
                let mut definition = decode_definition::<ComputedFieldDefinition>(tx, &entry)
                    .map_err(repo_change)?;
                definition.order = order as i64;
                write_definition(
                    tx,
                    &collections,
                    *collection_id,
                    "computed_fields",
                    &id.to_string(),
                    &definition,
                    stamp,
                )?;
            }
        }
        GenericCommand::CreateQuery(definition) | GenericCommand::UpdateQuery(definition) => {
            write_definition(
                tx,
                &collections,
                definition.collection_id,
                "queries",
                &definition.id.to_string(),
                definition,
                stamp,
            )?;
        }
        GenericCommand::RemoveQuery { collection_id, id } => {
            let entry =
                definition_entry(tx, &collections, *collection_id, "queries", &id.to_string())
                    .map_err(repo_change)?;
            let mut definition =
                decode_definition::<QueryDefinition>(tx, &entry).map_err(repo_change)?;
            definition.deleted = true;
            write_definition(
                tx,
                &collections,
                *collection_id,
                "queries",
                &id.to_string(),
                &definition,
                stamp,
            )?;
        }
        GenericCommand::ReorderQueries { collection_id, ids } => {
            for (order, id) in ids.iter().enumerate() {
                let entry =
                    definition_entry(tx, &collections, *collection_id, "queries", &id.to_string())
                        .map_err(repo_change)?;
                let mut definition =
                    decode_definition::<QueryDefinition>(tx, &entry).map_err(repo_change)?;
                definition.order = order as i64;
                write_definition(
                    tx,
                    &collections,
                    *collection_id,
                    "queries",
                    &id.to_string(),
                    &definition,
                    stamp,
                )?;
            }
        }
        GenericCommand::CreateWidget(definition) => {
            write_widget(tx, &collections, definition, stamp)?
        }
        GenericCommand::UpdateWidget(update) => {
            let entry = widget_entry(
                tx,
                &collections,
                update.collection_id,
                &update.id.to_string(),
            )
            .map_err(repo_change)?;
            if let Some(title) = &update.title {
                write_lww_register(
                    tx,
                    &entry,
                    "title",
                    &FieldValue::Text(title.trim().into()),
                    stamp,
                )?;
            }
            if let Some(query_id) = update.query_id {
                write_lww_register(
                    tx,
                    &entry,
                    "query_id",
                    &FieldValue::Text(query_id.to_string()),
                    stamp,
                )?;
            }
            // Each present field writes only its own register, so an omitted field — notably an
            // unknown widget's opaque configuration — is never rewritten by an unrelated edit.
            if let Some(configuration) = &update.configuration {
                write_widget_json(tx, &entry, "configuration", configuration, stamp)?;
            }
            if let Some(layout) = &update.layout {
                write_widget_json(tx, &entry, "layout", layout, stamp)?;
            }
            if let Some(order) = update.order {
                write_lww_register(tx, &entry, "order", &FieldValue::Integer(order), stamp)?;
            }
        }
        GenericCommand::RemoveWidget { collection_id, id } => {
            let entry = widget_entry(tx, &collections, *collection_id, &id.to_string())
                .map_err(repo_change)?;
            write_lww_register(tx, &entry, "deleted", &FieldValue::Boolean(true), stamp)?;
        }
        GenericCommand::ReorderWidgets { collection_id, ids } => {
            for (order, id) in ids.iter().enumerate() {
                let entry = widget_entry(tx, &collections, *collection_id, &id.to_string())
                    .map_err(repo_change)?;
                write_lww_register(
                    tx,
                    &entry,
                    "order",
                    &FieldValue::Integer(order as i64),
                    stamp,
                )?;
            }
        }
    }
    Ok(())
}

fn widget_entry(
    doc: &impl ReadDoc,
    collections: &ObjId,
    collection_id: CollectionSchemaId,
    id: &str,
) -> Result<ObjId, DomainError> {
    definition_entry(doc, collections, collection_id, "widgets", id)
}

fn write_widget_json<T: Serialize>(
    tx: &mut AutomergeTransaction<'_>,
    entry: &ObjId,
    property: &str,
    value: &T,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let encoded = serde_json::to_string(value).map_err(repo_change)?;
    write_lww_register(tx, entry, property, &FieldValue::Text(encoded), stamp)
}

fn write_widget(
    tx: &mut AutomergeTransaction<'_>,
    collections: &ObjId,
    definition: &WidgetDefinition,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let collection =
        object(tx, collections, &definition.collection_id.to_string()).map_err(repo_change)?;
    let widgets = object(tx, &collection, "widgets").map_err(repo_change)?;
    let entry = tx
        .put_object(&widgets, definition.id.to_string(), ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&entry, "id", definition.id.to_string())
        .map_err(repo_change)?;
    tx.put(
        &entry,
        "collection_id",
        definition.collection_id.to_string(),
    )
    .map_err(repo_change)?;
    write_lww_register(
        tx,
        &entry,
        "widget_type",
        &FieldValue::Text(definition.widget_type.to_string()),
        stamp,
    )?;
    write_lww_register(
        tx,
        &entry,
        "title",
        &FieldValue::Text(definition.title.trim().into()),
        stamp,
    )?;
    write_lww_register(
        tx,
        &entry,
        "query_id",
        &FieldValue::Text(definition.query_id.to_string()),
        stamp,
    )?;
    write_widget_json(
        tx,
        &entry,
        "configuration",
        &definition.configuration,
        stamp,
    )?;
    write_widget_json(tx, &entry, "layout", &definition.layout, stamp)?;
    write_lww_register(
        tx,
        &entry,
        "order",
        &FieldValue::Integer(definition.order),
        stamp,
    )?;
    write_lww_register(
        tx,
        &entry,
        "deleted",
        &FieldValue::Boolean(definition.deleted),
        stamp,
    )
}

pub fn decode_generic(doc: &Automerge) -> Result<GenericSnapshot, DomainError> {
    let app = match doc.get(ROOT, "application").map_err(malformed)? {
        Some((value, object)) if value.is_object() => object,
        Some(_) => return Err(malformed("application is not an object")),
        None if doc.get(ROOT, "finance").map_err(malformed)?.is_some() => {
            return Err(DomainError::UnsupportedSchema(1));
        }
        None => return Err(malformed("missing application")),
    };
    let schema_version = integer(doc, &app, "schema_version")?;
    if schema_version != APP_SCHEMA_VERSION {
        return Err(DomainError::UnsupportedSchema(schema_version));
    }
    let collections_map = object(doc, &app, "collections")?;
    let records_map = object(doc, &app, "records")?;
    let mut max_stamp = None;
    let mut collections = Vec::new();
    let mut computed_fields = Vec::new();
    let mut query_definitions = Vec::new();
    let mut widgets = Vec::new();
    for key in doc.keys(&collections_map) {
        let entry = object(doc, &collections_map, &key)?;
        let id = CollectionSchemaId::from_str(&string(doc, &entry, "id")?)?;
        if id.to_string() != key {
            return Err(malformed("collection key/id mismatch"));
        }
        let name = expect_text(
            read_winner_tracking(doc, &entry, "name", &mut max_stamp)?,
            "name",
        )?;
        let description = expect_text(
            read_winner_tracking(doc, &entry, "description", &mut max_stamp)?,
            "description",
        )?;
        let deleted = expect_bool(
            read_winner_tracking(doc, &entry, "deleted", &mut max_stamp)?,
            "deleted",
        )?;
        let fields_map = object(doc, &entry, "fields")?;
        let mut fields = Vec::new();
        for field_key in doc.keys(&fields_map) {
            let field_entry = object(doc, &fields_map, &field_key)?;
            let field = decode_field_tracking(doc, &field_entry, &mut max_stamp)?;
            if field.id.to_string() != field_key {
                return Err(malformed("field key/id mismatch"));
            }
            fields.push(field);
        }
        fields.sort_by_key(|field| (field.order, field.id));
        let computed_map = object(doc, &entry, "computed_fields")?;
        for definition_key in doc.keys(&computed_map) {
            let definition_entry = object(doc, &computed_map, &definition_key)?;
            let definition: ComputedFieldDefinition =
                decode_definition_tracking(doc, &definition_entry, &mut max_stamp)?;
            if definition.id.to_string() != definition_key || definition.collection_id != id {
                return Err(malformed("computed definition key/id mismatch"));
            }
            computed_fields.push(definition);
        }
        let query_map = object(doc, &entry, "queries")?;
        for definition_key in doc.keys(&query_map) {
            let definition_entry = object(doc, &query_map, &definition_key)?;
            let definition: QueryDefinition =
                decode_definition_tracking(doc, &definition_entry, &mut max_stamp)?;
            if definition.id.to_string() != definition_key || definition.collection_id != id {
                return Err(malformed("query definition key/id mismatch"));
            }
            query_definitions.push(definition);
        }
        let widget_map = object(doc, &entry, "widgets")?;
        for widget_key in doc.keys(&widget_map) {
            let widget_entry = object(doc, &widget_map, &widget_key)?;
            let widget = decode_widget_tracking(doc, &widget_entry, &mut max_stamp)?;
            if widget.id.to_string() != widget_key || widget.collection_id != id {
                return Err(malformed("widget key/id mismatch"));
            }
            widgets.push(widget);
        }
        collections.push(CollectionSchema {
            id,
            name,
            description,
            fields,
            deleted,
        });
    }
    collections.sort_by_key(|schema| schema.id);
    computed_fields.sort_by_key(|field| (field.collection_id, field.order, field.id));
    query_definitions.sort_by_key(|query| (query.collection_id, query.order, query.id));
    widgets.sort_by_key(|widget| (widget.collection_id, widget.order, widget.id));
    let mut records = Vec::new();
    for key in doc.keys(&records_map) {
        let entry = object(doc, &records_map, &key)?;
        let id = RecordId::from_str(&string(doc, &entry, "id")?)
            .map_err(|error| malformed(error.to_string()))?;
        if id.to_string() != key {
            return Err(malformed("record key/id mismatch"));
        }
        let collection_id = CollectionSchemaId::from_str(&string(doc, &entry, "collection_id")?)?;
        let deleted = expect_bool(
            read_winner_tracking(doc, &entry, "deleted", &mut max_stamp)?,
            "deleted",
        )?;
        let values_map = object(doc, &entry, "values")?;
        let mut values = BTreeMap::new();
        let mut stamps = BTreeMap::new();
        for field_key in doc.keys(&values_map) {
            let field_id = FieldId::from_str(&field_key)?;
            let candidates = read_lww_candidates(doc, &values_map, &field_key)?;
            let winner = candidates
                .into_iter()
                .max_by_key(|candidate| candidate.stamp)
                .ok_or_else(|| malformed("empty field register"))?;
            max_stamp = Some(max_stamp.map_or(winner.stamp, |current| current.max(winner.stamp)));
            values.insert(field_id, winner.value);
            stamps.insert(field_id, winner.stamp);
        }
        records.push(GenericRecord {
            id,
            collection_id,
            values,
            stamps,
            deleted,
        });
    }
    records.sort_by_key(|record| record.id);
    let mut diagnostics = Vec::new();
    for schema in &collections {
        if let Err(error) = schema.validate() {
            diagnostics.push(GenericDiagnostic {
                kind: "schema_validation".into(),
                entity_id: schema.id.to_string(),
                field_id: None,
                message: error.to_string(),
            });
        }
    }
    for record in &records {
        let Some(schema) = collections
            .iter()
            .find(|schema| schema.id == record.collection_id)
        else {
            diagnostics.push(GenericDiagnostic {
                kind: "missing_collection".into(),
                entity_id: record.id.to_string(),
                field_id: None,
                message: "record collection is unavailable".into(),
            });
            continue;
        };
        let mut checked = record.clone();
        if let Err(error) = validate_record(&mut checked, schema, false) {
            diagnostics.push(GenericDiagnostic {
                kind: "record_validation".into(),
                entity_id: record.id.to_string(),
                field_id: match error {
                    crate::records::RecordValidationError::FieldUnavailable(id)
                    | crate::records::RecordValidationError::MissingRequired(id) => Some(id),
                    crate::records::RecordValidationError::InvalidValue { field, .. } => {
                        Some(field)
                    }
                    _ => None,
                },
                message: error.to_string(),
            });
        }
    }
    for definition in &computed_fields {
        let result = collections
            .iter()
            .find(|schema| schema.id == definition.collection_id)
            .ok_or_else(|| {
                crate::query::QueryValidationError::new(
                    "collection_id",
                    "collection is unavailable",
                )
            })
            .and_then(|schema| validate_computed_field(definition, schema));
        if let Err(error) = result {
            diagnostics.push(GenericDiagnostic {
                kind: "computed_field_validation".into(),
                entity_id: definition.id.to_string(),
                field_id: None,
                message: error.to_string(),
            });
        }
    }
    for definition in &query_definitions {
        let result = definition.query.query().and_then(|query| {
            collections
                .iter()
                .find(|schema| schema.id == definition.collection_id)
                .ok_or_else(|| {
                    crate::query::QueryValidationError::new(
                        "collection_id",
                        "collection is unavailable",
                    )
                })
                .and_then(|schema| validate_query(&query, schema, &computed_fields))
        });
        if let Err(error) = result {
            diagnostics.push(GenericDiagnostic {
                kind: "query_validation".into(),
                entity_id: definition.id.to_string(),
                field_id: None,
                message: error.to_string(),
            });
        }
    }
    for widget in &widgets {
        // Merged data can violate contracts this device never accepted locally. Those widgets stay
        // preserved and surface as diagnostics plus typed per-widget evaluation errors.
        if let Some(message) = widget_diagnostic(&query_definitions, widget) {
            diagnostics.push(GenericDiagnostic {
                kind: "widget_validation".into(),
                entity_id: widget.id.to_string(),
                field_id: None,
                message,
            });
        }
    }
    Ok(GenericSnapshot {
        schema_version,
        collections,
        records,
        computed_fields,
        query_definitions,
        widgets,
        diagnostics,
        max_stamp,
    })
}

fn write_collection(
    tx: &mut AutomergeTransaction<'_>,
    collections: &ObjId,
    schema: &CollectionSchema,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let entry = tx
        .put_object(collections, schema.id.to_string(), ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&entry, "id", schema.id.to_string())
        .map_err(repo_change)?;
    write_lww_register(
        tx,
        &entry,
        "name",
        &FieldValue::Text(schema.name.trim().into()),
        stamp,
    )?;
    write_lww_register(
        tx,
        &entry,
        "description",
        &FieldValue::Text(schema.description.clone()),
        stamp,
    )?;
    write_lww_register(
        tx,
        &entry,
        "deleted",
        &FieldValue::Boolean(schema.deleted),
        stamp,
    )?;
    let fields = tx
        .put_object(&entry, "fields", ObjType::Map)
        .map_err(repo_change)?;
    for field in &schema.fields {
        write_field(tx, &fields, field, stamp)?;
    }
    tx.put_object(&entry, "computed_fields", ObjType::Map)
        .map_err(repo_change)?;
    tx.put_object(&entry, "queries", ObjType::Map)
        .map_err(repo_change)?;
    tx.put_object(&entry, "widgets", ObjType::Map)
        .map_err(repo_change)?;
    Ok(())
}

fn definition_entry(
    doc: &impl ReadDoc,
    collections: &ObjId,
    collection_id: CollectionSchemaId,
    map_name: &str,
    id: &str,
) -> Result<ObjId, DomainError> {
    let collection = object(doc, collections, &collection_id.to_string())?;
    let definitions = object(doc, &collection, map_name)?;
    object(doc, &definitions, id)
}

fn write_definition<T: Serialize>(
    tx: &mut AutomergeTransaction<'_>,
    collections: &ObjId,
    collection_id: CollectionSchemaId,
    map_name: &str,
    id: &str,
    definition: &T,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let collection = object(tx, collections, &collection_id.to_string()).map_err(repo_change)?;
    let definitions = object(tx, &collection, map_name).map_err(repo_change)?;
    let entry = match tx.get(&definitions, id).map_err(repo_change)? {
        Some((value, object)) if value.is_object() => object,
        Some(_) => return Err(repo_change("definition entry is not an object")),
        None => tx
            .put_object(&definitions, id, ObjType::Map)
            .map_err(repo_change)?,
    };
    tx.put(&entry, "id", id).map_err(repo_change)?;
    let encoded = serde_json::to_string(definition).map_err(repo_change)?;
    write_lww_register(tx, &entry, "definition", &FieldValue::Text(encoded), stamp)
}

fn decode_definition<T: for<'de> Deserialize<'de>>(
    doc: &impl ReadDoc,
    entry: &ObjId,
) -> Result<T, DomainError> {
    let mut max = None;
    decode_definition_tracking(doc, entry, &mut max)
}

fn decode_definition_tracking<T: for<'de> Deserialize<'de>>(
    doc: &impl ReadDoc,
    entry: &ObjId,
    max: &mut Option<HlcStamp>,
) -> Result<T, DomainError> {
    let encoded = expect_text(
        read_winner_tracking(doc, entry, "definition", max)?,
        "definition",
    )?;
    serde_json::from_str(&encoded).map_err(malformed)
}

/// Decodes one widget entry from its independent HLC registers. The widget type is preserved
/// verbatim so an identifier this build does not implement stays valid synchronized data.
fn decode_widget_tracking(
    doc: &impl ReadDoc,
    entry: &ObjId,
    max: &mut Option<HlcStamp>,
) -> Result<WidgetDefinition, DomainError> {
    let id = WidgetId::from_str(&string(doc, entry, "id")?)
        .map_err(|error| malformed(error.to_string()))?;
    let collection_id = CollectionSchemaId::from_str(&string(doc, entry, "collection_id")?)?;
    let widget_type = WidgetType::preserved(expect_text(
        read_winner_tracking(doc, entry, "widget_type", max)?,
        "widget_type",
    )?);
    let title = expect_text(read_winner_tracking(doc, entry, "title", max)?, "title")?;
    let query_id = QueryId::from_str(&expect_text(
        read_winner_tracking(doc, entry, "query_id", max)?,
        "query_id",
    )?)
    .map_err(|error| malformed(error.to_string()))?;
    let configuration: WidgetConfiguration = serde_json::from_str(&expect_text(
        read_winner_tracking(doc, entry, "configuration", max)?,
        "configuration",
    )?)
    .map_err(malformed)?;
    let layout: WidgetLayout = serde_json::from_str(&expect_text(
        read_winner_tracking(doc, entry, "layout", max)?,
        "layout",
    )?)
    .map_err(malformed)?;
    let order = expect_integer(read_winner_tracking(doc, entry, "order", max)?, "order")?;
    let deleted = expect_bool(read_winner_tracking(doc, entry, "deleted", max)?, "deleted")?;
    Ok(WidgetDefinition {
        id,
        collection_id,
        widget_type,
        query_id,
        title,
        configuration,
        layout,
        order,
        deleted,
    })
}
fn write_field(
    tx: &mut AutomergeTransaction<'_>,
    fields: &ObjId,
    field: &FieldDefinition,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let entry = tx
        .put_object(fields, field.id.to_string(), ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&entry, "id", field.id.to_string())
        .map_err(repo_change)?;
    write_field_definition(tx, &entry, field, stamp)
}
fn write_field_definition(
    tx: &mut AutomergeTransaction<'_>,
    entry: &ObjId,
    field: &FieldDefinition,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let json = serde_json::to_string(field).map_err(repo_change)?;
    write_lww_register(tx, entry, "definition", &FieldValue::Text(json), stamp)
}
fn write_record(
    tx: &mut AutomergeTransaction<'_>,
    records: &ObjId,
    record: &GenericRecord,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let entry = tx
        .put_object(records, record.id.to_string(), ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&entry, "id", record.id.to_string())
        .map_err(repo_change)?;
    tx.put(&entry, "collection_id", record.collection_id.to_string())
        .map_err(repo_change)?;
    write_lww_register(
        tx,
        &entry,
        "deleted",
        &FieldValue::Boolean(record.deleted),
        stamp,
    )?;
    let values = tx
        .put_object(&entry, "values", ObjType::Map)
        .map_err(repo_change)?;
    for (field, value) in &record.values {
        write_lww_register(tx, &values, &field.to_string(), value, stamp)?;
    }
    Ok(())
}
fn decode_field(doc: &impl ReadDoc, entry: &ObjId) -> Result<FieldDefinition, DomainError> {
    let mut max = None;
    decode_field_tracking(doc, entry, &mut max)
}
fn decode_field_tracking(
    doc: &impl ReadDoc,
    entry: &ObjId,
    max: &mut Option<HlcStamp>,
) -> Result<FieldDefinition, DomainError> {
    let encoded = expect_text(
        read_winner_tracking(doc, entry, "definition", max)?,
        "definition",
    )?;
    let field: FieldDefinition = serde_json::from_str(&encoded).map_err(malformed)?;
    let id = FieldId::from_str(&string(doc, entry, "id")?)?;
    if field.id != id {
        return Err(malformed("field repeated id mismatch"));
    }
    Ok(field)
}
fn read_winner_tracking(
    doc: &impl ReadDoc,
    parent: &ObjId,
    property: &str,
    max: &mut Option<HlcStamp>,
) -> Result<FieldValue, DomainError> {
    let winner = read_lww_winner(doc, parent, property)?
        .ok_or_else(|| malformed(format!("missing {property} register")))?;
    *max = Some(max.map_or(winner.stamp, |current| current.max(winner.stamp)));
    Ok(winner.value)
}
fn expect_text(value: FieldValue, field: &str) -> Result<String, DomainError> {
    if let FieldValue::Text(value) = value {
        Ok(value)
    } else {
        Err(malformed(format!("invalid {field} register type")))
    }
}
fn expect_bool(value: FieldValue, field: &str) -> Result<bool, DomainError> {
    if let FieldValue::Boolean(value) = value {
        Ok(value)
    } else {
        Err(malformed(format!("invalid {field} register type")))
    }
}
fn expect_integer(value: FieldValue, field: &str) -> Result<i64, DomainError> {
    if let FieldValue::Integer(value) = value {
        Ok(value)
    } else {
        Err(malformed(format!("invalid {field} register type")))
    }
}
fn object(doc: &impl ReadDoc, parent: &ObjId, key: &str) -> Result<ObjId, DomainError> {
    let (value, object) = doc
        .get(parent, key)
        .map_err(malformed)?
        .ok_or_else(|| malformed(format!("missing {key}")))?;
    if !value.is_object() {
        return Err(malformed(format!("{key} is not an object")));
    }
    Ok(object)
}
fn string(doc: &impl ReadDoc, object: &ObjId, key: &str) -> Result<String, DomainError> {
    doc.get(object, key)
        .map_err(malformed)?
        .and_then(|(value, _)| value.to_str().map(str::to_owned))
        .ok_or_else(|| malformed(format!("missing or invalid {key}")))
}
fn integer(doc: &impl ReadDoc, object: &ObjId, key: &str) -> Result<i64, DomainError> {
    doc.get(object, key)
        .map_err(malformed)?
        .and_then(|(value, _)| value.to_i64())
        .ok_or_else(|| malformed(format!("missing or invalid {key}")))
}
fn collection_fields(
    doc: &impl ReadDoc,
    collections: &ObjId,
    id: CollectionSchemaId,
) -> Result<ObjId, DomainError> {
    let entry = object(doc, collections, &id.to_string())?;
    object(doc, &entry, "fields")
}
fn collection(
    snapshot: &GenericSnapshot,
    id: CollectionSchemaId,
) -> Result<&CollectionSchema, DomainError> {
    snapshot
        .collections
        .iter()
        .find(|item| item.id == id)
        .ok_or_else(|| not_found("collection", id))
}
fn active_collection(
    snapshot: &GenericSnapshot,
    id: CollectionSchemaId,
) -> Result<&CollectionSchema, DomainError> {
    collection(snapshot, id).and_then(|item| {
        if item.deleted {
            Err(not_found("collection", id))
        } else {
            Ok(item)
        }
    })
}
fn active_field(
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
    field_id: FieldId,
) -> Result<&FieldDefinition, DomainError> {
    active_collection(snapshot, collection_id)?
        .fields
        .iter()
        .find(|field| field.id == field_id && !field.deleted)
        .ok_or_else(|| not_found("field", field_id))
}
fn active_computed(
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
    id: ComputedFieldId,
) -> Result<&ComputedFieldDefinition, DomainError> {
    snapshot
        .computed_fields
        .iter()
        .find(|item| item.id == id && item.collection_id == collection_id && !item.deleted)
        .ok_or_else(|| not_found("computed field", id))
}
fn active_query(
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
    id: QueryId,
) -> Result<&QueryDefinition, DomainError> {
    snapshot
        .query_definitions
        .iter()
        .find(|item| item.id == id && item.collection_id == collection_id && !item.deleted)
        .ok_or_else(|| not_found("query", id))
}
fn active_widget(
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
    id: WidgetId,
) -> Result<&WidgetDefinition, DomainError> {
    snapshot
        .widgets
        .iter()
        .find(|item| item.id == id && item.collection_id == collection_id && !item.deleted)
        .ok_or_else(|| not_found("widget", id))
}
fn validate_reorder<T: Copy + Eq + std::hash::Hash>(
    requested: &[T],
    active: impl IntoIterator<Item = T>,
    field: &'static str,
) -> Result<(), DomainError> {
    let active: HashSet<_> = active.into_iter().collect();
    let requested_set: HashSet<_> = requested.iter().copied().collect();
    if requested_set.len() != requested.len() || requested_set != active {
        Err(invalid(
            field,
            "must contain every active definition exactly once",
        ))
    } else {
        Ok(())
    }
}
fn record(snapshot: &GenericSnapshot, id: RecordId) -> Result<&GenericRecord, DomainError> {
    snapshot
        .records
        .iter()
        .find(|item| item.id == id)
        .ok_or_else(|| not_found("record", id))
}
fn active_record(snapshot: &GenericSnapshot, id: RecordId) -> Result<&GenericRecord, DomainError> {
    record(snapshot, id).and_then(|item| {
        if item.deleted {
            Err(not_found("record", id))
        } else {
            Ok(item)
        }
    })
}
fn validate_required_evolution(
    field: &FieldDefinition,
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
) -> Result<(), DomainError> {
    if field.required
        && field.default.is_none()
        && snapshot.records.iter().any(|record| {
            !record.deleted
                && record.collection_id == collection_id
                && !record.values.contains_key(&field.id)
        })
    {
        return Err(invalid(
            "required",
            "active records require an atomically applicable default",
        ));
    }
    Ok(())
}
fn validate_name(value: &str) -> Result<(), DomainError> {
    let len = value.trim().chars().count();
    if len == 0 || len > 120 {
        Err(invalid(
            "name",
            "must contain 1 to 120 non-padding characters",
        ))
    } else {
        Ok(())
    }
}
fn invalid(field: &'static str, message: impl Into<String>) -> DomainError {
    DomainError::Invalid {
        field,
        message: message.into(),
    }
}
fn not_found(kind: &'static str, id: impl ToString) -> DomainError {
    DomainError::NotFound {
        kind,
        id: id.to_string(),
    }
}
fn malformed(error: impl std::fmt::Display) -> DomainError {
    DomainError::Malformed(error.to_string())
}
fn repo_change(error: impl std::fmt::Display) -> automerge_repo::Error {
    automerge_repo::Error::Change(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        hlc::HlcNodeId,
        query::{
            Aggregation, CalendarPolicy, CollectionQuery, Expression, FieldReference, QueryShape,
            ValueType, VersionedCollectionQuery, VersionedExpression,
        },
        schema::{DisplayMetadata, FieldType, ValidationMetadata},
        widgets::StructuredValue,
    };

    fn stamp(time: i64) -> HlcStamp {
        HlcStamp {
            physical_time_ms: time,
            logical_counter: 0,
            node_id: HlcNodeId([1; 32]),
        }
    }
    fn schema() -> CollectionSchema {
        CollectionSchema {
            id: CollectionSchemaId::new(),
            name: "Headaches".into(),
            description: String::new(),
            fields: vec![FieldDefinition {
                id: FieldId::new(),
                name: "Intensity".into(),
                field_type: FieldType::Integer,
                required: true,
                default: None,
                validation: ValidationMetadata {
                    min_integer: Some(1),
                    max_integer: Some(10),
                    ..ValidationMetadata::default()
                },
                display: DisplayMetadata::default(),
                order: 0,
                deleted: false,
                enum_options: vec![],
            }],
            deleted: false,
        }
    }
    fn initialized() -> Automerge {
        let mut doc = Automerge::new();
        let mut tx = doc.transaction();
        initialize_generic(&mut tx).unwrap();
        tx.commit();
        doc
    }

    #[test]
    fn schema_record_rename_removal_and_tombstone_round_trip() {
        let mut doc = initialized();
        let schema = schema();
        let mut snapshot = decode_generic(&doc).unwrap();
        let mut create = GenericCommand::CreateCollection(schema.clone());
        create.validate_against(&snapshot).unwrap();
        {
            let mut tx = doc.transaction();
            apply_generic_command(&mut tx, &create, stamp(1)).unwrap();
            tx.commit();
        }
        snapshot = decode_generic(&doc).unwrap();
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id: schema.id,
            values: BTreeMap::from([(schema.fields[0].id, FieldValue::Integer(7))]),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        let mut create_record = GenericCommand::CreateRecord(record.clone());
        create_record.validate_against(&snapshot).unwrap();
        if let GenericCommand::CreateRecord(validated) = create_record {
            record = validated;
        }
        {
            let mut tx = doc.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::CreateRecord(record.clone()),
                stamp(2),
            )
            .unwrap();
            tx.commit();
        }
        let mut rename = GenericCommand::RenameCollection {
            id: schema.id,
            name: "Pain diary".into(),
        };
        rename
            .validate_against(&decode_generic(&doc).unwrap())
            .unwrap();
        {
            let mut tx = doc.transaction();
            apply_generic_command(&mut tx, &rename, stamp(3)).unwrap();
            apply_generic_command(
                &mut tx,
                &GenericCommand::RemoveField {
                    collection_id: schema.id,
                    field_id: schema.fields[0].id,
                },
                stamp(4),
            )
            .unwrap();
            apply_generic_command(&mut tx, &GenericCommand::DeleteRecord(record.id), stamp(5))
                .unwrap();
            tx.commit();
        }
        let decoded = decode_generic(&doc).unwrap();
        assert_eq!(decoded.collections[0].name, "Pain diary");
        assert!(decoded.collections[0].fields[0].deleted);
        assert_eq!(
            decoded.records[0].values[&schema.fields[0].id],
            FieldValue::Integer(7)
        );
        assert!(decoded.records[0].deleted);
    }

    #[test]
    fn invalid_record_is_rejected_without_a_write() {
        let mut doc = initialized();
        let schema = schema();
        {
            let mut tx = doc.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::CreateCollection(schema.clone()),
                stamp(1),
            )
            .unwrap();
            tx.commit();
        }
        let before = doc.get_heads();
        let mut command = GenericCommand::CreateRecord(GenericRecord {
            id: RecordId::new(),
            collection_id: schema.id,
            values: BTreeMap::from([(schema.fields[0].id, FieldValue::Integer(99))]),
            stamps: BTreeMap::new(),
            deleted: false,
        });
        assert!(
            command
                .validate_against(&decode_generic(&doc).unwrap())
                .is_err()
        );
        assert_eq!(doc.get_heads(), before);
    }

    #[test]
    fn computed_and_query_definitions_round_trip_and_invalid_merge_is_isolated() {
        let mut doc = initialized();
        let schema = schema();
        {
            let mut tx = doc.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::CreateCollection(schema.clone()),
                stamp(1),
            )
            .unwrap();
            tx.commit();
        }
        let computed = ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id: schema.id,
            name: "Absolute intensity".into(),
            declared_type: ValueType::Integer,
            nullable: false,
            expression: VersionedExpression::new(Expression::Abs {
                expression: Box::new(Expression::Field {
                    field: FieldReference::Source(schema.fields[0].id),
                }),
            }),
            order: 0,
            deleted: false,
        };
        let query = QueryDefinition {
            id: QueryId::new(),
            collection_id: schema.id,
            name: "Count".into(),
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id: schema.id,
                filter: None,
                grouping: None,
                shape: QueryShape::Scalar {
                    aggregation: Aggregation::Count,
                },
                sorting: vec![],
                limit: None,
                calendar: CalendarPolicy::default(),
            }),
            order: 0,
            deleted: false,
        };
        let mut create_computed = GenericCommand::CreateComputedField(computed.clone());
        create_computed
            .validate_against(&decode_generic(&doc).unwrap())
            .unwrap();
        let mut create_query = GenericCommand::CreateQuery(query.clone());
        create_query
            .validate_against(&decode_generic(&doc).unwrap())
            .unwrap();
        {
            let mut tx = doc.transaction();
            apply_generic_command(&mut tx, &create_computed, stamp(2)).unwrap();
            apply_generic_command(&mut tx, &create_query, stamp(3)).unwrap();
            tx.commit();
        }
        let snapshot = decode_generic(&doc).unwrap();
        assert_eq!(snapshot.computed_fields, vec![computed]);
        assert_eq!(snapshot.query_definitions, vec![query]);
        {
            let mut tx = doc.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::RemoveField {
                    collection_id: schema.id,
                    field_id: schema.fields[0].id,
                },
                stamp(4),
            )
            .unwrap();
            tx.commit();
        }
        let merged = decode_generic(&doc).unwrap();
        assert_eq!(merged.computed_fields.len(), 1);
        assert!(merged.diagnostics.iter().any(|item| {
            item.kind == "computed_field_validation"
                && item.entity_id == merged.computed_fields[0].id.to_string()
        }));
    }

    #[test]
    fn two_device_definition_changes_converge_and_invalid_dependency_is_preserved() {
        let mut base = initialized();
        let schema = schema();
        {
            let mut tx = base.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::CreateCollection(schema.clone()),
                stamp(1),
            )
            .unwrap();
            tx.commit();
        }
        let computed = ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id: schema.id,
            name: "Absolute".into(),
            declared_type: ValueType::Integer,
            nullable: false,
            expression: VersionedExpression::new(Expression::Abs {
                expression: Box::new(Expression::Field {
                    field: FieldReference::Source(schema.fields[0].id),
                }),
            }),
            order: 0,
            deleted: false,
        };
        let query = QueryDefinition {
            id: QueryId::new(),
            collection_id: schema.id,
            name: "Count".into(),
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id: schema.id,
                filter: None,
                grouping: None,
                shape: QueryShape::Scalar {
                    aggregation: Aggregation::Count,
                },
                sorting: vec![],
                limit: None,
                calendar: CalendarPolicy::default(),
            }),
            order: 0,
            deleted: false,
        };
        let mut left = base.fork();
        let mut right = base.fork();
        {
            let mut tx = left.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::CreateComputedField(computed.clone()),
                stamp(2),
            )
            .unwrap();
            tx.commit();
        }
        {
            let mut tx = right.transaction();
            apply_generic_command(
                &mut tx,
                &GenericCommand::CreateQuery(query.clone()),
                stamp(2),
            )
            .unwrap();
            apply_generic_command(
                &mut tx,
                &GenericCommand::RemoveField {
                    collection_id: schema.id,
                    field_id: schema.fields[0].id,
                },
                stamp(3),
            )
            .unwrap();
            tx.commit();
        }
        left.merge(&mut right).unwrap();
        right.merge(&mut left).unwrap();
        let left_snapshot = decode_generic(&left).unwrap();
        let right_snapshot = decode_generic(&right).unwrap();
        assert_eq!(left_snapshot.computed_fields, vec![computed]);
        assert_eq!(left_snapshot.query_definitions, vec![query]);
        assert_eq!(left_snapshot, right_snapshot);
        assert!(
            left_snapshot
                .diagnostics
                .iter()
                .any(|item| item.kind == "computed_field_validation")
        );
    }

    #[test]
    fn finance_v1_root_requires_an_explicit_development_reset() {
        let mut doc = Automerge::new();
        {
            let mut tx = doc.transaction();
            let finance = tx.put_object(ROOT, "finance", ObjType::Map).unwrap();
            tx.put(&finance, "schema_version", 1).unwrap();
            tx.commit();
        }
        assert_eq!(decode_generic(&doc), Err(DomainError::UnsupportedSchema(1)));
    }

    fn scalar_query(collection_id: CollectionSchemaId, id: QueryId) -> QueryDefinition {
        QueryDefinition {
            id,
            collection_id,
            name: "Count".into(),
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id,
                filter: None,
                grouping: None,
                shape: QueryShape::Scalar {
                    aggregation: Aggregation::Count,
                },
                sorting: vec![],
                limit: None,
                calendar: CalendarPolicy::default(),
            }),
            order: 0,
            deleted: false,
        }
    }

    fn series_query(collection_id: CollectionSchemaId, id: QueryId) -> QueryDefinition {
        let constant = Expression::Constant {
            value: crate::query::TypedValue::Integer(0),
        };
        QueryDefinition {
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id,
                filter: None,
                grouping: None,
                shape: QueryShape::Series {
                    x: constant.clone(),
                    y: constant,
                },
                sorting: vec![],
                limit: None,
                calendar: CalendarPolicy::default(),
            }),
            ..scalar_query(collection_id, id)
        }
    }

    fn widget(
        collection_id: CollectionSchemaId,
        query_id: QueryId,
        widget_type: &str,
        order: i64,
    ) -> WidgetDefinition {
        WidgetDefinition {
            id: WidgetId::new(),
            collection_id,
            widget_type: WidgetType::new(widget_type).unwrap(),
            query_id,
            title: "Balance".into(),
            configuration: WidgetConfiguration::empty(),
            layout: WidgetLayout::default(),
            order,
            deleted: false,
        }
    }

    /// Applies a command after validating it, exactly as the application owner does.
    fn commit(doc: &mut Automerge, command: &mut GenericCommand, time: i64) {
        command
            .validate_against(&decode_generic(doc).unwrap())
            .unwrap();
        let mut tx = doc.transaction();
        apply_generic_command(&mut tx, command, stamp(time)).unwrap();
        tx.commit();
    }

    fn with_collection_and_query() -> (Automerge, CollectionSchemaId, QueryId) {
        let mut doc = initialized();
        let collection = schema();
        commit(
            &mut doc,
            &mut GenericCommand::CreateCollection(collection.clone()),
            1,
        );
        let query_id = QueryId::new();
        commit(
            &mut doc,
            &mut GenericCommand::CreateQuery(scalar_query(collection.id, query_id)),
            2,
        );
        (doc, collection.id, query_id)
    }

    fn widget_entry_of(doc: &Automerge, collection_id: CollectionSchemaId, id: WidgetId) -> ObjId {
        let app = object(doc, &ROOT, "application").unwrap();
        let collections = object(doc, &app, "collections").unwrap();
        widget_entry(doc, &collections, collection_id, &id.to_string()).unwrap()
    }

    #[test]
    fn widget_lifecycle_validates_targets_and_orders_deterministically() {
        let (mut doc, collection_id, query_id) = with_collection_and_query();
        let first = widget(collection_id, query_id, "core.aggregate-number", 0);
        let second = widget(collection_id, query_id, "core.aggregate-number", 0);
        commit(
            &mut doc,
            &mut GenericCommand::CreateWidget(first.clone()),
            3,
        );
        commit(
            &mut doc,
            &mut GenericCommand::CreateWidget(second.clone()),
            4,
        );

        // Equal order values fall back to the stable ID so every device agrees.
        let decoded = decode_generic(&doc).unwrap();
        let mut expected = vec![first.clone(), second.clone()];
        expected.sort_by_key(|item| item.id);
        assert_eq!(decoded.widgets, expected);

        // A duplicate ID is rejected before anything is written.
        let heads = doc.get_heads();
        let mut duplicate = GenericCommand::CreateWidget(first.clone());
        assert!(
            duplicate
                .validate_against(&decode_generic(&doc).unwrap())
                .is_err()
        );
        assert_eq!(doc.get_heads(), heads);

        commit(
            &mut doc,
            &mut GenericCommand::ReorderWidgets {
                collection_id,
                ids: vec![second.id, first.id],
            },
            5,
        );
        let reordered = decode_generic(&doc).unwrap();
        assert_eq!(
            reordered
                .widgets
                .iter()
                .map(|item| item.id)
                .collect::<Vec<_>>(),
            vec![second.id, first.id]
        );
        assert_eq!(reordered.widgets[0].order, 0);
        assert_eq!(reordered.widgets[1].order, 1);

        // Reordering must name every active widget exactly once.
        assert!(
            GenericCommand::ReorderWidgets {
                collection_id,
                ids: vec![first.id],
            }
            .validate_against(&reordered)
            .is_err()
        );

        commit(
            &mut doc,
            &mut GenericCommand::RemoveWidget {
                collection_id,
                id: first.id,
            },
            6,
        );
        let removed = decode_generic(&doc).unwrap();
        assert_eq!(removed.widgets.len(), 2);
        assert!(
            removed
                .widgets
                .iter()
                .find(|item| item.id == first.id)
                .unwrap()
                .deleted
        );
        // A tombstoned widget is no longer an active command target.
        assert!(
            GenericCommand::RemoveWidget {
                collection_id,
                id: first.id
            }
            .validate_against(&removed)
            .is_err()
        );
        assert!(
            GenericCommand::UpdateWidget(WidgetUpdate {
                id: first.id,
                collection_id,
                title: Some("Resurrected".into()),
                ..WidgetUpdate::default()
            })
            .validate_against(&removed)
            .is_err()
        );
    }

    #[test]
    fn widget_commands_reject_incompatible_and_missing_queries() {
        let (mut doc, collection_id, query_id) = with_collection_and_query();
        let mut mismatched = widget(collection_id, query_id, "core.aggregate-number", 0);
        let series_id = QueryId::new();
        commit(
            &mut doc,
            &mut GenericCommand::CreateQuery(series_query(collection_id, series_id)),
            3,
        );
        mismatched.query_id = series_id;
        let heads = doc.get_heads();
        let mut command = GenericCommand::CreateWidget(mismatched.clone());
        let error = command
            .validate_against(&decode_generic(&doc).unwrap())
            .unwrap_err();
        assert!(
            matches!(&error, DomainError::Invalid { field, message }
                if *field == "query_id" && message.contains("core.aggregate-number")),
            "unexpected error: {error}"
        );
        // A line chart accepts the same ordered Series query.
        let mut line = widget(collection_id, series_id, "core.line-chart", 0);
        line.query_id = series_id;
        commit(&mut doc, &mut GenericCommand::CreateWidget(line), 4);

        let mut dangling = widget(collection_id, QueryId::new(), "core.bar-chart", 1);
        dangling.query_id = QueryId::new();
        assert!(
            GenericCommand::CreateWidget(dangling)
                .validate_against(&decode_generic(&doc).unwrap())
                .is_err()
        );
        // Nothing was committed by the rejected commands.
        assert_ne!(doc.get_heads(), heads);

        // Removing the referenced query leaves the widget preserved with a diagnostic instead of
        // deleting it, because merged remote data must stay inspectable.
        commit(
            &mut doc,
            &mut GenericCommand::RemoveQuery {
                collection_id,
                id: series_id,
            },
            5,
        );
        let decoded = decode_generic(&doc).unwrap();
        assert_eq!(decoded.widgets.len(), 1);
        assert!(decoded.diagnostics.iter().any(|item| {
            item.kind == "widget_validation" && item.entity_id == decoded.widgets[0].id.to_string()
        }));
        assert!(decoded.widgets[0].validate_standalone().is_ok());
        // A broken reference never removes or rewrites the widget; it stays inspectable.
        assert!(!decoded.widgets[0].deleted);
    }

    #[test]
    fn renaming_an_unknown_widget_never_rewrites_its_opaque_registers() {
        let (mut doc, collection_id, query_id) = with_collection_and_query();
        let opaque = StructuredValue::Map(BTreeMap::from([
            ("heatmap".into(), StructuredValue::Boolean(true)),
            (
                "palette".into(),
                StructuredValue::List(vec![
                    StructuredValue::Text("#00ff00".into()),
                    StructuredValue::Integer(-2350),
                    StructuredValue::Null,
                ]),
            ),
        ]));
        let unknown = WidgetDefinition {
            widget_type: WidgetType::new("com.example.calendar-heatmap").unwrap(),
            title: "Future heatmap".into(),
            configuration: WidgetConfiguration {
                version: 9,
                body: opaque.clone(),
            },
            ..widget(collection_id, query_id, "core.aggregate-number", 0)
        };
        commit(
            &mut doc,
            &mut GenericCommand::CreateWidget(unknown.clone()),
            3,
        );
        let entry = widget_entry_of(&doc, collection_id, unknown.id);
        assert_eq!(
            read_lww_candidates(&doc, &entry, "configuration")
                .unwrap()
                .len(),
            1
        );

        commit(
            &mut doc,
            &mut GenericCommand::UpdateWidget(WidgetUpdate {
                id: unknown.id,
                collection_id,
                title: Some("Renamed heatmap".into()),
                ..WidgetUpdate::default()
            }),
            4,
        );
        let decoded = decode_generic(&doc).unwrap();
        let renamed = decoded.widgets.iter().find(|w| w.id == unknown.id).unwrap();
        assert_eq!(renamed.title, "Renamed heatmap");
        // Type, query, version, and every unknown key survive an unrelated metadata edit.
        assert_eq!(renamed.widget_type, unknown.widget_type);
        assert_eq!(renamed.query_id, unknown.query_id);
        assert_eq!(renamed.configuration.version, 9);
        assert_eq!(renamed.configuration.body, opaque);
        // The configuration register was not written again, so a concurrent remote configuration
        // edit composes with the local rename instead of being clobbered by it.
        let entry = widget_entry_of(&doc, collection_id, unknown.id);
        assert_eq!(
            read_lww_candidates(&doc, &entry, "configuration")
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn independent_widget_metadata_edits_compose_across_devices() {
        let (base, collection_id, query_id) = with_collection_and_query();
        let unknown = WidgetDefinition {
            widget_type: WidgetType::new("com.example.future-widget").unwrap(),
            configuration: WidgetConfiguration {
                version: 4,
                body: StructuredValue::Map(BTreeMap::from([(
                    "opaque".into(),
                    StructuredValue::Integer(7),
                )])),
            },
            ..widget(collection_id, query_id, "core.aggregate-number", 0)
        };
        let mut base = base;
        commit(
            &mut base,
            &mut GenericCommand::CreateWidget(unknown.clone()),
            3,
        );
        let mut left = base.fork();
        let mut right = base.fork();
        commit(
            &mut left,
            &mut GenericCommand::UpdateWidget(WidgetUpdate {
                id: unknown.id,
                collection_id,
                title: Some("Left title".into()),
                ..WidgetUpdate::default()
            }),
            10,
        );
        commit(
            &mut right,
            &mut GenericCommand::UpdateWidget(WidgetUpdate {
                id: unknown.id,
                collection_id,
                order: Some(5),
                ..WidgetUpdate::default()
            }),
            11,
        );
        left.merge(&mut right).unwrap();
        right.merge(&mut left).unwrap();
        for doc in [&left, &right] {
            let merged = decode_generic(doc).unwrap();
            let widget = merged.widgets.iter().find(|w| w.id == unknown.id).unwrap();
            assert_eq!(widget.title, "Left title");
            assert_eq!(widget.order, 5);
            assert_eq!(widget.widget_type, unknown.widget_type);
            assert_eq!(widget.configuration, unknown.configuration);
        }
        assert_eq!(
            decode_generic(&left).unwrap(),
            decode_generic(&right).unwrap()
        );
    }

    #[test]
    fn widget_tombstone_wins_over_a_concurrent_update_and_reorder_converges() {
        let (mut base, collection_id, query_id) = with_collection_and_query();
        let first = widget(collection_id, query_id, "core.aggregate-number", 0);
        let second = widget(collection_id, query_id, "core.aggregate-number", 1);
        commit(
            &mut base,
            &mut GenericCommand::CreateWidget(first.clone()),
            3,
        );
        commit(
            &mut base,
            &mut GenericCommand::CreateWidget(second.clone()),
            4,
        );
        let mut left = base.fork();
        let mut right = base.fork();
        commit(
            &mut left,
            &mut GenericCommand::RemoveWidget {
                collection_id,
                id: first.id,
            },
            10,
        );
        commit(
            &mut right,
            &mut GenericCommand::UpdateWidget(WidgetUpdate {
                id: first.id,
                collection_id,
                title: Some("Concurrent rename".into()),
                ..WidgetUpdate::default()
            }),
            9,
        );
        left.merge(&mut right).unwrap();
        right.merge(&mut left).unwrap();
        for doc in [&left, &right] {
            let merged = decode_generic(doc).unwrap();
            let widget = merged.widgets.iter().find(|w| w.id == first.id).unwrap();
            // The ordinary update composes but cannot resurrect the tombstone.
            assert!(widget.deleted);
            assert_eq!(widget.title, "Concurrent rename");
        }

        // Concurrent reorders that produce equal order values still converge on one order.
        let mut left = base.fork();
        let mut right = base.fork();
        commit(
            &mut left,
            &mut GenericCommand::ReorderWidgets {
                collection_id,
                ids: vec![second.id, first.id],
            },
            20,
        );
        commit(
            &mut right,
            &mut GenericCommand::ReorderWidgets {
                collection_id,
                ids: vec![first.id, second.id],
            },
            20,
        );
        left.merge(&mut right).unwrap();
        right.merge(&mut left).unwrap();
        let left_order = decode_generic(&left)
            .unwrap()
            .widgets
            .iter()
            .map(|item| item.id)
            .collect::<Vec<_>>();
        assert_eq!(
            left_order,
            decode_generic(&right)
                .unwrap()
                .widgets
                .iter()
                .map(|item| item.id)
                .collect::<Vec<_>>()
        );
        assert_eq!(left_order.len(), 2);
    }

    #[test]
    fn unknown_widget_types_synchronize_intact_between_devices() {
        // Device B already shares the root, then receives a widget type it cannot render.
        let (mut device_a, collection_id, query_id) = with_collection_and_query();
        let mut device_b = device_a.fork();
        let preserved = WidgetDefinition {
            widget_type: WidgetType::preserved("com.example.future-widget".into()),
            configuration: WidgetConfiguration {
                version: 12,
                body: StructuredValue::Map(BTreeMap::from([(
                    "renderer".into(),
                    StructuredValue::Map(BTreeMap::from([(
                        "shader".into(),
                        StructuredValue::Text("heat".into()),
                    )])),
                )])),
            },
            ..widget(collection_id, query_id, "core.aggregate-number", 0)
        };
        commit(
            &mut device_a,
            &mut GenericCommand::CreateWidget(preserved.clone()),
            3,
        );
        // Device B has no renderer for this type; the definition is still valid preserved data.
        assert!(!crate::widget_registry::is_supported(
            preserved.widget_type.as_str()
        ));
        device_b.merge(&mut device_a).unwrap();
        let projected = decode_generic(&device_b).unwrap();
        assert_eq!(projected.widgets, vec![preserved]);
        assert!(
            !projected
                .diagnostics
                .iter()
                .any(|item| item.kind == "widget_validation"),
            "an unimplemented widget type is not an error: {:?}",
            projected.diagnostics
        );
    }
}
