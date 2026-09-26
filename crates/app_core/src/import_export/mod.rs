//! Portable collection data: the `fi-collection` JSON envelope and CSV record files.
//!
//! Rust owns encoding, parsing and validation; the platform layer only moves text in and out of
//! files. Exports carry active data only (no tombstones, no HLC stamps). Imports never modify an
//! existing collection: CSV rows become new records, envelope entries become new collections with
//! fresh identities.

pub mod csv;

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::{
    error::DomainError,
    query::{ComputedFieldDefinition, QueryDefinition},
    records::{GenericRecord, RecordId},
    remap::{ClonePlan, IdRemap, plan_with_remap, remap_record_values},
    schema::{CollectionSchema, CollectionSchemaId, FieldId},
    values::FieldValue,
    widgets::WidgetDefinition,
};

pub const ENVELOPE_FORMAT: &str = "fi-collection";
pub const ENVELOPE_VERSION: u32 = 1;

/// Top-level JSON document. Unknown top-level keys are ignored.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub format: String,
    pub version: u32,
    pub collections: Vec<ExportedCollection>,
}

/// One collection with its active structure and records, using the core serde forms.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ExportedCollection {
    pub schema: CollectionSchema,
    #[serde(default)]
    pub computed_fields: Vec<ComputedFieldDefinition>,
    #[serde(default)]
    pub queries: Vec<QueryDefinition>,
    #[serde(default)]
    pub widgets: Vec<WidgetDefinition>,
    #[serde(default)]
    pub records: Vec<ExportedRecord>,
}

/// A record without stamps, tombstone or owning collection; the entry it sits in owns it.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ExportedRecord {
    pub id: RecordId,
    pub values: BTreeMap<FieldId, FieldValue>,
}

impl Envelope {
    #[must_use]
    pub fn new(collections: Vec<ExportedCollection>) -> Self {
        Self {
            format: ENVELOPE_FORMAT.into(),
            version: ENVELOPE_VERSION,
            collections,
        }
    }

    pub fn to_json(&self) -> Result<String, DomainError> {
        serde_json::to_string_pretty(self).map_err(|error| DomainError::Invalid {
            field: "export",
            message: error.to_string(),
        })
    }

    /// Parses a document, checking `format` and `version` before the body so a document from a
    /// newer app reports a version error rather than a shape error.
    pub fn parse(text: &str) -> Result<Self, ImportAbort> {
        #[derive(Deserialize)]
        struct Header {
            format: Option<String>,
            version: Option<u64>,
        }
        let header: Header = serde_json::from_str(text).map_err(|error| {
            ImportAbort::envelope(format!("not a valid JSON document: {error}"))
        })?;
        if header.format.as_deref() != Some(ENVELOPE_FORMAT) {
            return Err(ImportAbort::envelope(format!(
                "format must be \"{ENVELOPE_FORMAT}\""
            )));
        }
        match header.version {
            Some(version) if version == u64::from(ENVELOPE_VERSION) => {}
            Some(version) => {
                return Err(ImportAbort::envelope(format!(
                    "unsupported version {version}; this app reads version {ENVELOPE_VERSION}"
                )));
            }
            None => return Err(ImportAbort::envelope("missing version")),
        }
        let envelope: Self = serde_json::from_str(text)
            .map_err(|error| ImportAbort::envelope(format!("invalid document: {error}")))?;
        if envelope.collections.is_empty() {
            return Err(ImportAbort::envelope("contains no collections"));
        }
        Ok(envelope)
    }
}

impl ExportedCollection {
    /// Keeps only active data: active fields with their active options, active definitions owned
    /// by the collection, active records with values for active fields. Stamps are dropped.
    #[must_use]
    pub fn from_active(
        schema: &CollectionSchema,
        computed_fields: &[ComputedFieldDefinition],
        queries: &[QueryDefinition],
        widgets: &[WidgetDefinition],
        records: &[GenericRecord],
    ) -> Self {
        let owned = |collection_id: CollectionSchemaId, deleted: bool| {
            collection_id == schema.id && !deleted
        };
        let mut fields: Vec<_> = schema
            .fields
            .iter()
            .filter(|field| !field.deleted)
            .cloned()
            .collect();
        for field in &mut fields {
            field.enum_options.retain(|option| !option.deleted);
        }
        let active: HashSet<_> = fields.iter().map(|field| field.id).collect();
        Self {
            schema: CollectionSchema {
                fields,
                ..schema.clone()
            },
            computed_fields: computed_fields
                .iter()
                .filter(|item| owned(item.collection_id, item.deleted))
                .cloned()
                .collect(),
            queries: queries
                .iter()
                .filter(|item| owned(item.collection_id, item.deleted))
                .cloned()
                .collect(),
            widgets: widgets
                .iter()
                .filter(|item| owned(item.collection_id, item.deleted))
                .cloned()
                .collect(),
            records: records
                .iter()
                .filter(|record| owned(record.collection_id, record.deleted))
                .map(|record| ExportedRecord {
                    id: record.id,
                    values: record
                        .values
                        .iter()
                        .filter(|(field, _)| active.contains(field))
                        .map(|(field, value)| (*field, value.clone()))
                        .collect(),
                })
                .collect(),
        }
    }
}

/// One envelope entry after identity remapping: new collection, definitions and records, ready
/// for validation and a single write.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ImportedCollection {
    pub plan: ClonePlan,
    pub records: Vec<GenericRecord>,
}

/// Gives every entry of `envelope` fresh identities for the collection, fields, enum options,
/// computed fields, queries, widgets and records, rewriting every internal reference.
pub fn prepare_import(envelope: &Envelope) -> Result<Vec<ImportedCollection>, ImportAbort> {
    envelope
        .collections
        .iter()
        .enumerate()
        .map(|(index, entry)| {
            let abort = |item: &str, reason: String| ImportAbort::Json {
                collection_index: Some(index as u32),
                item: item.into(),
                reason,
            };
            let source = entry.schema.id;
            let foreign = entry
                .computed_fields
                .iter()
                .map(|item| item.collection_id)
                .chain(entry.queries.iter().map(|item| item.collection_id))
                .chain(entry.widgets.iter().map(|item| item.collection_id))
                .any(|collection_id| collection_id != source);
            if foreign {
                return Err(abort(
                    "collection",
                    "a definition belongs to another collection".into(),
                ));
            }
            let remap = IdRemap::for_collection(
                source,
                CollectionSchemaId::new(),
                &entry.schema.fields,
                &entry.computed_fields,
                &entry.queries,
            );
            let plan = plan_with_remap(
                &entry.schema,
                &remap,
                entry.schema.name.trim(),
                &entry.computed_fields,
                &entry.queries,
                &entry.widgets,
            )
            .map_err(|error| abort("collection", error.to_string()))?;
            let records = entry
                .records
                .iter()
                .enumerate()
                .map(|(number, record)| {
                    Ok(GenericRecord {
                        id: RecordId::new(),
                        collection_id: plan.schema.id,
                        values: remap_record_values(&record.values, &remap).map_err(|error| {
                            abort(&format!("record {}", number + 1), error.to_string())
                        })?,
                        stamps: BTreeMap::new(),
                        deleted: false,
                    })
                })
                .collect::<Result<_, _>>()?;
            Ok(ImportedCollection { plan, records })
        })
        .collect()
}

/// Result of an import. An abort wrote nothing.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ImportOutcome {
    Imported {
        collections: Vec<CollectionSchemaId>,
        records: usize,
    },
    Aborted(ImportAbort),
}

/// Why an import was rejected before any write.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ImportAbort {
    /// `row` is the 1-based data row; 0 means the header row.
    Csv {
        row: u32,
        column: String,
        reason: String,
    },
    /// `collection_index` is the 0-based envelope entry, `None` for the document itself.
    Json {
        collection_index: Option<u32>,
        item: String,
        reason: String,
    },
}

impl ImportAbort {
    fn envelope(reason: impl Into<String>) -> Self {
        Self::Json {
            collection_index: None,
            item: "document".into(),
            reason: reason.into(),
        }
    }
}

impl std::fmt::Display for ImportAbort {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Csv {
                row: 0,
                column,
                reason,
            } => write!(formatter, "header, column {column}: {reason}"),
            Self::Csv {
                row,
                column,
                reason,
            } if column.is_empty() => write!(formatter, "row {row}: {reason}"),
            Self::Csv {
                row,
                column,
                reason,
            } => write!(formatter, "row {row}, column {column}: {reason}"),
            Self::Json {
                collection_index: None,
                item,
                reason,
            } => write!(formatter, "{item}: {reason}"),
            Self::Json {
                collection_index: Some(index),
                item,
                reason,
            } => write!(formatter, "collection {}, {item}: {reason}", index + 1),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        query::{
            Aggregation, CalendarPolicy, CollectionQuery, ComparisonOperator, ComputedFieldId,
            Expression, FieldReference, QueryId, QueryShape, TypedValue, ValueType,
            VersionedCollectionQuery, VersionedExpression,
        },
        schema::{
            DisplayMetadata, EnumOption, EnumOptionId, FieldDefinition, FieldType,
            ValidationMetadata,
        },
        widgets::{WidgetConfiguration, WidgetId, WidgetLayout, WidgetType},
    };

    fn field(name: &str, field_type: FieldType, order: i64) -> FieldDefinition {
        FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type,
            required: false,
            default: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order,
            deleted: false,
            enum_options: vec![],
        }
    }

    /// A collection with every field type, an enum option, a computed field, a query and a
    /// widget, plus one record.
    fn sample() -> ExportedCollection {
        let id = CollectionSchemaId::new();
        let mut kind = field("Kind", FieldType::Enum, 7);
        kind.enum_options = vec![EnumOption {
            id: EnumOptionId::new(),
            label: "Mild".into(),
            order: 0,
            deleted: false,
        }];
        let fields = vec![
            field("Note", FieldType::Text, 0),
            field("Count", FieldType::Integer, 1),
            field("Cost", FieldType::FixedDecimal { scale: 2 }, 2),
            field("Done", FieldType::Boolean, 3),
            field("Day", FieldType::Date, 4),
            field("At", FieldType::DateTime, 5),
            field("Took", FieldType::Duration, 6),
            kind,
        ];
        let computed = ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id: id,
            name: "Twice".into(),
            declared_type: ValueType::Integer,
            nullable: true,
            expression: VersionedExpression::new(Expression::Abs {
                expression: Box::new(Expression::Field {
                    field: FieldReference::Source(fields[1].id),
                }),
            }),
            order: 0,
            deleted: false,
        };
        let query = QueryDefinition {
            id: QueryId::new(),
            collection_id: id,
            name: "Mild count".into(),
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id: id,
                filter: Some(Expression::Compare {
                    operator: ComparisonOperator::Equal,
                    left: Box::new(Expression::Field {
                        field: FieldReference::Source(fields[7].id),
                    }),
                    right: Box::new(Expression::Constant {
                        value: TypedValue::Enum(fields[7].enum_options[0].id),
                    }),
                }),
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
        let widget = WidgetDefinition {
            id: WidgetId::new(),
            collection_id: id,
            widget_type: WidgetType::new("core.aggregate-number").unwrap(),
            query_id: query.id,
            title: "Mild".into(),
            configuration: WidgetConfiguration::empty(),
            layout: WidgetLayout::default(),
            order: 0,
            deleted: false,
        };
        let values = BTreeMap::from([
            (fields[0].id, FieldValue::Text("a, \"quoted\"\nline".into())),
            (fields[1].id, FieldValue::Integer(-3)),
            (fields[2].id, FieldValue::FixedDecimal(150)),
            (fields[3].id, FieldValue::Boolean(true)),
            (fields[4].id, FieldValue::Date(19_783)),
            (fields[5].id, FieldValue::DateTime(1_709_288_100_000)),
            (fields[6].id, FieldValue::Duration(90_000)),
            (fields[7].id, FieldValue::Enum(fields[7].enum_options[0].id)),
        ]);
        ExportedCollection {
            schema: CollectionSchema {
                id,
                name: "Headache".into(),
                description: "Daily log".into(),
                fields,
                deleted: false,
            },
            computed_fields: vec![computed],
            queries: vec![query],
            widgets: vec![widget],
            records: vec![ExportedRecord {
                id: RecordId::new(),
                values,
            }],
        }
    }

    #[test]
    fn envelope_round_trip_is_byte_stable() {
        let envelope = Envelope::new(vec![sample()]);
        let encoded = envelope.to_json().unwrap();
        let decoded = Envelope::parse(&encoded).unwrap();
        assert_eq!(decoded, envelope);
        assert_eq!(decoded.to_json().unwrap(), encoded);
        let value: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        assert_eq!(value["format"], "fi-collection");
        assert_eq!(value["version"], 1);
        let record = &value["collections"][0]["records"][0];
        assert!(record.get("stamps").is_none());
        assert!(record.get("deleted").is_none());
        assert!(record.get("collection_id").is_none());
    }

    #[test]
    fn unknown_top_level_keys_are_ignored_and_unknown_kinds_fail() {
        let encoded = Envelope::new(vec![sample()]).to_json().unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&encoded).unwrap();
        value["exported_by"] = "another build".into();
        assert!(Envelope::parse(&value.to_string()).is_ok());
        value["collections"][0]["schema"]["fields"][0]["field_type"]["kind"] = "colour".into();
        assert!(matches!(
            Envelope::parse(&value.to_string()),
            Err(ImportAbort::Json {
                collection_index: None,
                ..
            })
        ));
    }

    #[test]
    fn wrong_format_or_version_is_rejected_before_the_body() {
        for (document, expected) in [
            (
                r#"{"format":"other","version":1,"collections":[]}"#,
                "format",
            ),
            (
                r#"{"format":"fi-collection","version":2,"collections":7}"#,
                "version 2",
            ),
            (r#"{"format":"fi-collection"}"#, "missing version"),
            ("not json", "not a valid JSON"),
        ] {
            let error = Envelope::parse(document).unwrap_err().to_string();
            assert!(error.contains(expected), "{error}");
        }
    }

    #[test]
    fn from_active_drops_tombstones_and_stale_values() {
        let mut entry = sample();
        let mut gone_field = field("Gone", FieldType::Text, 9);
        gone_field.deleted = true;
        entry.schema.fields.push(gone_field.clone());
        entry.schema.fields[7].enum_options.push(EnumOption {
            id: EnumOptionId::new(),
            label: "Removed".into(),
            order: 1,
            deleted: true,
        });
        let mut gone_query = entry.queries[0].clone();
        gone_query.id = QueryId::new();
        gone_query.deleted = true;
        entry.queries.push(gone_query);
        let mut values = entry.records[0].values.clone();
        values.insert(gone_field.id, FieldValue::Text("stale".into()));
        let live = GenericRecord {
            id: entry.records[0].id,
            collection_id: entry.schema.id,
            values,
            stamps: BTreeMap::new(),
            deleted: false,
        };
        let dead = GenericRecord {
            id: RecordId::new(),
            deleted: true,
            ..live.clone()
        };
        let exported = ExportedCollection::from_active(
            &entry.schema,
            &entry.computed_fields,
            &entry.queries,
            &entry.widgets,
            &[live, dead.clone()],
        );
        assert_eq!(exported.schema.fields.len(), 8);
        assert_eq!(exported.schema.fields[7].enum_options.len(), 1);
        assert_eq!(exported.queries.len(), 1);
        assert_eq!(exported.records.len(), 1);
        assert!(!exported.records[0].values.contains_key(&gone_field.id));
        let encoded = Envelope::new(vec![exported]).to_json().unwrap();
        assert!(!encoded.contains(&gone_field.id.to_string()));
        assert!(!encoded.contains(&dead.id.to_string()));
        assert!(!encoded.contains("Removed"));
    }

    #[test]
    fn prepare_import_assigns_fresh_ids_and_remaps_record_values() {
        let entry = sample();
        let envelope = Envelope::new(vec![entry.clone(), entry.clone()]);
        let imported = prepare_import(&envelope).unwrap();
        assert_eq!(imported.len(), 2);
        assert_ne!(imported[0].plan.schema.id, imported[1].plan.schema.id);
        let source = serde_json::to_string(&entry).unwrap();
        for item in &imported {
            assert_eq!(item.plan.schema.name, "Headache");
            assert_eq!(
                item.plan.widgets[0].query_id,
                item.plan.query_definitions[0].id
            );
            let record = &item.records[0];
            assert_eq!(record.collection_id, item.plan.schema.id);
            let kind = &item.plan.schema.fields[7];
            assert_eq!(
                record.values[&kind.id],
                FieldValue::Enum(kind.enum_options[0].id)
            );
            let ids = std::iter::once(record.id.to_string())
                .chain(std::iter::once(item.plan.schema.id.to_string()))
                .chain(item.plan.schema.fields.iter().map(|f| f.id.to_string()))
                .chain(item.plan.widgets.iter().map(|w| w.id.to_string()));
            for id in ids {
                assert!(!source.contains(&id), "{id} leaked from the source");
            }
        }
    }

    #[test]
    fn prepare_import_rejects_dangling_record_values() {
        let mut entry = sample();
        entry.records[0]
            .values
            .insert(FieldId::new(), FieldValue::Integer(1));
        let error = prepare_import(&Envelope::new(vec![sample(), entry])).unwrap_err();
        assert!(matches!(
            &error,
            ImportAbort::Json { collection_index: Some(1), item, .. } if item == "record 1"
        ));
    }
}
