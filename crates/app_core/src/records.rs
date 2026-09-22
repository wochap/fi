use std::{
    collections::{BTreeMap, HashSet},
    fmt,
    str::FromStr,
};

use automerge::{
    ObjId, ObjType, ReadDoc,
    transaction::{Transactable, Transaction as AutomergeTransaction},
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    error::DomainError,
    hlc::{HlcNodeId, HlcStamp},
    schema::{CollectionSchema, CollectionSchemaId, FieldId},
    values::FieldValue,
};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct RecordId(Uuid);

impl RecordId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::now_v7())
    }
    #[must_use]
    pub const fn as_uuid(self) -> Uuid {
        self.0
    }
}
impl Default for RecordId {
    fn default() -> Self {
        Self::new()
    }
}
impl fmt::Display for RecordId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}
impl FromStr for RecordId {
    type Err = RecordValidationError;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let uuid = Uuid::parse_str(value).map_err(|_| RecordValidationError::InvalidId)?;
        if uuid.get_version_num() != 7 || uuid.hyphenated().to_string() != value {
            return Err(RecordValidationError::InvalidId);
        }
        Ok(Self(uuid))
    }
}
impl<'de> Deserialize<'de> for RecordId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        String::deserialize(deserializer)?
            .parse()
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct GenericRecord {
    pub id: RecordId,
    pub collection_id: CollectionSchemaId,
    pub values: BTreeMap<FieldId, FieldValue>,
    #[serde(default)]
    pub stamps: BTreeMap<FieldId, HlcStamp>,
    pub deleted: bool,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum RecordValidationError {
    #[error("record id must be a canonical UUIDv7")]
    InvalidId,
    #[error("record belongs to a different collection")]
    WrongCollection,
    #[error("field {0} was not found or is removed")]
    FieldUnavailable(FieldId),
    #[error("required field {0} is missing")]
    MissingRequired(FieldId),
    #[error("field {field}: {message}")]
    InvalidValue { field: FieldId, message: String },
}

pub fn validate_record(
    record: &mut GenericRecord,
    schema: &CollectionSchema,
    apply_defaults: bool,
) -> Result<(), RecordValidationError> {
    if record.collection_id != schema.id {
        return Err(RecordValidationError::WrongCollection);
    }
    let active: HashSet<_> = schema
        .fields
        .iter()
        .filter(|field| !field.deleted)
        .map(|field| field.id)
        .collect();
    if let Some(id) = record.values.keys().find(|id| !active.contains(id)) {
        return Err(RecordValidationError::FieldUnavailable(*id));
    }
    for field in schema.fields.iter().filter(|field| !field.deleted) {
        if !record.values.contains_key(&field.id)
            && apply_defaults
            && let Some(default) = &field.default
        {
            record.values.insert(field.id, default.clone());
        }
        match record.values.get(&field.id) {
            // A default satisfies requiredness even on the projection path, where defaults are not
            // inserted: the field reads as its default everywhere, so the record is not missing it.
            None if field.required && field.default.is_none() => {
                return Err(RecordValidationError::MissingRequired(field.id));
            }
            Some(value) => field.validate_value(value, false).map_err(|error| {
                RecordValidationError::InvalidValue {
                    field: field.id,
                    message: error.to_string(),
                }
            })?,
            None => {}
        }
    }
    Ok(())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LwwValue {
    pub value: FieldValue,
    pub stamp: HlcStamp,
}

pub fn write_lww_register(
    tx: &mut AutomergeTransaction<'_>,
    parent: &ObjId,
    property: &str,
    value: &FieldValue,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let register = tx
        .put_object(parent, property, ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&register, "kind", value_kind(value))
        .map_err(repo_change)?;
    match value {
        FieldValue::Null => {}
        FieldValue::Text(value) => tx
            .put(&register, "text", value.as_str())
            .map_err(repo_change)?,
        FieldValue::Integer(value)
        | FieldValue::FixedDecimal(value)
        | FieldValue::Date(value)
        | FieldValue::DateTime(value)
        | FieldValue::Duration(value) => {
            tx.put(&register, "integer", *value).map_err(repo_change)?
        }
        FieldValue::Boolean(value) => tx.put(&register, "boolean", *value).map_err(repo_change)?,
        FieldValue::Enum(value) => tx
            .put(&register, "enum_id", value.to_string())
            .map_err(repo_change)?,
    }
    tx.put(&register, "physical_time_ms", stamp.physical_time_ms)
        .map_err(repo_change)?;
    tx.put(
        &register,
        "logical_counter",
        i64::from(stamp.logical_counter),
    )
    .map_err(repo_change)?;
    tx.put(&register, "node_id", stamp.node_id.to_string())
        .map_err(repo_change)?;
    Ok(())
}

pub fn read_lww_candidates(
    doc: &impl ReadDoc,
    parent: &ObjId,
    property: &str,
) -> Result<Vec<LwwValue>, DomainError> {
    let candidates = doc.get_all(parent, property).map_err(malformed)?;
    let mut decoded = Vec::with_capacity(candidates.len());
    for (value, object) in candidates {
        if !matches!(value, automerge::Value::Object(ObjType::Map)) {
            return Err(malformed(format!("register {property} is not a map")));
        }
        let kind = string(doc, &object, "kind")?;
        let value = match kind.as_str() {
            "null" => FieldValue::Null,
            "text" => FieldValue::Text(string(doc, &object, "text")?),
            "integer" => FieldValue::Integer(integer(doc, &object, "integer")?),
            "fixed_decimal" => FieldValue::FixedDecimal(integer(doc, &object, "integer")?),
            "boolean" => FieldValue::Boolean(boolean(doc, &object, "boolean")?),
            "date" => FieldValue::Date(integer(doc, &object, "integer")?),
            "date_time" => FieldValue::DateTime(integer(doc, &object, "integer")?),
            "duration" => FieldValue::Duration(integer(doc, &object, "integer")?),
            "enum" => FieldValue::Enum(string(doc, &object, "enum_id")?.parse()?),
            _ => return Err(malformed(format!("unsupported register kind {kind}"))),
        };
        let logical_counter = u32::try_from(integer(doc, &object, "logical_counter")?)
            .map_err(|_| malformed("invalid logical counter"))?;
        let node = string(doc, &object, "node_id")?;
        if node.len() != 64 || node.bytes().any(|byte| byte.is_ascii_uppercase()) {
            return Err(malformed("invalid HLC node id"));
        }
        let node = hex::decode(node).map_err(|_| malformed("invalid HLC node id"))?;
        let node_id = HlcNodeId(
            node.try_into()
                .map_err(|_| malformed("invalid HLC node id"))?,
        );
        decoded.push(LwwValue {
            value,
            stamp: HlcStamp {
                physical_time_ms: integer(doc, &object, "physical_time_ms")?,
                logical_counter,
                node_id,
            },
        });
    }
    Ok(decoded)
}

pub fn read_lww_winner(
    doc: &impl ReadDoc,
    parent: &ObjId,
    property: &str,
) -> Result<Option<LwwValue>, DomainError> {
    Ok(read_lww_candidates(doc, parent, property)?
        .into_iter()
        .max_by_key(|candidate| candidate.stamp))
}

fn value_kind(value: &FieldValue) -> &'static str {
    match value {
        FieldValue::Null => "null",
        FieldValue::Text(_) => "text",
        FieldValue::Integer(_) => "integer",
        FieldValue::FixedDecimal(_) => "fixed_decimal",
        FieldValue::Boolean(_) => "boolean",
        FieldValue::Date(_) => "date",
        FieldValue::DateTime(_) => "date_time",
        FieldValue::Duration(_) => "duration",
        FieldValue::Enum(_) => "enum",
    }
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
fn boolean(doc: &impl ReadDoc, object: &ObjId, key: &str) -> Result<bool, DomainError> {
    doc.get(object, key)
        .map_err(malformed)?
        .and_then(|(value, _)| value.to_bool())
        .ok_or_else(|| malformed(format!("missing or invalid {key}")))
}
fn malformed(error: impl fmt::Display) -> DomainError {
    DomainError::Malformed(error.to_string())
}
fn repo_change(error: impl fmt::Display) -> automerge_repo::Error {
    automerge_repo::Error::Change(error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{DisplayMetadata, FieldDefinition, FieldType, ValidationMetadata};

    #[test]
    fn ids_are_canonical_and_records_apply_defaults_atomically() {
        let collection_id = CollectionSchemaId::new();
        let field_id = FieldId::new();
        let schema = CollectionSchema {
            id: collection_id,
            name: "Headaches".into(),
            description: String::new(),
            deleted: false,
            fields: vec![FieldDefinition {
                id: field_id,
                name: "Intensity".into(),
                field_type: FieldType::Integer,
                required: true,
                default: Some(FieldValue::Integer(1)),
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
        };
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id,
            values: BTreeMap::new(),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        validate_record(&mut record, &schema, true).unwrap();
        assert_eq!(record.values.get(&field_id), Some(&FieldValue::Integer(1)));
        assert_eq!(
            record.id.to_string().parse::<RecordId>().unwrap(),
            record.id
        );
    }

    #[test]
    fn explicit_null_is_distinct_from_absence_and_rejected_for_required_fields() {
        let collection_id = CollectionSchemaId::new();
        let field_id = FieldId::new();
        let schema = CollectionSchema {
            id: collection_id,
            name: "Things".into(),
            description: String::new(),
            deleted: false,
            fields: vec![FieldDefinition {
                id: field_id,
                name: "When".into(),
                field_type: FieldType::DateTime,
                required: true,
                default: None,
                validation: ValidationMetadata::default(),
                display: DisplayMetadata::default(),
                order: 0,
                deleted: false,
                enum_options: vec![],
            }],
        };
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id,
            values: BTreeMap::from([(field_id, FieldValue::Null)]),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        assert!(validate_record(&mut record, &schema, false).is_err());
        record.values.clear();
        assert_eq!(
            validate_record(&mut record, &schema, false),
            Err(RecordValidationError::MissingRequired(field_id))
        );
    }

    #[test]
    fn automerge_registers_resolve_same_field_by_hlc_and_compose_different_fields() {
        use automerge::{Automerge, ROOT, transaction::Transactable};
        let mut base = Automerge::new();
        let fields = {
            let mut tx = base.transaction();
            let fields = tx.put_object(ROOT, "fields", ObjType::Map).unwrap();
            tx.commit();
            fields
        };
        let mut left = base.fork();
        let mut right = base.fork();
        {
            let mut tx = left.transaction();
            write_lww_register(
                &mut tx,
                &fields,
                "same",
                &FieldValue::Integer(1),
                HlcStamp {
                    physical_time_ms: 10,
                    logical_counter: 0,
                    node_id: HlcNodeId([1; 32]),
                },
            )
            .unwrap();
            write_lww_register(
                &mut tx,
                &fields,
                "left",
                &FieldValue::Text("a".into()),
                HlcStamp {
                    physical_time_ms: 10,
                    logical_counter: 1,
                    node_id: HlcNodeId([1; 32]),
                },
            )
            .unwrap();
            tx.commit();
        }
        {
            let mut tx = right.transaction();
            write_lww_register(
                &mut tx,
                &fields,
                "same",
                &FieldValue::Integer(2),
                HlcStamp {
                    physical_time_ms: 11,
                    logical_counter: 0,
                    node_id: HlcNodeId([2; 32]),
                },
            )
            .unwrap();
            write_lww_register(
                &mut tx,
                &fields,
                "right",
                &FieldValue::Boolean(true),
                HlcStamp {
                    physical_time_ms: 11,
                    logical_counter: 1,
                    node_id: HlcNodeId([2; 32]),
                },
            )
            .unwrap();
            tx.commit();
        }
        left.merge(&mut right).unwrap();
        assert_eq!(
            read_lww_candidates(&left, &fields, "same").unwrap().len(),
            2
        );
        assert_eq!(
            read_lww_winner(&left, &fields, "same")
                .unwrap()
                .unwrap()
                .value,
            FieldValue::Integer(2)
        );
        assert!(read_lww_winner(&left, &fields, "left").unwrap().is_some());
        assert!(read_lww_winner(&left, &fields, "right").unwrap().is_some());
    }
}
