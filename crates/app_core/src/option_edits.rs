//! Option edits that span the schema and records: saving a record together with options the
//! record form added, and merging options of one field.
//!
//! Both are planned against one snapshot during validation and applied as plain generic
//! commands inside one change under one stamp.

use std::collections::{BTreeMap, HashMap, HashSet};

use crate::{
    error::{DomainError, IssueCode, ValidationIssue},
    generic::{GenericCommand, GenericSnapshot},
    query::{ComputedFieldDefinition, QueryDefinition},
    records::{GenericRecord, RecordId, validate_record},
    remap::{IdRemap, remap_computed, remap_query_definition},
    schema::{CollectionSchema, CollectionSchemaId, EnumOption, EnumOptionId, FieldId, FieldType},
    values::FieldValue,
};

/// Prefix of a draft-local key standing in for an option id in bridge values.
pub const PENDING_OPTION_PREFIX: &str = "pending:";

/// An option the record form added to a field, created only when the record is saved.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PendingOption {
    /// Draft-local key, unique within one command.
    pub key: String,
    pub field_id: FieldId,
    pub label: String,
}

/// A draft field value that may pick pending options by key.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DraftValue {
    Value(FieldValue),
    /// Choice: one pending option.
    PendingChoice(String),
    /// Choices: stored options plus pending options.
    Choices {
        options: Vec<EnumOptionId>,
        pending: Vec<String>,
    },
}

/// The record part of a draft save.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DraftTarget {
    New {
        id: RecordId,
        values: BTreeMap<FieldId, DraftValue>,
    },
    Existing {
        id: RecordId,
        /// Only the fields being changed.
        values: BTreeMap<FieldId, DraftValue>,
    },
}

impl DraftTarget {
    #[must_use]
    pub const fn record_id(&self) -> RecordId {
        match self {
            Self::New { id, .. } | Self::Existing { id, .. } => *id,
        }
    }
    #[must_use]
    pub const fn values(&self) -> &BTreeMap<FieldId, DraftValue> {
        match self {
            Self::New { values, .. } | Self::Existing { values, .. } => values,
        }
    }
}

/// A draft with every pending option resolved to an option id.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResolvedDraft {
    /// The collection with pending options counted as active options.
    pub schema: CollectionSchema,
    pub values: BTreeMap<FieldId, FieldValue>,
    /// Options to create, in pending order.
    pub created: Vec<(FieldId, EnumOption)>,
    /// Problems with the pending options themselves, each on its field.
    pub issues: Vec<ValidationIssue>,
}

fn issue(field: FieldId, message: &str) -> ValidationIssue {
    ValidationIssue::new(IssueCode::Invalid, message).on(field)
}

/// Resolves pending options against `schema`: a label equal to an active option of the field
/// ignoring case uses that option; any other becomes a new option after the field's last one.
#[must_use]
pub fn resolve_draft(
    schema: &CollectionSchema,
    values: &BTreeMap<FieldId, DraftValue>,
    pending: &[PendingOption],
) -> ResolvedDraft {
    let mut augmented = schema.clone();
    let mut issues = Vec::new();
    let mut created = Vec::new();
    let mut keys: HashMap<&str, (FieldId, EnumOptionId)> = HashMap::new();
    let mut labels: HashSet<(FieldId, String)> = HashSet::new();
    let mut failed: HashSet<&str> = HashSet::new();
    for option in pending {
        let Some(field) = augmented
            .fields
            .iter_mut()
            .find(|field| field.id == option.field_id && !field.deleted)
        else {
            issues.push(issue(option.field_id, "This field is no longer available"));
            failed.insert(option.key.as_str());
            continue;
        };
        if !field.field_type.has_options() || !field.allow_options_from_records {
            issues.push(issue(field.id, "This field doesn't allow adding options"));
            failed.insert(option.key.as_str());
            continue;
        }
        let label = option.label.trim();
        let length = label.chars().count();
        if length == 0 || length > 120 {
            issues.push(issue(field.id, "Option names must be 1 to 120 characters"));
            failed.insert(option.key.as_str());
            continue;
        }
        if let Err(DomainError::Invalid { message, .. }) = field.validate_option_label(label) {
            issues.push(issue(field.id, &message));
            failed.insert(option.key.as_str());
            continue;
        }
        if !labels.insert((field.id, label.to_lowercase())) {
            issues.push(issue(field.id, "Two new options have the same name"));
            failed.insert(option.key.as_str());
            continue;
        }
        if keys.contains_key(option.key.as_str()) {
            issues.push(issue(field.id, "Two new options share a key"));
            failed.insert(option.key.as_str());
            continue;
        }
        let existing = field
            .enum_options
            .iter()
            .filter(|item| !item.deleted)
            .find(|item| item.label.trim().to_lowercase() == label.to_lowercase())
            .map(|item| item.id);
        let id = existing.unwrap_or_else(|| {
            let order = field
                .enum_options
                .iter()
                .map(|item| item.order)
                .max()
                .map_or(0, |max| max.saturating_add(1));
            let created_option = EnumOption {
                id: EnumOptionId::new(),
                label: label.to_owned(),
                order,
                deleted: false,
                merged_into: None,
            };
            field.enum_options.push(created_option.clone());
            created.push((field.id, created_option.clone()));
            created_option.id
        });
        keys.insert(option.key.as_str(), (field.id, id));
    }
    let mut used: HashSet<String> = HashSet::new();
    let mut resolved = BTreeMap::new();
    let mut lookup = |field_id: FieldId, key: &str, issues: &mut Vec<ValidationIssue>| {
        if let Some((owner, id)) = keys.get(key)
            && *owner == field_id
        {
            used.insert(key.to_owned());
            Some(*id)
        } else {
            // A pending option that failed already has its issue on the field.
            if !failed.contains(key) {
                issues.push(issue(field_id, "Pick an existing or new option"));
            }
            None
        }
    };
    for (field_id, value) in values {
        let field_type = augmented
            .fields
            .iter()
            .find(|field| field.id == *field_id)
            .map(|field| field.field_type.clone());
        let value = match value {
            DraftValue::Value(value) => value.clone(),
            DraftValue::PendingChoice(key) => {
                if field_type != Some(FieldType::Enum) {
                    issues.push(issue(*field_id, "Value does not match this field's type"));
                    continue;
                }
                match lookup(*field_id, key, &mut issues) {
                    Some(id) => FieldValue::Enum(id),
                    None => continue,
                }
            }
            DraftValue::Choices { options, pending } => {
                if field_type != Some(FieldType::EnumSet) {
                    issues.push(issue(*field_id, "Value does not match this field's type"));
                    continue;
                }
                let mut ids = options.clone();
                for key in pending {
                    if let Some(id) = lookup(*field_id, key, &mut issues) {
                        ids.push(id);
                    }
                }
                FieldValue::enum_set(ids)
            }
        };
        resolved.insert(*field_id, value);
    }
    for option in pending {
        if keys.contains_key(option.key.as_str()) && !used.contains(option.key.as_str()) {
            issues.push(issue(option.field_id, "A new option is not picked"));
        }
    }
    ResolvedDraft {
        schema: augmented,
        values: resolved,
        created,
        issues,
    }
}

/// Validates a draft save against `snapshot` and returns the commands that apply it.
pub fn plan_record_draft(
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
    target: &DraftTarget,
    pending: &[PendingOption],
) -> Result<Vec<GenericCommand>, DomainError> {
    let schema = snapshot
        .collections
        .iter()
        .find(|item| item.id == collection_id && !item.deleted)
        .ok_or_else(|| DomainError::NotFound {
            kind: "collection",
            id: collection_id.to_string(),
        })?;
    let resolved = resolve_draft(schema, target.values(), pending);
    if !resolved.issues.is_empty() {
        return Err(DomainError::InvalidMany(resolved.issues));
    }
    let mut plan: Vec<GenericCommand> = resolved
        .created
        .iter()
        .map(|(field_id, option)| GenericCommand::UpsertEnumOption {
            collection_id,
            field_id: *field_id,
            option: option.clone(),
        })
        .collect();
    match target {
        DraftTarget::New { id, .. } => {
            if snapshot.records.iter().any(|item| item.id == *id) {
                return Err(DomainError::Invalid {
                    field: "record_id",
                    message: "already exists".into(),
                });
            }
            let mut record = GenericRecord {
                id: *id,
                collection_id,
                values: resolved.values,
                stamps: BTreeMap::new(),
                deleted: false,
            };
            validate_record(&mut record, &resolved.schema, true)?;
            plan.push(GenericCommand::CreateRecord(record));
        }
        DraftTarget::Existing { id, .. } => {
            let existing = snapshot
                .records
                .iter()
                .find(|item| item.id == *id && !item.deleted)
                .ok_or_else(|| DomainError::NotFound {
                    kind: "record",
                    id: id.to_string(),
                })?;
            if existing.collection_id != collection_id {
                return Err(DomainError::Invalid {
                    field: "record_id",
                    message: "belongs to a different collection".into(),
                });
            }
            // A minimal snapshot: the augmented schema and the one record, so each field update
            // runs the ordinary update validation with pending options counted active.
            let scoped = GenericSnapshot {
                collections: vec![resolved.schema.clone()],
                records: vec![existing.clone()],
                ..GenericSnapshot::empty()
            };
            let mut issues = Vec::new();
            for (field_id, value) in resolved.values {
                if existing.values.get(&field_id) == Some(&value) {
                    continue;
                }
                let mut command = GenericCommand::UpdateRecordField {
                    record_id: *id,
                    field_id,
                    value,
                };
                match command.validate_against(&scoped) {
                    Ok(()) => plan.push(command),
                    Err(DomainError::InvalidMany(found)) => issues.extend(found),
                    Err(other) => return Err(other),
                }
            }
            if !issues.is_empty() {
                return Err(DomainError::InvalidMany(issues));
            }
        }
    }
    Ok(plan)
}

/// Validates a merge of `merge` into `keep` and returns the commands that apply it.
pub fn plan_merge(
    snapshot: &GenericSnapshot,
    collection_id: CollectionSchemaId,
    field_id: FieldId,
    keep: EnumOptionId,
    merge: &[EnumOptionId],
) -> Result<Vec<GenericCommand>, DomainError> {
    let invalid = |message: &str| DomainError::Invalid {
        field: "merge",
        message: message.into(),
    };
    let schema = snapshot
        .collections
        .iter()
        .find(|item| item.id == collection_id && !item.deleted)
        .ok_or_else(|| DomainError::NotFound {
            kind: "collection",
            id: collection_id.to_string(),
        })?;
    let field = schema
        .fields
        .iter()
        .find(|field| field.id == field_id && !field.deleted)
        .ok_or_else(|| DomainError::NotFound {
            kind: "field",
            id: field_id.to_string(),
        })?;
    if !field.field_type.has_options() {
        return Err(invalid(
            "only Choice and Choices fields have options to merge",
        ));
    }
    if !field
        .enum_options
        .iter()
        .any(|option| option.id == keep && !option.deleted)
    {
        return Err(invalid(
            "the kept option must be an active option of the field",
        ));
    }
    if merge.is_empty() {
        return Err(invalid("pick at least one option to merge"));
    }
    let merged: HashSet<_> = merge.iter().copied().collect();
    if merged.len() != merge.len() {
        return Err(invalid("an option is listed twice"));
    }
    if merged.contains(&keep) {
        return Err(invalid("the kept option can't also be merged"));
    }
    for id in merge {
        let option = field
            .enum_options
            .iter()
            .find(|option| option.id == *id)
            .ok_or_else(|| invalid("an option belongs to another field"))?;
        if option.deleted && option.merged_into.is_none() {
            return Err(invalid("a removed option can't be merged"));
        }
    }

    let swap = |id: EnumOptionId| if merged.contains(&id) { keep } else { id };
    let rewrite = |value: &FieldValue| -> Option<FieldValue> {
        match value {
            FieldValue::Enum(id) if merged.contains(id) => Some(FieldValue::Enum(keep)),
            FieldValue::EnumSet(ids) if ids.iter().any(|id| merged.contains(id)) => {
                Some(FieldValue::enum_set(ids.iter().copied().map(swap)))
            }
            _ => None,
        }
    };

    let mut updated = field.clone();
    for option in &mut updated.enum_options {
        if merged.contains(&option.id) {
            option.deleted = true;
            option.merged_into = Some(keep);
        }
    }
    if let Some(default) = updated.default.as_ref().and_then(rewrite) {
        updated.default = Some(default);
    }
    let mut plan = vec![GenericCommand::UpdateField {
        collection_id,
        field: updated,
    }];
    for record in snapshot
        .records
        .iter()
        .filter(|record| record.collection_id == collection_id && !record.deleted)
    {
        if let Some(value) = record.values.get(&field_id).and_then(rewrite) {
            plan.push(GenericCommand::UpdateRecordField {
                record_id: record.id,
                field_id,
                value,
            });
        }
    }

    let remap = identity_remap(
        schema,
        &snapshot.computed_fields,
        &snapshot.query_definitions,
        &merged,
        keep,
    );
    for definition in snapshot
        .computed_fields
        .iter()
        .filter(|item| item.collection_id == collection_id && !item.deleted)
    {
        if let Ok(rewritten) = remap_computed(definition, &remap)
            && rewritten_differs_computed(definition, &rewritten)
        {
            plan.push(GenericCommand::UpdateComputedField(rewritten));
        }
    }
    for definition in snapshot
        .query_definitions
        .iter()
        .filter(|item| item.collection_id == collection_id && !item.deleted)
    {
        if let Ok(rewritten) = remap_query_definition(definition, &remap)
            && rewritten_differs_query(definition, &rewritten)
        {
            plan.push(GenericCommand::UpdateQuery(rewritten));
        }
    }
    Ok(plan)
}

fn rewritten_differs_computed(
    before: &ComputedFieldDefinition,
    after: &ComputedFieldDefinition,
) -> bool {
    before.expression.expression().ok() != after.expression.expression().ok()
}

fn rewritten_differs_query(before: &QueryDefinition, after: &QueryDefinition) -> bool {
    before.query.query().ok() != after.query.query().ok()
}

/// A table mapping every id of the collection to itself except merged options, which map to the
/// kept option.
fn identity_remap(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    queries: &[QueryDefinition],
    merged: &HashSet<EnumOptionId>,
    keep: EnumOptionId,
) -> IdRemap {
    IdRemap {
        collection: (schema.id, schema.id),
        fields: schema
            .fields
            .iter()
            .map(|field| (field.id, field.id))
            .collect(),
        options: schema
            .fields
            .iter()
            .flat_map(|field| &field.enum_options)
            .map(|option| {
                let target = if merged.contains(&option.id) {
                    keep
                } else {
                    option.id
                };
                (option.id, target)
            })
            .collect(),
        computed: computed
            .iter()
            .filter(|item| item.collection_id == schema.id)
            .map(|item| (item.id, item.id))
            .collect(),
        queries: queries
            .iter()
            .filter(|item| item.collection_id == schema.id)
            .map(|item| (item.id, item.id))
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use automerge::Automerge;

    use super::*;
    use crate::{
        generic::{apply_generic_command, decode_generic, initialize_generic},
        hlc::{HlcNodeId, HlcStamp},
        query::{
            Aggregation, CalendarPolicy, CollectionQuery, ComparisonOperator, Expression,
            FieldReference, QueryId, QueryShape, SetOperator, TypedValue, VersionedCollectionQuery,
        },
        schema::{DisplayMetadata, FieldDefinition, ValidationMetadata},
        widgets::{WidgetConfiguration, WidgetDefinition, WidgetId, WidgetLayout, WidgetType},
    };

    fn stamp(time: i64, node: u8) -> HlcStamp {
        HlcStamp {
            physical_time_ms: time,
            logical_counter: 0,
            node_id: HlcNodeId([node; 32]),
        }
    }

    fn option(label: &str, order: i64) -> EnumOption {
        EnumOption {
            id: EnumOptionId::new(),
            label: label.into(),
            order,
            deleted: false,
            merged_into: None,
        }
    }

    fn field(name: &str, field_type: FieldType, order: i64) -> FieldDefinition {
        FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type,
            required: false,
            default: None,
            default_relative_days: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order,
            deleted: false,
            enum_options: vec![],
            allow_options_from_records: false,
        }
    }

    /// "Spending": required Text `note`, Choice `category` (Groceries, groceries, Rent) and
    /// Choices `tags` (food, work, Groceries, groceries), both allowing new options.
    struct Fixture {
        doc: Automerge,
        schema: CollectionSchema,
    }

    impl Fixture {
        fn new() -> Self {
            let mut doc = Automerge::new();
            let mut tx = doc.transaction();
            initialize_generic(&mut tx).unwrap();
            tx.commit();
            let note = FieldDefinition {
                required: true,
                ..field("note", FieldType::Text, 0)
            };
            let mut category = field("category", FieldType::Enum, 1);
            category.allow_options_from_records = true;
            category.enum_options = vec![
                option("Groceries", 0),
                option("groceries", 1),
                option("Rent", 2),
            ];
            let mut tags = field("tags", FieldType::EnumSet, 2);
            tags.allow_options_from_records = true;
            tags.enum_options = vec![
                option("food", 0),
                option("work", 1),
                option("Groceries", 2),
                option("groceries", 3),
            ];
            let schema = CollectionSchema {
                id: CollectionSchemaId::new(),
                name: "Spending".into(),
                description: String::new(),
                fields: vec![note, category, tags],
                deleted: false,
            };
            let mut fixture = Self { doc, schema };
            fixture.commit(GenericCommand::CreateCollection(fixture.schema.clone()), 1);
            fixture
        }
        fn note(&self) -> FieldId {
            self.schema.fields[0].id
        }
        fn category(&self) -> &FieldDefinition {
            &self.schema.fields[1]
        }
        fn tags(&self) -> &FieldDefinition {
            &self.schema.fields[2]
        }
        fn snapshot(&self) -> GenericSnapshot {
            decode_generic(&self.doc).unwrap()
        }
        fn try_commit(
            &mut self,
            mut command: GenericCommand,
            time: i64,
        ) -> Result<usize, DomainError> {
            command.validate_against(&self.snapshot())?;
            let before = self.doc.get_heads();
            let mut tx = self.doc.transaction();
            apply_generic_command(&mut tx, &command, stamp(time, 1)).unwrap();
            tx.commit();
            Ok(self.doc.get_changes(&before).len())
        }
        fn commit(&mut self, command: GenericCommand, time: i64) -> usize {
            self.try_commit(command, time).unwrap()
        }
        fn record(&mut self, values: BTreeMap<FieldId, FieldValue>, time: i64) -> RecordId {
            let record = GenericRecord {
                id: RecordId::new(),
                collection_id: self.schema.id,
                values,
                stamps: BTreeMap::new(),
                deleted: false,
            };
            let id = record.id;
            self.commit(GenericCommand::CreateRecord(record), time);
            id
        }
        fn note_record(&mut self, field: FieldId, value: FieldValue, time: i64) -> RecordId {
            let note = self.note();
            self.record(
                BTreeMap::from([(note, FieldValue::Text("x".into())), (field, value)]),
                time,
            )
        }
        fn field_now(&self, id: FieldId) -> FieldDefinition {
            self.snapshot().collections[0]
                .fields
                .iter()
                .find(|field| field.id == id)
                .unwrap()
                .clone()
        }
        fn value(&self, record: RecordId, field: FieldId) -> Option<FieldValue> {
            self.snapshot()
                .records
                .iter()
                .find(|item| item.id == record)
                .unwrap()
                .values
                .get(&field)
                .cloned()
        }
        fn draft(&self, target: DraftTarget, pending: Vec<PendingOption>) -> GenericCommand {
            GenericCommand::SaveRecordDraft {
                collection_id: self.schema.id,
                record: target,
                pending_options: pending,
                plan: None,
            }
        }
        fn merge(
            &self,
            field: FieldId,
            keep: EnumOptionId,
            merge: Vec<EnumOptionId>,
        ) -> GenericCommand {
            GenericCommand::MergeEnumOptions {
                collection_id: self.schema.id,
                field_id: field,
                keep,
                merge,
                plan: None,
            }
        }
    }

    fn pending(key: &str, field: FieldId, label: &str) -> PendingOption {
        PendingOption {
            key: key.into(),
            field_id: field,
            label: label.into(),
        }
    }

    fn option_named(field: &FieldDefinition, label: &str) -> EnumOption {
        field
            .enum_options
            .iter()
            .find(|option| option.label == label && !option.deleted)
            .unwrap()
            .clone()
    }

    #[test]
    fn a_new_record_with_a_new_option_is_one_change() {
        let mut fixture = Fixture::new();
        let category = fixture.category().id;
        let id = RecordId::new();
        let command = fixture.draft(
            DraftTarget::New {
                id,
                values: BTreeMap::from([
                    (
                        fixture.note(),
                        DraftValue::Value(FieldValue::Text("milk".into())),
                    ),
                    (category, DraftValue::PendingChoice("pending:1".into())),
                ]),
            },
            vec![pending("pending:1", category, " Coffee ")],
        );
        assert_eq!(fixture.commit(command, 5), 1);
        let field = fixture.field_now(category);
        let coffee = option_named(&field, "Coffee");
        assert_eq!(coffee.order, 3);
        assert_eq!(
            fixture.value(id, category),
            Some(FieldValue::Enum(coffee.id))
        );
    }

    #[test]
    fn an_edit_with_new_choices_options_writes_only_that_field() {
        let mut fixture = Fixture::new();
        let tags = fixture.tags().clone();
        let food = tags.enum_options[0].id;
        let record = fixture.note_record(tags.id, FieldValue::EnumSet(vec![food]), 2);
        let note_stamp_before = fixture.snapshot().records[0].stamps[&fixture.note()];
        let command = fixture.draft(
            DraftTarget::Existing {
                id: record,
                values: BTreeMap::from([(
                    tags.id,
                    DraftValue::Choices {
                        options: vec![food],
                        pending: vec!["pending:1".into(), "pending:2".into()],
                    },
                )]),
            },
            vec![
                pending("pending:1", tags.id, "coffee"),
                pending("pending:2", tags.id, "travel"),
            ],
        );
        assert_eq!(fixture.commit(command, 6), 1);
        let field = fixture.field_now(tags.id);
        let coffee = option_named(&field, "coffee").id;
        let travel = option_named(&field, "travel").id;
        assert_eq!(
            fixture.value(record, tags.id),
            Some(FieldValue::enum_set([food, coffee, travel]))
        );
        let snapshot = fixture.snapshot();
        assert_eq!(
            snapshot.records[0].stamps[&fixture.note()],
            note_stamp_before
        );
    }

    #[test]
    fn invalid_pending_options_reject_the_whole_save() {
        let mut fixture = Fixture::new();
        let category = fixture.category().id;
        let note = fixture.note();
        let new = |values: BTreeMap<FieldId, DraftValue>| DraftTarget::New {
            id: RecordId::new(),
            values,
        };
        // Setting off.
        let mut closed = fixture.category().clone();
        closed.allow_options_from_records = false;
        fixture.commit(
            GenericCommand::UpdateField {
                collection_id: fixture.schema.id,
                field: closed,
            },
            2,
        );
        let picked = BTreeMap::from([
            (note, DraftValue::Value(FieldValue::Text("x".into()))),
            (category, DraftValue::PendingChoice("pending:1".into())),
        ]);
        let heads = fixture.doc.get_heads();
        let command = fixture.draft(
            new(picked.clone()),
            vec![pending("pending:1", category, "Coffee")],
        );
        assert!(fixture.try_commit(command, 3).is_err());
        // Unused pending option.
        let tags = fixture.tags().id;
        let command = fixture.draft(
            new(BTreeMap::from([(
                note,
                DraftValue::Value(FieldValue::Text("x".into())),
            )])),
            vec![pending("pending:1", tags, "coffee")],
        );
        assert!(fixture.try_commit(command, 4).is_err());
        // A valid pending option but a missing required field.
        let command = fixture.draft(
            new(BTreeMap::from([(
                tags,
                DraftValue::Choices {
                    options: vec![],
                    pending: vec!["pending:1".into()],
                },
            )])),
            vec![pending("pending:1", tags, "coffee")],
        );
        match fixture.try_commit(command, 5) {
            Err(DomainError::InvalidMany(issues)) => {
                assert!(issues.iter().any(|issue| issue.code == IssueCode::Required));
            }
            other => panic!("expected a required issue, got {other:?}"),
        }
        // Semicolon in a Choices label.
        let command = fixture.draft(
            new(BTreeMap::from([
                (note, DraftValue::Value(FieldValue::Text("x".into()))),
                (
                    tags,
                    DraftValue::Choices {
                        options: vec![],
                        pending: vec!["pending:1".into()],
                    },
                ),
            ])),
            vec![pending("pending:1", tags, "a;b")],
        );
        assert!(fixture.try_commit(command, 6).is_err());
        assert_eq!(fixture.doc.get_heads(), heads, "nothing was written");
        assert!(fixture.snapshot().records.is_empty());
    }

    #[test]
    fn a_label_that_arrived_by_sync_is_reused() {
        let mut fixture = Fixture::new();
        let category = fixture.category().clone();
        let id = RecordId::new();
        let command = fixture.draft(
            DraftTarget::New {
                id,
                values: BTreeMap::from([
                    (
                        fixture.note(),
                        DraftValue::Value(FieldValue::Text("x".into())),
                    ),
                    (category.id, DraftValue::PendingChoice("pending:1".into())),
                ]),
            },
            vec![pending("pending:1", category.id, "RENT")],
        );
        fixture.commit(command, 5);
        assert_eq!(fixture.field_now(category.id).enum_options.len(), 3);
        assert_eq!(
            fixture.value(id, category.id),
            Some(FieldValue::Enum(category.enum_options[2].id))
        );
    }

    #[test]
    fn draft_resolution_reports_invalid_labels_on_their_field() {
        let fixture = Fixture::new();
        let category = fixture.category().id;
        let resolved = resolve_draft(
            &fixture.schema,
            &BTreeMap::from([(category, DraftValue::PendingChoice("pending:1".into()))]),
            &[pending("pending:1", category, "  ")],
        );
        assert_eq!(resolved.issues.len(), 1);
        assert!(
            resolved
                .issues
                .iter()
                .all(|issue| issue.fields == vec![category.to_string()])
        );
        let resolved = resolve_draft(
            &fixture.schema,
            &BTreeMap::from([(category, DraftValue::PendingChoice("pending:1".into()))]),
            &[pending("pending:1", category, "Coffee")],
        );
        assert!(resolved.issues.is_empty());
        let mut record = GenericRecord {
            id: RecordId::new(),
            collection_id: fixture.schema.id,
            values: resolved.values,
            stamps: BTreeMap::new(),
            deleted: false,
        };
        let error = validate_record(&mut record, &resolved.schema, true).unwrap_err();
        // Only the required note is missing; the pending pick is an active option.
        assert_eq!(error.issues().len(), 1);
        assert_eq!(error.issues()[0].fields, vec![fixture.note().to_string()]);
    }

    #[test]
    fn merging_a_choice_field_moves_every_active_record_in_one_change() {
        let mut fixture = Fixture::new();
        let category = fixture.category().clone();
        let (keep, gone) = (category.enum_options[0].id, category.enum_options[1].id);
        let mut records = Vec::new();
        for index in 0..12 {
            let option = if index < 9 { keep } else { gone };
            records.push(fixture.note_record(category.id, FieldValue::Enum(option), 2 + index));
        }
        let removed = fixture.note_record(category.id, FieldValue::Enum(gone), 30);
        fixture.commit(GenericCommand::DeleteRecord(removed), 31);
        assert_eq!(
            fixture.commit(fixture.merge(category.id, keep, vec![gone]), 40),
            1
        );
        for record in records {
            assert_eq!(
                fixture.value(record, category.id),
                Some(FieldValue::Enum(keep))
            );
        }
        assert_eq!(
            fixture.value(removed, category.id),
            Some(FieldValue::Enum(gone))
        );
        let field = fixture.field_now(category.id);
        let merged = field
            .enum_options
            .iter()
            .find(|item| item.id == gone)
            .unwrap();
        assert!(merged.deleted);
        assert_eq!(merged.merged_into, Some(keep));
        let kept = field
            .enum_options
            .iter()
            .find(|item| item.id == keep)
            .unwrap();
        assert_eq!(
            (kept.label.as_str(), kept.order, kept.deleted),
            ("Groceries", 0, false)
        );
        assert!(fixture.snapshot().diagnostics.is_empty());
    }

    #[test]
    fn merging_a_choices_field_deduplicates_sets() {
        let mut fixture = Fixture::new();
        let tags = fixture.tags().clone();
        let [food, work, keep, gone] = [0, 1, 2, 3].map(|index| tags.enum_options[index].id);
        let both = fixture.note_record(tags.id, FieldValue::enum_set([keep, gone, food]), 2);
        let only_gone = fixture.note_record(tags.id, FieldValue::enum_set([gone, work]), 3);
        fixture.commit(fixture.merge(tags.id, keep, vec![gone]), 4);
        assert_eq!(
            fixture.value(both, tags.id),
            Some(FieldValue::enum_set([keep, food]))
        );
        assert_eq!(
            fixture.value(only_gone, tags.id),
            Some(FieldValue::enum_set([keep, work]))
        );
    }

    #[test]
    fn references_follow_the_merge() {
        let mut fixture = Fixture::new();
        let category = fixture.category().clone();
        let tags = fixture.tags().clone();
        let (keep, gone) = (category.enum_options[0].id, category.enum_options[1].id);
        let (tag_keep, tag_gone) = (tags.enum_options[2].id, tags.enum_options[3].id);
        let mut with_default = category.clone();
        with_default.default = Some(FieldValue::Enum(gone));
        fixture.commit(
            GenericCommand::UpdateField {
                collection_id: fixture.schema.id,
                field: with_default,
            },
            2,
        );
        let filter = Expression::Boolean {
            operator: crate::query::BooleanOperator::And,
            left: Box::new(Expression::Compare {
                operator: ComparisonOperator::Equal,
                left: Box::new(Expression::Field {
                    field: FieldReference::Source(category.id),
                }),
                right: Box::new(Expression::Constant {
                    value: TypedValue::Enum(gone),
                }),
            }),
            right: Box::new(Expression::SetCompare {
                operator: SetOperator::HasAnyOf,
                left: Box::new(Expression::Field {
                    field: FieldReference::Source(tags.id),
                }),
                right: Box::new(Expression::Constant {
                    value: TypedValue::EnumOptionSet {
                        field: tags.id,
                        options: vec![tag_keep, tag_gone],
                    },
                }),
            }),
        };
        let query_id = QueryId::new();
        let query = QueryDefinition {
            id: query_id,
            collection_id: fixture.schema.id,
            name: "Groceries".into(),
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id: fixture.schema.id,
                filter: Some(filter),
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
        fixture.commit(GenericCommand::CreateQuery(query), 3);
        fixture.commit(
            GenericCommand::CreateWidget(WidgetDefinition {
                id: WidgetId::new(),
                collection_id: fixture.schema.id,
                widget_type: WidgetType::new("core.aggregate-number").unwrap(),
                query_id,
                title: "Groceries".into(),
                configuration: WidgetConfiguration::empty(),
                layout: WidgetLayout::default(),
                order: 0,
                deleted: false,
            }),
            4,
        );
        fixture.commit(fixture.merge(category.id, keep, vec![gone]), 5);
        fixture.commit(fixture.merge(tags.id, tag_keep, vec![tag_gone]), 6);
        assert_eq!(
            fixture.field_now(category.id).default,
            Some(FieldValue::Enum(keep))
        );
        let snapshot = fixture.snapshot();
        let stored = snapshot.query_definitions[0].query.query().unwrap();
        let text = serde_json::to_string(&stored).unwrap();
        assert!(!text.contains(&gone.to_string()));
        assert!(!text.contains(&tag_gone.to_string()));
        assert!(text.contains(&keep.to_string()));
        assert_eq!(
            text.matches(&tag_keep.to_string()).count(),
            1,
            "set is de-duplicated"
        );
        crate::query::validate_query(&stored, &snapshot.collections[0], &snapshot.computed_fields)
            .unwrap();
        assert!(
            snapshot.diagnostics.is_empty(),
            "{:?}",
            snapshot.diagnostics
        );
    }

    #[test]
    fn invalid_merges_are_rejected_without_a_write() {
        let mut fixture = Fixture::new();
        let category = fixture.category().clone();
        let tags = fixture.tags().clone();
        let [keep, gone, rent] = [0, 1, 2].map(|index| category.enum_options[index].id);
        fixture.commit(
            GenericCommand::RemoveEnumOption {
                collection_id: fixture.schema.id,
                field_id: category.id,
                option_id: rent,
            },
            2,
        );
        let heads = fixture.doc.get_heads();
        for (keep, merge) in [
            (keep, vec![keep, gone]),
            (keep, vec![tags.enum_options[0].id]),
            (rent, vec![gone]),
            (keep, vec![]),
            (keep, vec![gone, gone]),
            (keep, vec![rent]),
        ] {
            let command = fixture.merge(category.id, keep, merge);
            assert!(fixture.try_commit(command, 3).is_err());
        }
        let command = fixture.merge(fixture.note(), keep, vec![gone]);
        assert!(fixture.try_commit(command, 3).is_err());
        assert_eq!(fixture.doc.get_heads(), heads);
    }

    #[test]
    fn an_offline_write_of_a_merged_option_stays_valid_and_a_re_merge_moves_it() {
        let mut fixture = Fixture::new();
        let category = fixture.category().clone();
        let (keep, gone) = (category.enum_options[0].id, category.enum_options[1].id);
        let record = fixture.note_record(category.id, FieldValue::Enum(keep), 2);
        let mut offline = fixture.doc.fork();
        fixture.commit(fixture.merge(category.id, keep, vec![gone]), 3);
        // The offline device has not seen the merge and sets the record to "groceries" later.
        let mut command = GenericCommand::UpdateRecordField {
            record_id: record,
            field_id: category.id,
            value: FieldValue::Enum(gone),
        };
        command
            .validate_against(&decode_generic(&offline).unwrap())
            .unwrap();
        let mut tx = offline.transaction();
        apply_generic_command(&mut tx, &command, stamp(10, 2)).unwrap();
        tx.commit();
        fixture.doc.merge(&mut offline).unwrap();
        let snapshot = fixture.snapshot();
        assert_eq!(
            fixture.value(record, category.id),
            Some(FieldValue::Enum(gone))
        );
        assert!(
            snapshot.diagnostics.is_empty(),
            "{:?}",
            snapshot.diagnostics
        );
        // "Move them": merge the merged option again into its recorded target.
        fixture.commit(fixture.merge(category.id, keep, vec![gone]), 20);
        assert_eq!(
            fixture.value(record, category.id),
            Some(FieldValue::Enum(keep))
        );
    }
}
