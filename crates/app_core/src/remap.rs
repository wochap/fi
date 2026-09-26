//! Identity remapping for copied collection definitions.
//!
//! Cloning (and later importing) a collection gives every copied entity a fresh UUIDv7 and
//! rewrites every internal reference through one table. A reference whose id is missing from the
//! table is an error, never silently kept: a kept source id would point into another collection.
//! Every `match` below is exhaustive so a new expression variant or query shape fails to compile
//! until its references are handled here.

use std::collections::{BTreeMap, HashMap};

use crate::{
    error::DomainError,
    query::{
        Aggregation, CollectionQuery, ComputedFieldDefinition, ComputedFieldId, Expression,
        FieldReference, Grouping, QueryDefinition, QueryId, QueryShape, SortClause, TypedValue,
        VersionedCollectionQuery, VersionedExpression,
    },
    schema::{
        CollectionSchema, CollectionSchemaId, EnumOption, EnumOptionId, FieldDefinition, FieldId,
    },
    values::FieldValue,
    widgets::{WidgetDefinition, WidgetId},
};

/// Old-to-new identity table for one copied collection. Only active entities have entries.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdRemap {
    /// `(source, target)` collection identities.
    pub collection: (CollectionSchemaId, CollectionSchemaId),
    pub fields: HashMap<FieldId, FieldId>,
    pub options: HashMap<EnumOptionId, EnumOptionId>,
    pub computed: HashMap<ComputedFieldId, ComputedFieldId>,
    pub queries: HashMap<QueryId, QueryId>,
}

/// A fully remapped, not yet validated copy of one collection's structure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClonePlan {
    pub schema: CollectionSchema,
    pub computed_fields: Vec<ComputedFieldDefinition>,
    pub query_definitions: Vec<QueryDefinition>,
    pub widgets: Vec<WidgetDefinition>,
}

impl IdRemap {
    /// Builds a table with a fresh identity for every active field, enum option of an active
    /// field, computed field and query of `source`. Tombstoned entities and definitions owned by
    /// other collections get no entry.
    #[must_use]
    pub fn for_collection(
        source: CollectionSchemaId,
        target: CollectionSchemaId,
        fields: &[FieldDefinition],
        computed: &[ComputedFieldDefinition],
        queries: &[QueryDefinition],
    ) -> Self {
        let active_fields = fields.iter().filter(|field| !field.deleted);
        Self {
            collection: (source, target),
            fields: active_fields
                .clone()
                .map(|field| (field.id, FieldId::new()))
                .collect(),
            options: active_fields
                .flat_map(|field| &field.enum_options)
                .filter(|option| !option.deleted)
                .map(|option| (option.id, EnumOptionId::new()))
                .collect(),
            computed: computed
                .iter()
                .filter(|item| item.collection_id == source && !item.deleted)
                .map(|item| (item.id, ComputedFieldId::new()))
                .collect(),
            queries: queries
                .iter()
                .filter(|item| item.collection_id == source && !item.deleted)
                .map(|item| (item.id, QueryId::new()))
                .collect(),
        }
    }

    pub fn collection_id(&self, id: CollectionSchemaId) -> Result<CollectionSchemaId, DomainError> {
        if id == self.collection.0 {
            Ok(self.collection.1)
        } else {
            Err(dangling("collection", id))
        }
    }
    pub fn field(&self, id: FieldId) -> Result<FieldId, DomainError> {
        lookup(&self.fields, id, "field")
    }
    pub fn option(&self, id: EnumOptionId) -> Result<EnumOptionId, DomainError> {
        lookup(&self.options, id, "enum option")
    }
    pub fn computed(&self, id: ComputedFieldId) -> Result<ComputedFieldId, DomainError> {
        lookup(&self.computed, id, "computed field")
    }
    pub fn query(&self, id: QueryId) -> Result<QueryId, DomainError> {
        lookup(&self.queries, id, "query")
    }
}

/// Copies the active structure of `source` under `target` named `name`: fields, enum options,
/// computed fields, queries and widgets with fresh identities and rewritten references. Records
/// are never part of a plan. Order metadata is copied unchanged.
pub fn clone_plan(
    source: &CollectionSchema,
    target: CollectionSchemaId,
    name: &str,
    computed: &[ComputedFieldDefinition],
    queries: &[QueryDefinition],
    widgets: &[WidgetDefinition],
) -> Result<ClonePlan, DomainError> {
    let remap = IdRemap::for_collection(source.id, target, &source.fields, computed, queries);
    plan_with_remap(source, &remap, name, computed, queries, widgets)
}

/// [`clone_plan`] with a caller-built table, so the caller can reuse it for further references
/// (imported record values).
pub fn plan_with_remap(
    source: &CollectionSchema,
    remap: &IdRemap,
    name: &str,
    computed: &[ComputedFieldDefinition],
    queries: &[QueryDefinition],
    widgets: &[WidgetDefinition],
) -> Result<ClonePlan, DomainError> {
    let target = remap.collection_id(source.id)?;
    let owned_active =
        |collection_id: CollectionSchemaId, deleted: bool| collection_id == source.id && !deleted;
    Ok(ClonePlan {
        schema: CollectionSchema {
            id: target,
            name: name.to_owned(),
            description: source.description.clone(),
            fields: source
                .fields
                .iter()
                .filter(|field| !field.deleted)
                .map(|field| remap_field(field, remap))
                .collect::<Result<_, _>>()?,
            deleted: false,
        },
        computed_fields: computed
            .iter()
            .filter(|item| owned_active(item.collection_id, item.deleted))
            .map(|item| remap_computed(item, remap))
            .collect::<Result<_, _>>()?,
        query_definitions: queries
            .iter()
            .filter(|item| owned_active(item.collection_id, item.deleted))
            .map(|item| remap_query_definition(item, remap))
            .collect::<Result<_, _>>()?,
        widgets: widgets
            .iter()
            .filter(|item| owned_active(item.collection_id, item.deleted))
            .map(|item| remap_widget(item, remap))
            .collect::<Result<_, _>>()?,
    })
}

pub fn remap_expression(
    expression: &Expression,
    remap: &IdRemap,
) -> Result<Expression, DomainError> {
    let boxed = |inner: &Expression| remap_expression(inner, remap).map(Box::new);
    Ok(match expression {
        Expression::Constant { value } => Expression::Constant {
            value: remap_typed_value(value, remap)?,
        },
        Expression::Field { field } => Expression::Field {
            field: remap_reference(field, remap)?,
        },
        Expression::Arithmetic {
            operator,
            left,
            right,
        } => Expression::Arithmetic {
            operator: *operator,
            left: boxed(left)?,
            right: boxed(right)?,
        },
        Expression::Divide {
            left,
            right,
            output_scale,
            rounding,
        } => Expression::Divide {
            left: boxed(left)?,
            right: boxed(right)?,
            output_scale: *output_scale,
            rounding: *rounding,
        },
        Expression::Compare {
            operator,
            left,
            right,
        } => Expression::Compare {
            operator: *operator,
            left: boxed(left)?,
            right: boxed(right)?,
        },
        Expression::Boolean {
            operator,
            left,
            right,
        } => Expression::Boolean {
            operator: *operator,
            left: boxed(left)?,
            right: boxed(right)?,
        },
        Expression::Not { expression } => Expression::Not {
            expression: boxed(expression)?,
        },
        Expression::IsNull { expression } => Expression::IsNull {
            expression: boxed(expression)?,
        },
        Expression::IsNotNull { expression } => Expression::IsNotNull {
            expression: boxed(expression)?,
        },
        Expression::Abs { expression } => Expression::Abs {
            expression: boxed(expression)?,
        },
        Expression::StartOfCurrent { boundary } => Expression::StartOfCurrent {
            boundary: *boundary,
        },
    })
}

fn remap_reference(
    reference: &FieldReference,
    remap: &IdRemap,
) -> Result<FieldReference, DomainError> {
    Ok(match reference {
        FieldReference::Source(id) => FieldReference::Source(remap.field(*id)?),
        FieldReference::Computed(id) => FieldReference::Computed(remap.computed(*id)?),
    })
}

fn remap_typed_value(value: &TypedValue, remap: &IdRemap) -> Result<TypedValue, DomainError> {
    Ok(match value {
        TypedValue::Enum(id) => TypedValue::Enum(remap.option(*id)?),
        TypedValue::Null
        | TypedValue::Text(_)
        | TypedValue::Integer(_)
        | TypedValue::FixedDecimal { .. }
        | TypedValue::Boolean(_)
        | TypedValue::Date(_)
        | TypedValue::DateTime(_)
        | TypedValue::Duration(_) => value.clone(),
    })
}

fn remap_aggregation(
    aggregation: &Aggregation,
    remap: &IdRemap,
) -> Result<Aggregation, DomainError> {
    Ok(match aggregation {
        Aggregation::Count => Aggregation::Count,
        Aggregation::Sum { expression } => Aggregation::Sum {
            expression: remap_expression(expression, remap)?,
        },
        Aggregation::Average {
            expression,
            output_scale,
            rounding,
        } => Aggregation::Average {
            expression: remap_expression(expression, remap)?,
            output_scale: *output_scale,
            rounding: *rounding,
        },
        Aggregation::Min { expression } => Aggregation::Min {
            expression: remap_expression(expression, remap)?,
        },
        Aggregation::Max { expression } => Aggregation::Max {
            expression: remap_expression(expression, remap)?,
        },
    })
}

fn remap_shape(shape: &QueryShape, remap: &IdRemap) -> Result<QueryShape, DomainError> {
    Ok(match shape {
        QueryShape::Scalar { aggregation } => QueryShape::Scalar {
            aggregation: remap_aggregation(aggregation, remap)?,
        },
        QueryShape::Series { x, y } => QueryShape::Series {
            x: remap_expression(x, remap)?,
            y: remap_expression(y, remap)?,
        },
        QueryShape::CategorySeries {
            category,
            aggregation,
        } => QueryShape::CategorySeries {
            category: remap_expression(category, remap)?,
            aggregation: remap_aggregation(aggregation, remap)?,
        },
        QueryShape::RecordSet { fields } => QueryShape::RecordSet {
            fields: fields
                .iter()
                .map(|field| remap_reference(field, remap))
                .collect::<Result<_, _>>()?,
        },
    })
}

pub fn remap_query(
    query: &CollectionQuery,
    remap: &IdRemap,
) -> Result<CollectionQuery, DomainError> {
    let CollectionQuery {
        collection_id,
        filter,
        grouping,
        shape,
        sorting,
        limit,
        calendar,
    } = query;
    Ok(CollectionQuery {
        collection_id: remap.collection_id(*collection_id)?,
        filter: filter
            .as_ref()
            .map(|filter| remap_expression(filter, remap))
            .transpose()?,
        grouping: grouping
            .as_ref()
            .map(|grouping| {
                Ok::<_, DomainError>(Grouping {
                    expression: remap_expression(&grouping.expression, remap)?,
                    period: grouping.period,
                })
            })
            .transpose()?,
        shape: remap_shape(shape, remap)?,
        sorting: sorting
            .iter()
            .map(|sort| {
                Ok(SortClause {
                    expression: remap_expression(&sort.expression, remap)?,
                    direction: sort.direction,
                    null_order: sort.null_order,
                })
            })
            .collect::<Result<_, DomainError>>()?,
        limit: *limit,
        calendar: calendar.clone(),
    })
}

/// Rewrites a field's identity, its active enum options and an enum default. Tombstoned options
/// are dropped because they have no entry in the table.
pub fn remap_field(
    field: &FieldDefinition,
    remap: &IdRemap,
) -> Result<FieldDefinition, DomainError> {
    Ok(FieldDefinition {
        id: remap.field(field.id)?,
        enum_options: field
            .enum_options
            .iter()
            .filter(|option| !option.deleted)
            .map(|option| {
                Ok(EnumOption {
                    id: remap.option(option.id)?,
                    ..option.clone()
                })
            })
            .collect::<Result<_, DomainError>>()?,
        default: match &field.default {
            Some(FieldValue::Enum(id)) => Some(FieldValue::Enum(remap.option(*id)?)),
            other => other.clone(),
        },
        ..field.clone()
    })
}

pub fn remap_computed(
    definition: &ComputedFieldDefinition,
    remap: &IdRemap,
) -> Result<ComputedFieldDefinition, DomainError> {
    let expression = definition
        .expression
        .expression()
        .map_err(|error| invalid("computed_field", error.to_string()))?;
    Ok(ComputedFieldDefinition {
        id: remap.computed(definition.id)?,
        collection_id: remap.collection_id(definition.collection_id)?,
        expression: VersionedExpression::new(remap_expression(&expression, remap)?),
        ..definition.clone()
    })
}

pub fn remap_query_definition(
    definition: &QueryDefinition,
    remap: &IdRemap,
) -> Result<QueryDefinition, DomainError> {
    let query = definition
        .query
        .query()
        .map_err(|error| invalid("query", error.to_string()))?;
    Ok(QueryDefinition {
        id: remap.query(definition.id)?,
        collection_id: remap.collection_id(definition.collection_id)?,
        query: VersionedCollectionQuery::new(remap_query(&query, remap)?),
        ..definition.clone()
    })
}

/// Widgets are never referenced by other definitions, so each copy simply gets a fresh id.
pub fn remap_widget(
    definition: &WidgetDefinition,
    remap: &IdRemap,
) -> Result<WidgetDefinition, DomainError> {
    Ok(WidgetDefinition {
        id: WidgetId::new(),
        collection_id: remap.collection_id(definition.collection_id)?,
        query_id: remap.query(definition.query_id)?,
        ..definition.clone()
    })
}

/// Rewrites a record's value map: every key to its new field id and every enum value to its new
/// option id. A value for a field or option outside the table is an error.
pub fn remap_record_values(
    values: &BTreeMap<FieldId, FieldValue>,
    remap: &IdRemap,
) -> Result<BTreeMap<FieldId, FieldValue>, DomainError> {
    values
        .iter()
        .map(|(field, value)| {
            let value = match value {
                FieldValue::Enum(id) => FieldValue::Enum(remap.option(*id)?),
                FieldValue::Null
                | FieldValue::Text(_)
                | FieldValue::Integer(_)
                | FieldValue::FixedDecimal(_)
                | FieldValue::Boolean(_)
                | FieldValue::Date(_)
                | FieldValue::DateTime(_)
                | FieldValue::Duration(_) => value.clone(),
            };
            Ok((remap.field(*field)?, value))
        })
        .collect()
}

fn lookup<T: Copy + Eq + std::hash::Hash + ToString>(
    table: &HashMap<T, T>,
    id: T,
    kind: &str,
) -> Result<T, DomainError> {
    table.get(&id).copied().ok_or_else(|| dangling(kind, id))
}

fn dangling(kind: &str, id: impl ToString) -> DomainError {
    invalid(
        "dangling_reference",
        format!(
            "references {kind} {} outside the copied collection",
            id.to_string()
        ),
    )
}

fn invalid(field: &'static str, message: impl Into<String>) -> DomainError {
    DomainError::Invalid {
        field,
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        query::{
            ArithmeticOperator, BucketPeriod, CalendarPolicy, ComparisonOperator, NullOrder,
            RoundingPolicy, SortDirection, ValueType,
        },
        schema::{DisplayMetadata, FieldType, ValidationMetadata},
        widgets::{WidgetConfiguration, WidgetLayout, WidgetType},
    };

    struct Fixture {
        schema: CollectionSchema,
        computed: Vec<ComputedFieldDefinition>,
        queries: Vec<QueryDefinition>,
        widgets: Vec<WidgetDefinition>,
    }

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

    fn option(label: &str, order: i64, deleted: bool) -> EnumOption {
        EnumOption {
            id: EnumOptionId::new(),
            label: label.into(),
            order,
            deleted,
        }
    }

    fn source_field(id: FieldId) -> Expression {
        Expression::Field {
            field: FieldReference::Source(id),
        }
    }

    /// A collection touching every reference site: enum default and constant, computed
    /// references, grouping, sorting, every aggregation carrier, record-set fields, and
    /// tombstones of each kind.
    fn fixture() -> Fixture {
        let collection_id = CollectionSchemaId::new();
        let mut kind = field("Kind", FieldType::Enum, 0);
        kind.enum_options = vec![
            option("Mild", 0, false),
            option("Gone", 1, true),
            option("Severe", 2, false),
        ];
        kind.default = Some(FieldValue::Enum(kind.enum_options[2].id));
        let intensity = field("Intensity", FieldType::Integer, 1);
        let when = field("When", FieldType::DateTime, 2);
        let mut removed = field("Removed", FieldType::Text, 3);
        removed.deleted = true;
        let schema = CollectionSchema {
            id: collection_id,
            name: "Headache".into(),
            description: "Daily log".into(),
            fields: vec![kind.clone(), intensity.clone(), when.clone(), removed],
            deleted: false,
        };
        let doubled = ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id,
            name: "Doubled".into(),
            declared_type: ValueType::Integer,
            nullable: true,
            expression: VersionedExpression::new(Expression::Arithmetic {
                operator: ArithmeticOperator::Add,
                left: Box::new(source_field(intensity.id)),
                right: Box::new(source_field(intensity.id)),
            }),
            order: 0,
            deleted: false,
        };
        let mut gone_computed = doubled.clone();
        gone_computed.id = ComputedFieldId::new();
        gone_computed.deleted = true;
        let severe_filter = Expression::Compare {
            operator: ComparisonOperator::Equal,
            left: Box::new(source_field(kind.id)),
            right: Box::new(Expression::Constant {
                value: TypedValue::Enum(kind.enum_options[2].id),
            }),
        };
        let computed_ref = Expression::Field {
            field: FieldReference::Computed(doubled.id),
        };
        let query = |name: &str, order: i64, shape: QueryShape| QueryDefinition {
            id: QueryId::new(),
            collection_id,
            name: name.into(),
            query: VersionedCollectionQuery::new(CollectionQuery {
                collection_id,
                filter: Some(severe_filter.clone()),
                grouping: None,
                shape,
                sorting: vec![],
                limit: None,
                calendar: CalendarPolicy::default(),
            }),
            order,
            deleted: false,
        };
        let mut series = query(
            "Series",
            1,
            QueryShape::Series {
                x: source_field(when.id),
                y: computed_ref.clone(),
            },
        );
        let mut body = series.query.query().unwrap();
        body.grouping = Some(Grouping {
            expression: source_field(when.id),
            period: BucketPeriod::Week,
        });
        body.sorting = vec![SortClause {
            expression: computed_ref.clone(),
            direction: SortDirection::Descending,
            null_order: NullOrder::Last,
        }];
        body.limit = Some(10);
        series.query = VersionedCollectionQuery::new(body);
        let mut gone_query = query(
            "Gone",
            4,
            QueryShape::Scalar {
                aggregation: Aggregation::Count,
            },
        );
        gone_query.deleted = true;
        let queries = vec![
            query(
                "Average",
                0,
                QueryShape::Scalar {
                    aggregation: Aggregation::Average {
                        expression: computed_ref.clone(),
                        output_scale: 2,
                        rounding: RoundingPolicy::HalfEven,
                    },
                },
            ),
            series,
            query(
                "By kind",
                2,
                QueryShape::CategorySeries {
                    category: source_field(kind.id),
                    aggregation: Aggregation::Max {
                        expression: source_field(intensity.id),
                    },
                },
            ),
            query(
                "Records",
                3,
                QueryShape::RecordSet {
                    fields: vec![
                        FieldReference::Source(kind.id),
                        FieldReference::Computed(doubled.id),
                    ],
                },
            ),
            gone_query,
        ];
        let widget = |query_id: QueryId, order: i64, deleted: bool| WidgetDefinition {
            id: WidgetId::new(),
            collection_id,
            widget_type: WidgetType::new("core.aggregate-number").unwrap(),
            query_id,
            title: "Average".into(),
            configuration: WidgetConfiguration::empty(),
            layout: WidgetLayout::default(),
            order,
            deleted,
        };
        let widgets = vec![
            widget(queries[0].id, 0, false),
            widget(queries[0].id, 1, true),
            widget(queries[0].id, 2, false),
        ];
        Fixture {
            schema,
            computed: vec![doubled, gone_computed],
            queries,
            widgets,
        }
    }

    /// Every UUID in the fixture, including tombstoned entities.
    fn source_ids(fixture: &Fixture) -> Vec<String> {
        let mut ids = vec![fixture.schema.id.to_string()];
        for field in &fixture.schema.fields {
            ids.push(field.id.to_string());
            ids.extend(
                field
                    .enum_options
                    .iter()
                    .map(|option| option.id.to_string()),
            );
        }
        ids.extend(fixture.computed.iter().map(|item| item.id.to_string()));
        ids.extend(fixture.queries.iter().map(|item| item.id.to_string()));
        ids.extend(fixture.widgets.iter().map(|item| item.id.to_string()));
        ids
    }

    fn remap_for(fixture: &Fixture) -> IdRemap {
        IdRemap::for_collection(
            fixture.schema.id,
            CollectionSchemaId::new(),
            &fixture.schema.fields,
            &fixture.computed,
            &fixture.queries,
        )
    }

    #[test]
    fn table_has_fresh_ids_for_active_entities_only() {
        let fixture = fixture();
        let remap = remap_for(&fixture);
        let sources = source_ids(&fixture);
        let generated: Vec<String> = std::iter::once(remap.collection.1.to_string())
            .chain(remap.fields.values().map(ToString::to_string))
            .chain(remap.options.values().map(ToString::to_string))
            .chain(remap.computed.values().map(ToString::to_string))
            .chain(remap.queries.values().map(ToString::to_string))
            .collect();
        assert!(generated.iter().all(|id| !sources.contains(id)));
        assert_eq!(remap.fields.len(), 3);
        assert_eq!(remap.options.len(), 2);
        assert_eq!(remap.computed.len(), 1);
        assert_eq!(remap.queries.len(), 4);
        let removed_field = &fixture.schema.fields[3];
        assert!(!remap.fields.contains_key(&removed_field.id));
        assert!(
            !remap
                .options
                .contains_key(&fixture.schema.fields[0].enum_options[1].id)
        );
        assert!(!remap.computed.contains_key(&fixture.computed[1].id));
        assert!(!remap.queries.contains_key(&fixture.queries[4].id));
    }

    #[test]
    fn nested_expression_rewrites_every_reference() {
        let fixture = fixture();
        let remap = remap_for(&fixture);
        let kind = &fixture.schema.fields[0];
        let intensity = &fixture.schema.fields[1];
        let expression = Expression::Boolean {
            operator: crate::query::BooleanOperator::And,
            left: Box::new(Expression::Not {
                expression: Box::new(Expression::Compare {
                    operator: ComparisonOperator::NotEqual,
                    left: Box::new(source_field(kind.id)),
                    right: Box::new(Expression::Constant {
                        value: TypedValue::Enum(kind.enum_options[0].id),
                    }),
                }),
            }),
            right: Box::new(Expression::IsNotNull {
                expression: Box::new(Expression::Divide {
                    left: Box::new(Expression::Abs {
                        expression: Box::new(source_field(intensity.id)),
                    }),
                    right: Box::new(Expression::Field {
                        field: FieldReference::Computed(fixture.computed[0].id),
                    }),
                    output_scale: 1,
                    rounding: RoundingPolicy::RejectInexact,
                }),
            }),
        };
        let remapped = remap_expression(&expression, &remap).unwrap();
        let expected = Expression::Boolean {
            operator: crate::query::BooleanOperator::And,
            left: Box::new(Expression::Not {
                expression: Box::new(Expression::Compare {
                    operator: ComparisonOperator::NotEqual,
                    left: Box::new(source_field(remap.fields[&kind.id])),
                    right: Box::new(Expression::Constant {
                        value: TypedValue::Enum(remap.options[&kind.enum_options[0].id]),
                    }),
                }),
            }),
            right: Box::new(Expression::IsNotNull {
                expression: Box::new(Expression::Divide {
                    left: Box::new(Expression::Abs {
                        expression: Box::new(source_field(remap.fields[&intensity.id])),
                    }),
                    right: Box::new(Expression::Field {
                        field: FieldReference::Computed(remap.computed[&fixture.computed[0].id]),
                    }),
                    output_scale: 1,
                    rounding: RoundingPolicy::RejectInexact,
                }),
            }),
        };
        assert_eq!(remapped, expected);
    }

    #[test]
    fn dangling_ids_are_errors() {
        let fixture = fixture();
        let remap = remap_for(&fixture);
        let removed = fixture.schema.fields[3].id;
        let cases = [
            source_field(removed),
            source_field(FieldId::new()),
            Expression::Field {
                field: FieldReference::Computed(fixture.computed[1].id),
            },
            Expression::Constant {
                value: TypedValue::Enum(fixture.schema.fields[0].enum_options[1].id),
            },
            Expression::IsNull {
                expression: Box::new(source_field(removed)),
            },
        ];
        for expression in cases {
            assert!(matches!(
                remap_expression(&expression, &remap),
                Err(DomainError::Invalid {
                    field: "dangling_reference",
                    ..
                })
            ));
        }
        let mut foreign = fixture.queries[0].query.query().unwrap();
        foreign.collection_id = CollectionSchemaId::new();
        assert!(remap_query(&foreign, &remap).is_err());
    }

    #[test]
    fn queries_and_fields_round_trip_without_source_ids() {
        let fixture = fixture();
        let remap = remap_for(&fixture);
        let sources = source_ids(&fixture);
        for definition in fixture.queries.iter().filter(|item| !item.deleted) {
            let query = definition.query.query().unwrap();
            let remapped = remap_query(&query, &remap).unwrap();
            let decoded = VersionedCollectionQuery::new(remapped.clone())
                .query()
                .unwrap();
            assert_eq!(decoded, remapped);
            assert_eq!(decoded.collection_id, remap.collection.1);
            assert_eq!(decoded.limit, query.limit);
            assert_eq!(decoded.calendar, query.calendar);
            let encoded = serde_json::to_string(&decoded).unwrap();
            assert!(sources.iter().all(|id| !encoded.contains(id)), "{encoded}");
        }
        let kind = &fixture.schema.fields[0];
        let remapped = remap_field(kind, &remap).unwrap();
        assert_eq!(remapped.id, remap.fields[&kind.id]);
        assert_eq!(
            remapped
                .enum_options
                .iter()
                .map(|option| (option.id, option.label.as_str(), option.order))
                .collect::<Vec<_>>(),
            vec![
                (remap.options[&kind.enum_options[0].id], "Mild", 0),
                (remap.options[&kind.enum_options[2].id], "Severe", 2),
            ]
        );
        assert_eq!(
            remapped.default,
            Some(FieldValue::Enum(remap.options[&kind.enum_options[2].id]))
        );
        let encoded = serde_json::to_string(&remapped).unwrap();
        assert!(sources.iter().all(|id| !encoded.contains(id)));
    }

    #[test]
    fn definitions_and_widgets_are_remapped_with_order_preserved() {
        let fixture = fixture();
        let target = CollectionSchemaId::new();
        let plan = clone_plan(
            &fixture.schema,
            target,
            "Migraine",
            &fixture.computed,
            &fixture.queries,
            &fixture.widgets,
        )
        .unwrap();
        assert_eq!(plan.schema.id, target);
        assert_eq!(plan.schema.name, "Migraine");
        assert_eq!(plan.schema.description, "Daily log");
        assert_eq!(
            plan.schema
                .fields
                .iter()
                .map(|field| (field.name.as_str(), field.order))
                .collect::<Vec<_>>(),
            vec![("Kind", 0), ("Intensity", 1), ("When", 2)]
        );
        assert_eq!(plan.computed_fields.len(), 1);
        assert_eq!(plan.computed_fields[0].collection_id, target);
        assert_eq!(
            plan.computed_fields[0].expression.expression().unwrap(),
            Expression::Arithmetic {
                operator: ArithmeticOperator::Add,
                left: Box::new(source_field(plan.schema.fields[1].id)),
                right: Box::new(source_field(plan.schema.fields[1].id)),
            }
        );
        assert_eq!(
            plan.query_definitions
                .iter()
                .map(|query| (query.name.as_str(), query.order))
                .collect::<Vec<_>>(),
            vec![
                ("Average", 0),
                ("Series", 1),
                ("By kind", 2),
                ("Records", 3)
            ]
        );
        assert!(
            plan.query_definitions
                .iter()
                .all(|query| query.collection_id == target)
        );
        assert_eq!(
            plan.widgets
                .iter()
                .map(|widget| widget.order)
                .collect::<Vec<_>>(),
            vec![0, 2]
        );
        assert!(
            plan.widgets
                .iter()
                .all(|widget| widget.collection_id == target
                    && widget.query_id == plan.query_definitions[0].id)
        );
        let sources = source_ids(&fixture);
        let encoded = format!(
            "{}{}{}{}",
            serde_json::to_string(&plan.schema).unwrap(),
            serde_json::to_string(&plan.computed_fields).unwrap(),
            serde_json::to_string(&plan.query_definitions).unwrap(),
            serde_json::to_string(&plan.widgets).unwrap(),
        );
        assert!(sources.iter().all(|id| !encoded.contains(id)));
    }
}
