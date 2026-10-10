//! Collection views: a named filter plus up to three sort keys, executed by the query engine.

use serde::{Deserialize, Serialize};

use crate::{
    CollectionSchema, CollectionSchemaId, GenericRecord, RecordId,
    error::{DomainError, IssueCode, ValidationIssue},
    query::{
        CalendarPolicy, ComputedFieldDefinition, EvaluationContext, Expression, FieldReference,
        NullOrder, OptionPositions, SortClause, SortDirection, TypeEnvironment, TypedValue,
        ValueType, ViewId, compare_records, evaluate_expression, infer_expression,
    },
};

pub const VIEW_VERSION: u32 = 1;
/// The reserved identifier of the implicit All view. Never a UUID.
pub const ALL_VIEW_ID: &str = "all";
pub const MAX_VIEW_SORT_CLAUSES: usize = 3;
pub const MAX_VIEW_NAME_LENGTH: usize = 40;

/// Reserved for `views-extras`; any grouping is rejected until then.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ViewGrouping(pub serde_json::Value);

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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ViewResult {
    pub ids: Vec<RecordId>,
    pub count: u32,
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
    if body.grouping.is_some() {
        issues.push(
            ValidationIssue::new(IssueCode::ViewGrouping, "Grouping isn't available yet.")
                .on("grouping"),
        );
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
        .and_then(|filter| filter_problem(filter, schema, computed));
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

/// The active records of the collection that the body keeps, in view order. A record whose
/// filter can't be evaluated is left out; a sort failure falls back to record id order.
pub fn execute_view(
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    records: &[GenericRecord],
    body: &ViewBody,
    now_utc_ms: i64,
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
    Ok(ViewResult {
        ids: selected.into_iter().map(|record| record.id).collect(),
        count,
    })
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
        let grouped = ViewBody {
            grouping: Some(ViewGrouping(serde_json::json!({}))),
            ..ViewBody::all()
        };
        assert_eq!(
            codes(check("Grouped", &grouped).unwrap_err()),
            ["view_grouping"]
        );
        // Names are not checked for uniqueness or the localized All name.
        assert!(check("All", &ok).is_ok());
    }
}
