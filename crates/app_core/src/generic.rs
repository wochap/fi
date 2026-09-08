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
    records::{
        GenericRecord, RecordId, read_lww_candidates, read_lww_winner, validate_record,
        write_lww_register,
    },
    schema::{
        CollectionSchema, CollectionSchemaId, EnumOption, EnumOptionId, FieldDefinition, FieldId,
    },
    values::FieldValue,
};

pub const APP_SCHEMA_VERSION: i64 = 2;

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
        }
        Ok(())
    }
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
    }
    Ok(())
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
        collections.push(CollectionSchema {
            id,
            name,
            description,
            fields,
            deleted,
        });
    }
    collections.sort_by_key(|schema| schema.id);
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
    Ok(GenericSnapshot {
        schema_version,
        collections,
        records,
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
    Ok(())
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
        schema::{DisplayMetadata, FieldType, ValidationMetadata},
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
}
