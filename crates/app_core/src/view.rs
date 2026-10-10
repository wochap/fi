//! Collection views: a named filter, up to three sort keys and an optional grouping, executed
//! by the query engine.

use std::collections::HashMap;

use chrono_tz::Tz;
use serde::{Deserialize, Serialize};

use crate::{
    CollectionSchema, CollectionSchemaId, EnumOptionId, FieldId, FieldType, GenericRecord,
    RecordId,
    error::{DomainError, IssueCode, ValidationIssue},
    query::{
        BucketPeriod, CalendarPolicy, ComputedFieldDefinition, EvaluationContext, Expression,
        FieldReference, NullOrder, OptionPositions, SortClause, SortDirection, TypeEnvironment,
        TypedValue, ValueType, ViewId, WeekStart, bucket_value, compare_records,
        evaluate_expression, infer_expression,
    },
};

pub const VIEW_VERSION: u32 = 1;
/// The reserved identifier of the implicit All view. Never a UUID.
pub const ALL_VIEW_ID: &str = "all";
pub const MAX_VIEW_SORT_CLAUSES: usize = 3;
pub const MAX_VIEW_NAME_LENGTH: usize = 40;

/// The calendar period of a Date or DateTime grouping.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupPeriod {
    Day,
    Week,
    Month,
}

/// Sections the view's records by one single Choice, Boolean, Date or DateTime source field.
/// Dates carry a period; any other field carries none.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ViewGrouping {
    pub field: FieldId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub period: Option<GroupPeriod>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ViewBody {
    pub filter: Option<Expression>,
    pub sorting: Vec<SortClause>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grouping: Option<ViewGrouping>,
}

impl ViewBody {
    /// The implicit All view: no filter, newest first by record creation time.
    #[must_use]
    pub fn all() -> Self {
        Self {
            filter: None,
            sorting: vec![created_desc()],
            grouping: None,
        }
    }

    /// Every sort clause keeps empty values last.
    #[must_use]
    pub fn normalized(mut self) -> Self {
        for clause in &mut self.sorting {
            clause.null_order = NullOrder::Last;
        }
        self
    }
}

fn created_desc() -> SortClause {
    SortClause {
        expression: Expression::RecordCreatedAt,
        direction: SortDirection::Descending,
        null_order: NullOrder::Last,
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct VersionedViewBody {
    pub version: u32,
    pub body: serde_json::Value,
}

impl VersionedViewBody {
    #[must_use]
    pub fn new(body: &ViewBody) -> Self {
        Self {
            version: VIEW_VERSION,
            body: serde_json::to_value(body).expect("ViewBody is serializable"),
        }
    }

    pub fn body(&self) -> Result<ViewBody, String> {
        if self.version != VIEW_VERSION {
            return Err(format!("unsupported view version {}", self.version));
        }
        serde_json::from_value(self.body.clone()).map_err(|error| error.to_string())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ViewDefinition {
    pub id: ViewId,
    pub collection_id: CollectionSchemaId,
    pub name: String,
    pub body: VersionedViewBody,
    pub order: i64,
    pub deleted: bool,
}

/// How a body fares against the current schema.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewHealth {
    /// Set when the filter no longer validates or the version is unsupported.
    pub broken: Option<String>,
    /// The stored sort minus clauses that no longer resolve; created desc when none is left.
    pub effective_sort: Vec<SortClause>,
}

/// The value shared by the records of one group.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum GroupKey {
    /// A single-choice option, removed options included.
    Option(EnumOptionId),
    Boolean(bool),
    /// The first calendar day of a Day, Week or Month bucket, in days since 1970-01-01, in the
    /// zone the execution used.
    Date(i64),
    /// Records with no value.
    Empty,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewGroup {
    pub key: GroupKey,
    /// The option label for an option group (its last label when removed).
    pub label_hint: Option<String>,
    pub count: u32,
    /// The group's slice of `ViewResult::ids`.
    pub start: u32,
    pub len: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewResult {
    pub ids: Vec<RecordId>,
    pub count: u32,
    /// Empty unless the body groups; the groups' slices cover `ids` in order.
    pub groups: Vec<ViewGroup>,
    /// The IANA zone date grouping used; record dates should be shown in it.
    pub zone: String,
}

/// One entry of a collection's view listing. `id` is `None` for All.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewListing {
    pub id: Option<ViewId>,
    pub name: String,
    pub body: Option<ViewBody>,
    pub order: i64,
    pub effective_sort: Vec<SortClause>,
    pub broken: Option<String>,
    pub count: Option<u32>,
}

pub fn validate_view_name(name: &str) -> Result<(), ValidationIssue> {
    if (1..=MAX_VIEW_NAME_LENGTH).contains(&name.trim().chars().count()) {
        Ok(())
    } else {
        Err(ValidationIssue::new(
            IssueCode::Length,
            format!("Use 1 to {MAX_VIEW_NAME_LENGTH} characters."),
        )
        .on("name"))
    }
}

/// Structural checks of a body; every issue is reported at once.
#[must_use]
pub fn view_body_issues(
    body: &ViewBody,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> Vec<ValidationIssue> {
    let mut issues = Vec::new();
    if let Some(grouping) = &body.grouping
        && let Some(message) = grouping_problem(grouping, schema)
    {
        issues.push(ValidationIssue::new(IssueCode::ViewGrouping, message).on("grouping"));
    }
    if let Some(filter) = &body.filter
        && let Some(message) = filter_problem(filter, schema, computed)
    {
        issues.push(ValidationIssue::new(IssueCode::ViewFilterType, message).on("filter"));
    }
    if body.sorting.len() > MAX_VIEW_SORT_CLAUSES {
        issues.push(
            ValidationIssue::new(
                IssueCode::ViewSortLimit,
                format!("Sort by at most {MAX_VIEW_SORT_CLAUSES} keys."),
            )
            .on("sorting"),
        );
    }
    for (index, clause) in body.sorting.iter().enumerate() {
        if !sort_key_resolves(&clause.expression, schema, computed) {
            issues.push(
                ValidationIssue::new(IssueCode::ViewSortKey, "This field can't be sorted by.")
                    .on(format!("sorting[{index}]")),
            );
        }
    }
    issues
}

pub fn validate_view(
    name: &str,
    body: &ViewBody,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> Result<(), DomainError> {
    let mut issues = Vec::new();
    if let Err(issue) = validate_view_name(name) {
        issues.push(issue);
    }
    issues.extend(view_body_issues(body, schema, computed));
    if issues.is_empty() {
        Ok(())
    } else {
        Err(DomainError::InvalidMany(issues))
    }
}

/// Why a filter does not hold against the schema, naming the field at fault when known.
fn filter_problem(
    filter: &Expression,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> Option<String> {
    let mut references = Vec::new();
    let mut options = Vec::new();
    collect(filter, &mut references, &mut options);
    for reference in &references {
        let missing = match reference {
            FieldReference::Source(id) => schema
                .fields
                .iter()
                .find(|field| field.id == *id)
                .filter(|field| field.deleted)
                .map(|field| field.name.clone())
                .or_else(|| {
                    (!schema.fields.iter().any(|field| field.id == *id)).then(|| id.to_string())
                }),
            FieldReference::Computed(id) => computed
                .iter()
                .find(|field| field.id == *id)
                .filter(|field| field.deleted)
                .map(|field| field.name.clone())
                .or_else(|| {
                    (!computed.iter().any(|field| field.id == *id)).then(|| id.to_string())
                }),
        };
        if let Some(name) = missing {
            return Some(format!("field \u{201c}{name}\u{201d} was deleted"));
        }
    }
    for option in &options {
        let found = schema
            .fields
            .iter()
            .filter(|field| !field.deleted)
            .find_map(|field| {
                field
                    .enum_options
                    .iter()
                    .find(|item| item.id == *option)
                    .map(|item| (field, item))
            });
        match found {
            Some((_, item)) if !item.deleted => {}
            Some((field, _)) => {
                return Some(format!(
                    "an option of \u{201c}{}\u{201d} was deleted",
                    field.name
                ));
            }
            None => return Some("an option was deleted".into()),
        }
    }
    let env = TypeEnvironment { schema, computed };
    match infer_expression(filter, &env, true) {
        Ok(inferred) if inferred.value_type == ValueType::Boolean => None,
        Ok(_) => Some("the filter must be true or false".into()),
        Err(error) => {
            let name = references.iter().find_map(|reference| match reference {
                FieldReference::Source(id) => schema
                    .fields
                    .iter()
                    .find(|field| field.id == *id)
                    .map(|field| field.name.clone()),
                FieldReference::Computed(id) => computed
                    .iter()
                    .find(|field| field.id == *id)
                    .map(|field| field.name.clone()),
            });
            Some(match name {
                Some(name) => format!("field \u{201c}{name}\u{201d} changed: {}", error.message),
                None => error.to_string(),
            })
        }
    }
}

fn collect(
    expression: &Expression,
    references: &mut Vec<FieldReference>,
    options: &mut Vec<crate::EnumOptionId>,
) {
    match expression {
        Expression::Constant { value } => match value {
            TypedValue::Enum(id) => options.push(*id),
            TypedValue::EnumOptionSet { options: ids, .. } => options.extend(ids.iter().copied()),
            _ => {}
        },
        Expression::Field { field } => references.push(field.clone()),
        Expression::Arithmetic { left, right, .. }
        | Expression::Divide { left, right, .. }
        | Expression::Compare { left, right, .. }
        | Expression::SetCompare { left, right, .. }
        | Expression::Boolean { left, right, .. } => {
            collect(left, references, options);
            collect(right, references, options);
        }
        Expression::Not { expression }
        | Expression::IsNull { expression }
        | Expression::IsNotNull { expression }
        | Expression::Abs { expression } => collect(expression, references, options),
        Expression::StartOfCurrent { .. } | Expression::RecordCreatedAt => {}
    }
}

/// Why a grouping does not hold against the schema, naming the field when it still exists.
fn grouping_problem(grouping: &ViewGrouping, schema: &CollectionSchema) -> Option<String> {
    let Some(field) = schema
        .fields
        .iter()
        .find(|field| field.id == grouping.field)
    else {
        return Some(format!(
            "field \u{201c}{}\u{201d} was deleted",
            grouping.field
        ));
    };
    if field.deleted {
        return Some(format!("field \u{201c}{}\u{201d} was deleted", field.name));
    }
    let fits = match field.field_type {
        FieldType::Enum | FieldType::Boolean => grouping.period.is_none(),
        FieldType::Date | FieldType::DateTime => grouping.period.is_some(),
        _ => false,
    };
    (!fits).then(|| format!("field \u{201c}{}\u{201d} can't be grouped by", field.name))
}

/// Record creation time, or an active orderable field that is not a multi-option Choices field.
fn sort_key_resolves(
    expression: &Expression,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> bool {
    match expression {
        Expression::RecordCreatedAt => true,
        Expression::Field { .. } => {
            infer_expression(expression, &TypeEnvironment { schema, computed }, true).is_ok_and(
                |inferred| !matches!(inferred.value_type, ValueType::Null | ValueType::EnumSet),
            )
        }
        _ => false,
    }
}

#[must_use]
pub fn view_health(
    body: &VersionedViewBody,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> ViewHealth {
    match body.body() {
        Ok(body) => body_health(&body, schema, computed),
        Err(message) => ViewHealth {
            broken: Some(message),
            effective_sort: vec![created_desc()],
        },
    }
}

#[must_use]
pub fn body_health(
    body: &ViewBody,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> ViewHealth {
    let broken = body
        .filter
        .as_ref()
        .and_then(|filter| filter_problem(filter, schema, computed))
        .or_else(|| {
            body.grouping
                .as_ref()
                .and_then(|grouping| grouping_problem(grouping, schema))
        });
    let mut effective_sort: Vec<SortClause> = body
        .sorting
        .iter()
        .filter(|clause| sort_key_resolves(&clause.expression, schema, computed))
        .take(MAX_VIEW_SORT_CLAUSES)
        .cloned()
        .map(|mut clause| {
            clause.null_order = NullOrder::Last;
            clause
        })
        .collect();
    if effective_sort.is_empty() {
        effective_sort.push(created_desc());
    }
    ViewHealth {
        broken,
        effective_sort,
    }
}

/// The device's IANA zone, or UTC when it can't be determined or isn't known to the zone
/// database. Weeks start on Monday.
#[must_use]
pub fn device_calendar() -> CalendarPolicy {
    calendar_for(iana_time_zone::get_timezone().ok())
}

#[must_use]
pub fn calendar_for(zone: Option<String>) -> CalendarPolicy {
    CalendarPolicy {
        timezone: zone
            .filter(|zone| zone.parse::<Tz>().is_ok())
            .unwrap_or_else(|| "UTC".into()),
        week_start: WeekStart::Monday,
    }
}

/// The active records of the collection that the body keeps, in view order, grouped in the
/// device time zone. A record whose filter can't be evaluated is left out; a sort failure falls
/// back to record id order.
pub fn execute_view(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    records: &[GenericRecord],
    body: &ViewBody,
    now_utc_ms: i64,
) -> Result<ViewResult, DomainError> {
    execute_view_in(
        schema,
        computed,
        records,
        body,
        now_utc_ms,
        &device_calendar(),
    )
}

/// [`execute_view`] with date grouping in `zone`.
pub fn execute_view_in(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    records: &[GenericRecord],
    body: &ViewBody,
    now_utc_ms: i64,
    zone: &CalendarPolicy,
) -> Result<ViewResult, DomainError> {
    let health = body_health(body, schema, computed);
    if let Some(diagnostic) = health.broken {
        return Err(DomainError::BrokenView { diagnostic });
    }
    let calendar = CalendarPolicy::default();
    let context = EvaluationContext {
        schema,
        computed_definitions: computed,
        now_utc_ms,
        calendar: &calendar,
    };
    let mut selected: Vec<&GenericRecord> = records
        .iter()
        .filter(|record| !record.deleted && record.collection_id == schema.id)
        .filter(|record| keeps(body.filter.as_ref(), record, &context))
        .collect();
    let positions = OptionPositions::new(schema);
    selected.sort_by(|a, b| {
        compare_records(a, b, &health.effective_sort, &context, &positions)
            .unwrap_or_else(|_| a.id.cmp(&b.id))
    });
    let count = u32::try_from(selected.len()).unwrap_or(u32::MAX);
    let Some(grouping) = &body.grouping else {
        return Ok(ViewResult {
            ids: selected.into_iter().map(|record| record.id).collect(),
            count,
            groups: Vec::new(),
            zone: zone.timezone.clone(),
        });
    };
    let (ids, groups) = partition(&selected, grouping, schema, &health.effective_sort, zone);
    Ok(ViewResult {
        ids,
        count,
        groups,
        zone: zone.timezone.clone(),
    })
}

/// Splits the view-ordered records into groups without reordering inside a group, then orders
/// the groups: options by stored position, Yes before No, dates newest first, each flipped by a
/// first sort clause on the grouping field going the other way; the no-value group last.
fn partition(
    selected: &[&GenericRecord],
    grouping: &ViewGrouping,
    schema: &CollectionSchema,
    sorting: &[SortClause],
    zone: &CalendarPolicy,
) -> (Vec<RecordId>, Vec<ViewGroup>) {
    let field = schema
        .fields
        .iter()
        .find(|field| field.id == grouping.field)
        .expect("a healthy grouping references a schema field");
    let mut keys: Vec<GroupKey> = Vec::new();
    let mut members: HashMap<GroupKey, Vec<RecordId>> = HashMap::new();
    for record in selected {
        let key = group_key(record.values.get(&field.id), grouping.period, zone);
        if !members.contains_key(&key) {
            keys.push(key.clone());
        }
        members.entry(key).or_default().push(record.id);
    }
    let first = sorting.first().filter(|clause| {
        matches!(&clause.expression, Expression::Field { field: FieldReference::Source(id) } if *id == field.id)
    });
    let ascending = first.map(|clause| clause.direction == SortDirection::Ascending);
    let position = |id: &EnumOptionId| {
        field
            .enum_options
            .iter()
            .find(|option| option.id == *id)
            .map_or(i64::MAX, |option| option.order)
    };
    keys.sort_by(|a, b| {
        use std::cmp::Ordering;
        match (a, b) {
            (GroupKey::Empty, GroupKey::Empty) => Ordering::Equal,
            (GroupKey::Empty, _) => Ordering::Greater,
            (_, GroupKey::Empty) => Ordering::Less,
            (GroupKey::Option(a), GroupKey::Option(b)) => {
                let order = position(a).cmp(&position(b)).then_with(|| a.cmp(b));
                if ascending == Some(false) {
                    order.reverse()
                } else {
                    order
                }
            }
            (GroupKey::Boolean(a), GroupKey::Boolean(b)) => {
                let order = b.cmp(a);
                if ascending == Some(true) {
                    order.reverse()
                } else {
                    order
                }
            }
            (GroupKey::Date(a), GroupKey::Date(b)) => {
                if ascending == Some(true) {
                    a.cmp(b)
                } else {
                    b.cmp(a)
                }
            }
            _ => Ordering::Equal,
        }
    });
    let mut ids = Vec::with_capacity(selected.len());
    let groups = keys
        .into_iter()
        .map(|key| {
            let slice = members.remove(&key).unwrap_or_default();
            let start = u32::try_from(ids.len()).unwrap_or(u32::MAX);
            let len = u32::try_from(slice.len()).unwrap_or(u32::MAX);
            ids.extend(slice);
            let label_hint = match &key {
                GroupKey::Option(id) => field
                    .enum_options
                    .iter()
                    .find(|option| option.id == *id)
                    .map(|option| option.label.clone()),
                _ => None,
            };
            ViewGroup {
                key,
                label_hint,
                count: len,
                start,
                len,
            }
        })
        .collect();
    (ids, groups)
}

/// The group of one stored value. DateTime values are first read as a calendar day in `zone`;
/// Date values are bucketed as stored.
fn group_key(
    value: Option<&crate::FieldValue>,
    period: Option<GroupPeriod>,
    zone: &CalendarPolicy,
) -> GroupKey {
    use crate::FieldValue;
    let day = match value {
        Some(FieldValue::Enum(id)) => return GroupKey::Option(*id),
        Some(FieldValue::Boolean(value)) => return GroupKey::Boolean(*value),
        Some(FieldValue::Date(days)) => *days,
        Some(FieldValue::DateTime(ms)) => match local_day(*ms, zone) {
            Some(day) => day,
            None => return GroupKey::Empty,
        },
        _ => return GroupKey::Empty,
    };
    let period = match period {
        Some(GroupPeriod::Day) | None => BucketPeriod::Day,
        Some(GroupPeriod::Week) => BucketPeriod::Week,
        Some(GroupPeriod::Month) => BucketPeriod::Month,
    };
    match bucket_value(&TypedValue::Date(day), period, zone) {
        Ok(TypedValue::Date(start)) => GroupKey::Date(start),
        _ => GroupKey::Empty,
    }
}

fn local_day(ms: i64, zone: &CalendarPolicy) -> Option<i64> {
    let zone: Tz = zone.timezone.parse().ok()?;
    let local = chrono::DateTime::from_timestamp_millis(ms)?
        .with_timezone(&zone)
        .date_naive();
    let epoch = chrono::NaiveDate::from_ymd_opt(1970, 1, 1)?;
    Some(local.signed_duration_since(epoch).num_days())
}

/// The views of `schema` that can travel to another collection or document: the active ones by
/// `(order, id)`, each holding its effective body (sort clauses that no longer resolve removed).
/// Broken views are left out and their names returned.
#[must_use]
pub fn portable_views(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    views: &[ViewDefinition],
) -> (Vec<ViewDefinition>, Vec<String>) {
    let computed: Vec<ComputedFieldDefinition> = computed
        .iter()
        .filter(|item| item.collection_id == schema.id && !item.deleted)
        .cloned()
        .collect();
    let mut active: Vec<&ViewDefinition> = views
        .iter()
        .filter(|view| !view.deleted && view.collection_id == schema.id)
        .collect();
    active.sort_by_key(|view| (view.order, view.id));
    let mut kept = Vec::new();
    let mut omitted = Vec::new();
    for view in active {
        let health = view_health(&view.body, schema, &computed);
        match (health.broken, view.body.body()) {
            (None, Ok(body)) => kept.push(ViewDefinition {
                body: VersionedViewBody::new(&ViewBody {
                    sorting: health.effective_sort,
                    ..body
                }),
                ..view.clone()
            }),
            _ => omitted.push(view.name.clone()),
        }
    }
    (kept, omitted)
}

fn keeps(
    filter: Option<&Expression>,
    record: &GenericRecord,
    context: &EvaluationContext<'_>,
) -> bool {
    filter.is_none_or(|filter| {
        matches!(
            evaluate_expression(filter, record, context),
            Ok(TypedValue::Boolean(true))
        )
    })
}

/// All first, then the active saved views by `(order, id)`, each with its health and count.
#[must_use]
pub fn list_views(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    records: &[GenericRecord],
    views: &[ViewDefinition],
    now_utc_ms: i64,
) -> Vec<ViewListing> {
    let calendar = CalendarPolicy::default();
    let context = EvaluationContext {
        schema,
        computed_definitions: computed,
        now_utc_ms,
        calendar: &calendar,
    };
    let active: Vec<&GenericRecord> = records
        .iter()
        .filter(|record| !record.deleted && record.collection_id == schema.id)
        .collect();
    let all = ViewBody::all();
    let mut listing = vec![ViewListing {
        id: None,
        name: "All".into(),
        effective_sort: all.sorting.clone(),
        body: Some(all),
        order: i64::MIN,
        broken: None,
        count: Some(u32::try_from(active.len()).unwrap_or(u32::MAX)),
    }];
    let mut saved: Vec<&ViewDefinition> = views
        .iter()
        .filter(|view| !view.deleted && view.collection_id == schema.id)
        .collect();
    saved.sort_by_key(|view| (view.order, view.id));
    for view in saved {
        let health = view_health(&view.body, schema, computed);
        let body = view.body.body().ok();
        let count = match (&health.broken, &body) {
            (None, Some(body)) => Some(
                u32::try_from(
                    active
                        .iter()
                        .filter(|record| keeps(body.filter.as_ref(), record, &context))
                        .count(),
                )
                .unwrap_or(u32::MAX),
            ),
            _ => None,
        };
        listing.push(ViewListing {
            id: Some(view.id),
            name: view.name.clone(),
            body,
            order: view.order,
            effective_sort: health.effective_sort,
            broken: health.broken,
            count,
        });
    }
    listing
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::{
        EnumOption, EnumOptionId, FieldDefinition, FieldId, FieldType, FieldValue,
        query::ComparisonOperator,
        schema::{DisplayMetadata, ValidationMetadata},
    };

    fn field(name: &str, field_type: FieldType, options: Vec<EnumOption>) -> FieldDefinition {
        FieldDefinition {
            allow_options_from_records: false,
            id: FieldId::new(),
            name: name.into(),
            field_type,
            required: false,
            default: None,
            default_relative_days: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order: 0,
            deleted: false,
            enum_options: options,
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

    struct Fixture {
        schema: CollectionSchema,
        records: Vec<GenericRecord>,
    }

    impl Fixture {
        fn kind(&self) -> &FieldDefinition {
            &self.schema.fields[0]
        }
        fn level(&self) -> &FieldDefinition {
            &self.schema.fields[1]
        }
        fn tags(&self) -> &FieldDefinition {
            &self.schema.fields[2]
        }
        fn headache(&self) -> EnumOptionId {
            self.kind().enum_options[0].id
        }
        fn push(&mut self, kind: Option<EnumOptionId>, level: Option<i64>) -> RecordId {
            let mut values = BTreeMap::new();
            if let Some(kind) = kind {
                values.insert(self.kind().id, FieldValue::Enum(kind));
            }
            if let Some(level) = level {
                values.insert(self.level().id, FieldValue::Integer(level));
            }
            let id = RecordId::new();
            self.records.push(GenericRecord {
                id,
                collection_id: self.schema.id,
                values,
                stamps: BTreeMap::new(),
                deleted: false,
            });
            id
        }
    }

    fn fixture() -> Fixture {
        let mut kind = field(
            "type",
            FieldType::Enum,
            vec![option("headache", 0), option("stomach", 1)],
        );
        kind.order = 0;
        let mut level = field("level", FieldType::Integer, vec![]);
        level.order = 1;
        let mut tags = field("tags", FieldType::EnumSet, vec![option("food", 0)]);
        tags.order = 2;
        Fixture {
            schema: CollectionSchema {
                id: CollectionSchemaId::new(),
                name: "pains".into(),
                description: String::new(),
                fields: vec![kind, level, tags],
                deleted: false,
            },
            records: Vec::new(),
        }
    }

    fn is_kind(fixture: &Fixture, option: EnumOptionId) -> Expression {
        Expression::Compare {
            operator: ComparisonOperator::Equal,
            left: Box::new(Expression::Field {
                field: FieldReference::Source(fixture.kind().id),
            }),
            right: Box::new(Expression::Constant {
                value: TypedValue::Enum(option),
            }),
        }
    }

    fn by(field: &FieldDefinition, direction: SortDirection) -> SortClause {
        SortClause {
            expression: Expression::Field {
                field: FieldReference::Source(field.id),
            },
            direction,
            null_order: NullOrder::Last,
        }
    }

    fn run(fixture: &Fixture, body: &ViewBody) -> Result<ViewResult, DomainError> {
        execute_view(&fixture.schema, &[], &fixture.records, body, 0)
    }

    fn codes(error: DomainError) -> Vec<&'static str> {
        match error {
            DomainError::InvalidMany(issues) => issues.iter().map(|i| i.code.as_str()).collect(),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn filter_sort_and_id_tie_break() {
        let mut fixture = fixture();
        let headache = fixture.headache();
        let stomach = fixture.kind().enum_options[1].id;
        let a = fixture.push(Some(headache), Some(5));
        let b = fixture.push(Some(headache), Some(7));
        let c = fixture.push(Some(headache), Some(5));
        fixture.push(Some(stomach), Some(9));
        let body = ViewBody {
            filter: Some(is_kind(&fixture, headache)),
            sorting: vec![by(fixture.level(), SortDirection::Descending)],
            grouping: None,
        };
        let result = run(&fixture, &body).unwrap();
        assert_eq!(result.ids, vec![b, a, c]);
        assert_eq!(result.count, 3);
        // All: newest first by creation time.
        let all = run(&fixture, &ViewBody::all()).unwrap();
        assert_eq!(all.count, 4);
    }

    #[test]
    fn empty_values_sort_last_both_ways() {
        let mut fixture = fixture();
        let empty_a = fixture.push(None, None);
        let low = fixture.push(None, Some(1));
        let empty_b = fixture.push(None, None);
        let high = fixture.push(None, Some(9));
        for (direction, expected) in [
            (SortDirection::Ascending, vec![low, high, empty_a, empty_b]),
            (SortDirection::Descending, vec![high, low, empty_a, empty_b]),
        ] {
            let body = ViewBody {
                filter: None,
                sorting: vec![by(fixture.level(), direction)],
                grouping: None,
            };
            assert_eq!(run(&fixture, &body).unwrap().ids, expected);
        }
    }

    #[test]
    fn deleted_filter_field_breaks_but_deleted_sort_field_degrades() {
        let mut fixture = fixture();
        let headache = fixture.headache();
        fixture.push(Some(headache), Some(1));
        let filtered = ViewBody {
            filter: Some(is_kind(&fixture, headache)),
            sorting: vec![],
            grouping: None,
        };
        let sorted = ViewBody {
            filter: None,
            sorting: vec![by(fixture.level(), SortDirection::Ascending)],
            grouping: None,
        };
        fixture.schema.fields[0].deleted = true;
        fixture.schema.fields[1].deleted = true;
        let health = body_health(&filtered, &fixture.schema, &[]);
        assert!(health.broken.unwrap().contains("type"));
        assert!(matches!(
            run(&fixture, &filtered),
            Err(DomainError::BrokenView { .. })
        ));
        let health = body_health(&sorted, &fixture.schema, &[]);
        assert!(health.broken.is_none());
        assert_eq!(health.effective_sort, ViewBody::all().sorting);
        assert_eq!(run(&fixture, &sorted).unwrap().count, 1);
    }

    #[test]
    fn deleted_option_and_unsupported_version_break() {
        let mut fixture = fixture();
        let headache = fixture.headache();
        let body = ViewBody {
            filter: Some(is_kind(&fixture, headache)),
            sorting: vec![],
            grouping: None,
        };
        fixture.schema.fields[0].enum_options[0].deleted = true;
        assert!(body_health(&body, &fixture.schema, &[]).broken.is_some());
        let future = VersionedViewBody {
            version: 99,
            body: serde_json::Value::Null,
        };
        assert!(view_health(&future, &fixture.schema, &[]).broken.is_some());
    }

    #[test]
    fn listing_counts_and_reports_broken_views() {
        let mut fixture = fixture();
        let headache = fixture.headache();
        fixture.push(Some(headache), None);
        fixture.push(Some(headache), None);
        fixture.push(None, None);
        let view = |name: &str, body: &ViewBody, order| ViewDefinition {
            id: ViewId::new(),
            collection_id: fixture.schema.id,
            name: name.into(),
            body: VersionedViewBody::new(body),
            order,
            deleted: false,
        };
        let headaches = view(
            "Headaches",
            &ViewBody {
                filter: Some(is_kind(&fixture, headache)),
                sorting: vec![],
                grouping: None,
            },
            0,
        );
        let mut broken = view("Broken", &ViewBody::all(), 1);
        broken.body = VersionedViewBody {
            version: 2,
            body: serde_json::Value::Null,
        };
        let mut gone = view("Gone", &ViewBody::all(), 2);
        gone.deleted = true;
        let listing = list_views(
            &fixture.schema,
            &[],
            &fixture.records,
            &[broken.clone(), gone, headaches.clone()],
            0,
        );
        let summary: Vec<_> = listing
            .iter()
            .map(|item| (item.id, item.count, item.broken.is_some()))
            .collect();
        assert_eq!(
            summary,
            vec![
                (None, Some(3), false),
                (Some(headaches.id), Some(2), false),
                (Some(broken.id), None, true),
            ]
        );
    }

    #[test]
    fn validation_codes() {
        let fixture = fixture();
        let ok = ViewBody::all();
        let check = |name: &str, body: &ViewBody| validate_view(name, body, &fixture.schema, &[]);
        assert!(check("Headaches", &ok).is_ok());
        assert_eq!(codes(check("  ", &ok).unwrap_err()), ["length"]);
        assert_eq!(codes(check(&"x".repeat(41), &ok).unwrap_err()), ["length"]);
        assert!(check(&"x".repeat(40), &ok).is_ok());
        let tags = ViewBody {
            filter: None,
            sorting: vec![by(fixture.tags(), SortDirection::Ascending)],
            grouping: None,
        };
        assert_eq!(codes(check("Tags", &tags).unwrap_err()), ["view_sort_key"]);
        let four = ViewBody {
            filter: None,
            sorting: vec![by(fixture.level(), SortDirection::Ascending); 4],
            grouping: None,
        };
        assert_eq!(
            codes(check("Four", &four).unwrap_err()),
            ["view_sort_limit"]
        );
        let not_boolean = ViewBody {
            filter: Some(Expression::Field {
                field: FieldReference::Source(fixture.level().id),
            }),
            sorting: vec![],
            grouping: None,
        };
        assert_eq!(
            codes(check("Level", &not_boolean).unwrap_err()),
            ["view_filter_type"]
        );
        let group = |field: FieldId, period| ViewBody {
            grouping: Some(ViewGrouping { field, period }),
            ..ViewBody::all()
        };
        assert!(check("Type", &group(fixture.kind().id, None)).is_ok());
        for bad in [
            group(fixture.tags().id, None),
            group(fixture.level().id, None),
            group(fixture.kind().id, Some(GroupPeriod::Day)),
            group(FieldId::new(), None),
        ] {
            assert_eq!(
                codes(check("Grouped", &bad).unwrap_err()),
                ["view_grouping"]
            );
        }
        // Names are not checked for uniqueness or the localized All name.
        assert!(check("All", &ok).is_ok());
    }

    fn add_field(fixture: &mut Fixture, name: &str, field_type: FieldType) -> FieldId {
        let mut item = field(name, field_type, vec![]);
        item.order = i64::try_from(fixture.schema.fields.len()).unwrap();
        let id = item.id;
        fixture.schema.fields.push(item);
        id
    }

    fn push_value(fixture: &mut Fixture, field: FieldId, value: Option<FieldValue>) -> RecordId {
        let id = fixture.push(None, None);
        if let Some(value) = value {
            fixture
                .records
                .last_mut()
                .unwrap()
                .values
                .insert(field, value);
        }
        id
    }

    fn utc_ms(text: &str) -> i64 {
        chrono::DateTime::parse_from_rfc3339(text)
            .unwrap()
            .timestamp_millis()
    }

    fn day(y: i32, m: u32, d: u32) -> i64 {
        chrono::NaiveDate::from_ymd_opt(y, m, d)
            .unwrap()
            .signed_duration_since(chrono::NaiveDate::from_ymd_opt(1970, 1, 1).unwrap())
            .num_days()
    }

    fn grouped(field: FieldId, period: Option<GroupPeriod>, sorting: Vec<SortClause>) -> ViewBody {
        ViewBody {
            filter: None,
            sorting,
            grouping: Some(ViewGrouping { field, period }),
        }
    }

    fn sort_on(field: FieldId, direction: SortDirection) -> SortClause {
        SortClause {
            expression: Expression::Field {
                field: FieldReference::Source(field),
            },
            direction,
            null_order: NullOrder::Last,
        }
    }

    fn run_in(fixture: &Fixture, body: &ViewBody, zone: &str) -> ViewResult {
        execute_view_in(
            &fixture.schema,
            &[],
            &fixture.records,
            body,
            0,
            &calendar_for(Some(zone.into())),
        )
        .unwrap()
    }

    fn summary(result: &ViewResult) -> Vec<(GroupKey, Vec<RecordId>)> {
        result
            .groups
            .iter()
            .map(|group| {
                let start = group.start as usize;
                (
                    group.key.clone(),
                    result.ids[start..start + group.len as usize].to_vec(),
                )
            })
            .collect()
    }

    #[test]
    fn month_grouping_orders_groups_and_keeps_view_order_inside() {
        let mut fixture = fixture();
        let start = add_field(&mut fixture, "start at", FieldType::DateTime);
        let at = |text: &str| Some(FieldValue::DateTime(utc_ms(text)));
        let sep_a = push_value(&mut fixture, start, at("2026-09-03T10:00:00Z"));
        let oct_a = push_value(&mut fixture, start, at("2026-10-02T10:00:00Z"));
        let sep_b = push_value(&mut fixture, start, at("2026-09-20T10:00:00Z"));
        let oct_b = push_value(&mut fixture, start, at("2026-10-09T10:00:00Z"));
        let none = push_value(&mut fixture, start, None);
        let body = grouped(
            start,
            Some(GroupPeriod::Month),
            vec![sort_on(start, SortDirection::Descending)],
        );
        let result = run_in(&fixture, &body, "UTC");
        assert_eq!(result.count, 5);
        assert_eq!(
            summary(&result),
            vec![
                (GroupKey::Date(day(2026, 10, 1)), vec![oct_b, oct_a]),
                (GroupKey::Date(day(2026, 9, 1)), vec![sep_b, sep_a]),
                (GroupKey::Empty, vec![none]),
            ]
        );
        // Ascending on the grouping field: oldest bucket first, empty still last.
        let body = grouped(
            start,
            Some(GroupPeriod::Month),
            vec![sort_on(start, SortDirection::Ascending)],
        );
        assert_eq!(
            summary(&run_in(&fixture, &body, "UTC")),
            vec![
                (GroupKey::Date(day(2026, 9, 1)), vec![sep_a, sep_b]),
                (GroupKey::Date(day(2026, 10, 1)), vec![oct_a, oct_b]),
                (GroupKey::Empty, vec![none]),
            ]
        );
    }

    #[test]
    fn choice_grouping_follows_stored_option_order_including_removed() {
        let mut fixture = fixture();
        fixture.schema.fields[0]
            .enum_options
            .push(option("migraine", 2));
        let headache = fixture.headache();
        let stomach = fixture.kind().enum_options[1].id;
        let migraine = fixture.kind().enum_options[2].id;
        let m = fixture.push(Some(migraine), None);
        let n1 = fixture.push(None, None);
        let s = fixture.push(Some(stomach), None);
        let h = fixture.push(Some(headache), None);
        let n2 = fixture.push(None, None);
        fixture.schema.fields[0].enum_options[1].deleted = true;
        let kind = fixture.kind().id;
        let body = grouped(kind, None, vec![]);
        let result = run_in(&fixture, &body, "UTC");
        let keys: Vec<_> = summary(&result).into_iter().map(|(key, _)| key).collect();
        assert_eq!(
            keys,
            vec![
                GroupKey::Option(headache),
                GroupKey::Option(stomach),
                GroupKey::Option(migraine),
                GroupKey::Empty,
            ]
        );
        assert_eq!(result.groups[1].label_hint.as_deref(), Some("stomach"));
        assert_eq!(result.groups[3].len, 2);
        let empty = &result.ids[3..];
        assert!(empty.contains(&n1) && empty.contains(&n2));
        let _ = (m, s, h);
        // The first sort clause on the field descending reverses the options.
        let body = grouped(kind, None, vec![sort_on(kind, SortDirection::Descending)]);
        let keys: Vec<_> = run_in(&fixture, &body, "UTC")
            .groups
            .into_iter()
            .map(|group| group.key)
            .collect();
        assert_eq!(
            keys,
            vec![
                GroupKey::Option(migraine),
                GroupKey::Option(stomach),
                GroupKey::Option(headache),
                GroupKey::Empty,
            ]
        );
    }

    #[test]
    fn boolean_grouping_yes_first_unless_ascending() {
        let mut fixture = fixture();
        let done = add_field(&mut fixture, "done", FieldType::Boolean);
        let no = push_value(&mut fixture, done, Some(FieldValue::Boolean(false)));
        let yes = push_value(&mut fixture, done, Some(FieldValue::Boolean(true)));
        let empty = push_value(&mut fixture, done, None);
        let result = run_in(&fixture, &grouped(done, None, vec![]), "UTC");
        assert_eq!(
            summary(&result),
            vec![
                (GroupKey::Boolean(true), vec![yes]),
                (GroupKey::Boolean(false), vec![no]),
                (GroupKey::Empty, vec![empty]),
            ]
        );
        let body = grouped(done, None, vec![sort_on(done, SortDirection::Ascending)]);
        let keys: Vec<_> = run_in(&fixture, &body, "UTC")
            .groups
            .into_iter()
            .map(|group| group.key)
            .collect();
        assert_eq!(
            keys,
            vec![
                GroupKey::Boolean(false),
                GroupKey::Boolean(true),
                GroupKey::Empty
            ]
        );
    }

    #[test]
    fn day_grouping_uses_the_zone() {
        let mut fixture = fixture();
        let start = add_field(&mut fixture, "start at", FieldType::DateTime);
        push_value(
            &mut fixture,
            start,
            Some(FieldValue::DateTime(utc_ms("2026-10-01T03:30:00Z"))),
        );
        let body = grouped(start, Some(GroupPeriod::Day), vec![]);
        let bogota = run_in(&fixture, &body, "America/Bogota");
        assert_eq!(bogota.groups[0].key, GroupKey::Date(day(2026, 9, 30)));
        assert_eq!(bogota.zone, "America/Bogota");
        let utc = run_in(&fixture, &body, "UTC");
        assert_eq!(utc.groups[0].key, GroupKey::Date(day(2026, 10, 1)));
    }

    #[test]
    fn date_values_are_bucketed_as_stored() {
        let mut fixture = fixture();
        let on = add_field(&mut fixture, "on", FieldType::Date);
        push_value(&mut fixture, on, Some(FieldValue::Date(day(2026, 10, 1))));
        let body = grouped(on, Some(GroupPeriod::Day), vec![]);
        let result = run_in(&fixture, &body, "America/Bogota");
        assert_eq!(result.groups[0].key, GroupKey::Date(day(2026, 10, 1)));
    }

    #[test]
    fn week_grouping_across_daylight_saving_change() {
        let mut fixture = fixture();
        let start = add_field(&mut fixture, "start at", FieldType::DateTime);
        // Saturday 24 October 2026 23:30 CEST and Monday 26 October 2026 00:30 CET.
        let saturday = push_value(
            &mut fixture,
            start,
            Some(FieldValue::DateTime(utc_ms("2026-10-24T21:30:00Z"))),
        );
        let monday = push_value(
            &mut fixture,
            start,
            Some(FieldValue::DateTime(utc_ms("2026-10-25T23:30:00Z"))),
        );
        let body = grouped(start, Some(GroupPeriod::Week), vec![]);
        assert_eq!(
            summary(&run_in(&fixture, &body, "Europe/Madrid")),
            vec![
                (GroupKey::Date(day(2026, 10, 26)), vec![monday]),
                (GroupKey::Date(day(2026, 10, 19)), vec![saturday]),
            ]
        );
    }

    #[test]
    fn unknown_zone_falls_back_to_utc_and_is_reported() {
        assert_eq!(calendar_for(None).timezone, "UTC");
        assert_eq!(calendar_for(Some("Mars/Olympus".into())).timezone, "UTC");
        assert_eq!(calendar_for(None).week_start, WeekStart::Monday);
        let mut fixture = fixture();
        let start = add_field(&mut fixture, "start at", FieldType::DateTime);
        push_value(
            &mut fixture,
            start,
            Some(FieldValue::DateTime(utc_ms("2026-10-01T03:30:00Z"))),
        );
        let body = grouped(start, Some(GroupPeriod::Day), vec![]);
        let result = execute_view_in(
            &fixture.schema,
            &[],
            &fixture.records,
            &body,
            0,
            &calendar_for(None),
        )
        .unwrap();
        assert_eq!(result.zone, "UTC");
        assert_eq!(result.groups[0].key, GroupKey::Date(day(2026, 10, 1)));
    }

    #[test]
    fn grouping_breaks_when_the_field_is_deleted_or_becomes_multi_option() {
        let mut fixture = fixture();
        let body = grouped(fixture.kind().id, None, vec![]);
        assert!(body_health(&body, &fixture.schema, &[]).broken.is_none());
        fixture.schema.fields[0].field_type = FieldType::EnumSet;
        let broken = body_health(&body, &fixture.schema, &[]).broken.unwrap();
        assert!(broken.contains("type"), "{broken}");
        assert!(matches!(
            run(&fixture, &body),
            Err(DomainError::BrokenView { .. })
        ));
        fixture.schema.fields[0].field_type = FieldType::Enum;
        fixture.schema.fields[0].deleted = true;
        let broken = body_health(&body, &fixture.schema, &[]).broken.unwrap();
        assert!(broken.contains("type"), "{broken}");
    }

    #[test]
    fn portable_views_skip_broken_and_trim_degraded_sort() {
        let mut fixture = fixture();
        let start = add_field(&mut fixture, "start at", FieldType::DateTime);
        let headache = fixture.headache();
        let view = |name: &str, body: &ViewBody, order| ViewDefinition {
            id: ViewId::new(),
            collection_id: fixture.schema.id,
            name: name.into(),
            body: VersionedViewBody::new(body),
            order,
            deleted: false,
        };
        let old = view(
            "Old scale",
            &ViewBody {
                filter: Some(is_kind(&fixture, headache)),
                sorting: vec![],
                grouping: None,
            },
            0,
        );
        let degraded = view(
            "Recent",
            &ViewBody {
                filter: None,
                sorting: vec![
                    by(fixture.level(), SortDirection::Descending),
                    sort_on(start, SortDirection::Descending),
                ],
                grouping: None,
            },
            1,
        );
        fixture.schema.fields[0].deleted = true;
        fixture.schema.fields[1].deleted = true;
        let (kept, omitted) = portable_views(&fixture.schema, &[], &[degraded.clone(), old]);
        assert_eq!(omitted, vec!["Old scale".to_string()]);
        assert_eq!(kept.len(), 1);
        assert_eq!(
            kept[0].body.body().unwrap().sorting,
            vec![sort_on(start, SortDirection::Descending)]
        );
    }
}
