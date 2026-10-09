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
    error::{DomainError, IssueCode, ValidationIssue, summarize_issues},
    hlc::{HlcNodeId, HlcStamp},
    schema::{CollectionSchema, CollectionSchemaId, EnumOptionId, FieldId},
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
    /// Every field problem found, in schema order. Never empty.
    #[error("{}", summarize_issues(&.0.iter().map(RecordFieldIssue::issue).collect::<Vec<_>>()))]
    Fields(Vec<RecordFieldIssue>),
}

/// One field-level record problem with an id-free message.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordFieldIssue {
    pub field: FieldId,
    pub code: IssueCode,
    pub message: String,
}

impl RecordFieldIssue {
    fn new(field: FieldId, issue: ValidationIssue) -> Self {
        Self {
            field,
            code: issue.code,
            message: issue.message,
        }
    }

    #[must_use]
    pub fn issue(&self) -> ValidationIssue {
        ValidationIssue {
            fields: vec![self.field.to_string()],
            code: self.code,
            message: self.message.clone(),
        }
    }
}

impl RecordValidationError {
    /// Validation issues with field context, for the bridge.
    #[must_use]
    pub fn issues(&self) -> Vec<ValidationIssue> {
        match self {
            Self::Fields(issues) => issues.iter().map(RecordFieldIssue::issue).collect(),
            other => vec![ValidationIssue::new(IssueCode::Invalid, other.to_string())],
        }
    }
}

impl From<RecordValidationError> for DomainError {
    fn from(error: RecordValidationError) -> Self {
        Self::InvalidMany(error.issues())
    }
}

/// Validates a record against its schema, reporting every field issue found.
/// A wrong collection is an early exit; nothing else is meaningful then.
///
/// `apply_defaults` marks a creation: absent fields take their defaults (a relative Date default
/// resolves from the record's creation day) and every value must be pickable now. Without it the
/// record is a stored one being projected, so a Choice value that points at a removed option of
/// the same field is kept as valid.
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
    let mut issues: Vec<_> = record
        .values
        .keys()
        .filter(|id| !active.contains(id))
        .map(|id| RecordFieldIssue {
            field: *id,
            code: IssueCode::FieldUnavailable,
            message: "This field is no longer available".into(),
        })
        .collect();
    let creation_day = record.creation_day();
    if apply_defaults {
        // A new set drops repeats and reads as Null when empty.
        for value in record.values.values_mut() {
            if let FieldValue::EnumSet(ids) = value {
                *value = FieldValue::enum_set(ids.iter().copied());
            }
        }
    }
    for field in schema.fields.iter().filter(|field| !field.deleted) {
        if !record.values.contains_key(&field.id)
            && apply_defaults
            && let Some(default) = field.resolved_default(creation_day)
        {
            record.values.insert(field.id, default);
        }
        match record.values.get(&field.id) {
            // A default satisfies requiredness even on the projection path, where defaults are not
            // inserted: the field reads as its default everywhere, so the record is not missing it.
            None if field.required && !field.has_default() => {
                issues.push(RecordFieldIssue {
                    field: field.id,
                    code: IssueCode::Required,
                    message: "Required".into(),
                });
            }
            Some(value) => {
                let checked = if apply_defaults {
                    field.validate_value(value)
                } else {
                    field.validate_kept_value(value)
                };
                if let Err(issue) = checked {
                    issues.push(RecordFieldIssue::new(field.id, issue));
                }
            }
            None => {}
        }
    }
    if issues.is_empty() {
        Ok(())
    } else {
        Err(RecordValidationError::Fields(issues))
    }
}

impl GenericRecord {
    /// The UTC calendar day (days since the Unix epoch) the record was created, read from its
    /// UUIDv7 id.
    #[must_use]
    pub fn creation_day(&self) -> i64 {
        let seconds = self
            .id
            .as_uuid()
            .get_timestamp()
            .map_or(0, |timestamp| timestamp.to_unix().0);
        i64::try_from(seconds)
            .unwrap_or(i64::MAX)
            .div_euclid(86_400)
    }
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
        // Sets live in per-option membership registers; see `write_set_value`.
        FieldValue::EnumSet(_) => {
            return Err(repo_change(
                "a set of options is written as membership registers",
            ));
        }
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
        FieldValue::EnumSet(_) => "enum_set",
    }
}

/// Separates the field id from the option id in a membership register key. A UUID never holds
/// it, so membership keys can't collide with plain field ids.
pub const MEMBER_KEY_SEPARATOR: char = '/';

/// The `values` key of the membership register of `option` in the Choices field `field`.
#[must_use]
pub fn member_key(field: FieldId, option: EnumOptionId) -> String {
    format!("{field}{MEMBER_KEY_SEPARATOR}{option}")
}

/// Splits a membership register key into its field and option ids.
pub fn parse_member_key(key: &str) -> Option<(FieldId, EnumOptionId)> {
    let (field, option) = key.split_once(MEMBER_KEY_SEPARATOR)?;
    Some((field.parse().ok()?, option.parse().ok()?))
}

/// Reads a Choices value from a record's `values` map.
///
/// Each option resolves on its own: the winning membership register at `<field>/<option>` and a
/// single-value register at `<field>` (left by Choice before a conversion, or by a conversion
/// back) compete by stamp. The single-value register asserts the set it names at its stamp: its
/// option present and every other option absent (a Null register: no member). `None` means
/// nothing was ever written for the field; an empty set reads as Null. The returned stamp is the
/// greatest one involved.
pub fn read_set_value(
    doc: &impl ReadDoc,
    values: &ObjId,
    field: FieldId,
) -> Result<Option<LwwValue>, DomainError> {
    let prefix = format!("{field}{MEMBER_KEY_SEPARATOR}");
    let mut members: BTreeMap<EnumOptionId, LwwValue> = BTreeMap::new();
    for key in doc.keys(values).filter(|key| key.starts_with(&prefix)) {
        let (_, option) = parse_member_key(&key)
            .ok_or_else(|| malformed(format!("invalid membership key {key}")))?;
        if let Some(winner) = read_lww_winner(doc, values, &key)? {
            members.insert(option, winner);
        }
    }
    let legacy = read_lww_winner(doc, values, &field.to_string())?;
    if members.is_empty() && legacy.is_none() {
        return Ok(None);
    }
    let legacy_option = match &legacy {
        Some(LwwValue {
            value: FieldValue::Enum(option),
            ..
        }) => Some(*option),
        _ => None,
    };
    let legacy_stamp = legacy.as_ref().map(|legacy| legacy.stamp);
    let mut stamp = legacy_stamp;
    let mut present = Vec::new();
    for (option, member) in &members {
        stamp = Some(stamp.map_or(member.stamp, |current| current.max(member.stamp)));
        let held = match member.value {
            FieldValue::Boolean(held) => held,
            _ => return Err(malformed("membership register is not Boolean")),
        };
        let held = match legacy_stamp {
            Some(legacy_stamp) if legacy_stamp > member.stamp => legacy_option == Some(*option),
            _ => held,
        };
        if held {
            present.push(*option);
        }
    }
    if let Some(option) = legacy_option
        && !members.contains_key(&option)
    {
        present.push(option);
    }
    Ok(Some(LwwValue {
        value: FieldValue::enum_set(present),
        stamp: stamp.expect("a register was read"),
    }))
}

/// Writes a Choices value (`FieldValue::EnumSet` or `FieldValue::Null`) as membership registers:
/// only options whose membership changes against the current value are written (plus kept members
/// that so far live only in a single-value register), all under `stamp`. When the new set is empty and nothing was ever written, a Null single-value register
/// marks the field as written.
pub fn write_set_value(
    tx: &mut AutomergeTransaction<'_>,
    values: &ObjId,
    field: FieldId,
    value: &FieldValue,
    stamp: HlcStamp,
) -> automerge_repo::Result<()> {
    let wanted: &[EnumOptionId] = match value {
        FieldValue::EnumSet(ids) => ids,
        FieldValue::Null => &[],
        _ => return Err(repo_change("a Choices field takes a set of options")),
    };
    let current = read_set_value(tx, values, field).map_err(repo_change)?;
    let held: Vec<EnumOptionId> = match current.as_ref().map(|current| &current.value) {
        Some(FieldValue::EnumSet(ids)) => ids.clone(),
        _ => Vec::new(),
    };
    if current.is_none() && wanted.is_empty() {
        return write_lww_register(tx, values, &field.to_string(), &FieldValue::Null, stamp);
    }
    // A member read only from a single-value register has no membership register of its own;
    // it is written so that a later single-value register can't silently drop it.
    let prefix = format!("{field}{MEMBER_KEY_SEPARATOR}");
    let stored: HashSet<EnumOptionId> = tx
        .keys(values)
        .filter_map(|key| {
            key.starts_with(&prefix)
                .then(|| parse_member_key(&key).map(|(_, option)| option))
                .flatten()
        })
        .collect();
    for option in held
        .iter()
        .filter(|option| wanted.contains(option) && !stored.contains(option))
    {
        write_lww_register(
            tx,
            values,
            &member_key(field, *option),
            &FieldValue::Boolean(true),
            stamp,
        )?;
    }
    for option in held.iter().filter(|option| !wanted.contains(option)) {
        write_lww_register(
            tx,
            values,
            &member_key(field, *option),
            &FieldValue::Boolean(false),
            stamp,
        )?;
    }
    let mut added = HashSet::new();
    for option in wanted.iter().filter(|option| !held.contains(option)) {
        if added.insert(*option) {
            write_lww_register(
                tx,
                values,
                &member_key(field, *option),
                &FieldValue::Boolean(true),
                stamp,
            )?;
        }
    }
    Ok(())
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
                default_relative_days: None,
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
                default_relative_days: None,
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
            Err(RecordValidationError::Fields(vec![RecordFieldIssue {
                field: field_id,
                code: IssueCode::Required,
                message: "Required".into(),
            }]))
        );
    }

    fn field(name: &str, field_type: FieldType, required: bool) -> FieldDefinition {
        FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type,
            required,
            default: None,
            default_relative_days: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order: 0,
            deleted: false,
            enum_options: vec![],
        }
    }

    #[test]
    fn every_field_issue_is_reported_with_its_field_and_no_ids_in_messages() {
        let collection_id = CollectionSchemaId::new();
        let title = FieldDefinition {
            validation: ValidationMetadata {
                min_length: Some(1),
                max_length: Some(40),
                ..ValidationMetadata::default()
            },
            ..field("Title", FieldType::Text, true)
        };
        let intensity = FieldDefinition {
            validation: ValidationMetadata {
                min_integer: Some(1),
                max_integer: Some(10),
                ..ValidationMetadata::default()
            },
            ..field("Intensity", FieldType::Integer, false)
        };
        let note = field("Note", FieldType::Text, true);
        let schema = CollectionSchema {
            id: collection_id,
            name: "Headaches".into(),
            description: String::new(),
            deleted: false,
            fields: vec![title.clone(), intensity.clone(), note.clone()],
        };
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id,
            values: BTreeMap::from([
                (title.id, FieldValue::Text("x".repeat(41))),
                (intensity.id, FieldValue::Integer(11)),
            ]),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        let Err(RecordValidationError::Fields(issues)) =
            validate_record(&mut record, &schema, true)
        else {
            panic!("expected field issues");
        };
        assert_eq!(
            issues
                .iter()
                .map(|issue| (issue.field, issue.code, issue.message.as_str()))
                .collect::<Vec<_>>(),
            vec![
                (title.id, IssueCode::Length, "Must be 1–40 characters"),
                (
                    intensity.id,
                    IssueCode::OutOfRange,
                    "Must be between 1 and 10"
                ),
                (note.id, IssueCode::Required, "Required"),
            ]
        );
        let error = RecordValidationError::Fields(issues);
        for issue in error.issues() {
            for id in [title.id, intensity.id, note.id] {
                assert!(!issue.message.contains(&id.to_string()));
            }
            assert_eq!(issue.fields.len(), 1);
        }
        assert_eq!(error.to_string(), "3 problems need attention");
    }

    #[test]
    fn relative_date_default_resolves_from_the_creation_day() {
        use uuid::{NoContext, Timestamp};
        let day = |year, month, date| {
            chrono::NaiveDate::from_ymd_opt(year, month, date)
                .unwrap()
                .signed_duration_since(chrono::NaiveDate::from_ymd_opt(1970, 1, 1).unwrap())
                .num_days()
        };
        let collection_id = CollectionSchemaId::new();
        let due = FieldDefinition {
            default_relative_days: Some(7),
            ..field("Due", FieldType::Date, true)
        };
        let schema = CollectionSchema {
            id: collection_id,
            name: "Tasks".into(),
            description: String::new(),
            deleted: false,
            fields: vec![due.clone()],
        };
        // 2026-09-28 at 23:59:59 UTC.
        let created = u64::try_from(day(2026, 9, 28) * 86_400 + 86_399).unwrap();
        let mut record = GenericRecord {
            id: RecordId(Uuid::new_v7(Timestamp::from_unix(NoContext, created, 0))),
            collection_id,
            values: BTreeMap::new(),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        assert_eq!(record.creation_day(), day(2026, 9, 28));
        validate_record(&mut record, &schema, true).unwrap();
        assert_eq!(
            record.values.get(&due.id),
            Some(&FieldValue::Date(day(2026, 10, 5)))
        );

        // On read a relative default satisfies Required without being inserted.
        record.values.clear();
        validate_record(&mut record, &schema, false).unwrap();
        assert!(record.values.is_empty());
    }

    #[test]
    fn a_resolved_relative_default_is_checked_against_the_range() {
        let collection_id = CollectionSchemaId::new();
        let due = FieldDefinition {
            default_relative_days: Some(7),
            validation: ValidationMetadata {
                max_integer: Some(0),
                ..ValidationMetadata::default()
            },
            ..field("Due", FieldType::Date, false)
        };
        let schema = CollectionSchema {
            id: collection_id,
            name: "Tasks".into(),
            description: String::new(),
            deleted: false,
            fields: vec![due.clone()],
        };
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id,
            values: BTreeMap::new(),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        let Err(RecordValidationError::Fields(issues)) =
            validate_record(&mut record, &schema, true)
        else {
            panic!("expected an out-of-range default");
        };
        assert_eq!(issues[0].code, IssueCode::OutOfRange);
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
