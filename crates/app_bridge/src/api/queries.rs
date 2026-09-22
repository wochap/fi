use app_core::{ComputedFieldId, QueryId};

use crate::api::{
    lifecycle::core,
    models::{
        AggregationDto, AggregationKindDto, ArithmeticOperatorDto, BooleanOperatorDto, BridgeError,
        BucketPeriodDto, CalendarPolicyDto, CategoryPointDto, CollectionQueryDto,
        ComparisonOperatorDto, ComputedFieldDefinitionDto, CurrentBoundaryDto, ExpressionDto,
        ExpressionKindDto, ExpressionNodeDto, FieldReferenceDto, FieldReferenceKindDto,
        GroupingDto, InferredTypeDto, NullOrderDto, QueryDefinitionDto, QueryResultDto,
        QueryResultKindDto, QueryShapeDto, QueryShapeKindDto, ResultRecordDto,
        ResultRecordValueDto, RoundingPolicyDto, SeriesPointDto, SortClauseDto, SortDirectionDto,
        TypedValueDto, ValueTypeDto, ValueTypeKindDto, WeekStartDto,
    },
};

pub async fn create_computed_field(
    mut definition: ComputedFieldDefinitionDto,
) -> Result<String, BridgeError> {
    let id = if definition.id.is_empty() {
        ComputedFieldId::new()
    } else {
        definition.id.parse().map_err(validation)?
    };
    definition.id = id.to_string();
    core()
        .await?
        .create_computed_field(definition.try_into()?)
        .await
        .map_err(BridgeError::from)?;
    Ok(id.to_string())
}
pub async fn update_computed_field(
    definition: ComputedFieldDefinitionDto,
) -> Result<(), BridgeError> {
    core()
        .await?
        .update_computed_field(definition.try_into()?)
        .await
        .map_err(Into::into)
}
pub async fn remove_computed_field(collection_id: String, id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .remove_computed_field(
            collection_id.parse().map_err(validation)?,
            id.parse().map_err(validation)?,
        )
        .await
        .map_err(Into::into)
}
pub async fn reorder_computed_fields(
    collection_id: String,
    ids: Vec<String>,
) -> Result<(), BridgeError> {
    core()
        .await?
        .reorder_computed_fields(
            collection_id.parse().map_err(validation)?,
            ids.into_iter()
                .map(|id| id.parse().map_err(validation))
                .collect::<Result<_, _>>()?,
        )
        .await
        .map_err(Into::into)
}
pub async fn list_computed_fields(
    collection_id: String,
) -> Result<Vec<ComputedFieldDefinitionDto>, BridgeError> {
    core()
        .await?
        .computed_fields(collection_id.parse().map_err(validation)?)
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}

pub async fn create_query_definition(
    mut definition: QueryDefinitionDto,
) -> Result<String, BridgeError> {
    let id = if definition.id.is_empty() {
        QueryId::new()
    } else {
        definition.id.parse().map_err(validation)?
    };
    definition.id = id.to_string();
    core()
        .await?
        .create_query_definition(definition.try_into()?)
        .await
        .map_err(BridgeError::from)?;
    Ok(id.to_string())
}
pub async fn update_query_definition(definition: QueryDefinitionDto) -> Result<(), BridgeError> {
    core()
        .await?
        .update_query_definition(definition.try_into()?)
        .await
        .map_err(Into::into)
}
pub async fn remove_query_definition(collection_id: String, id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .remove_query_definition(
            collection_id.parse().map_err(validation)?,
            id.parse().map_err(validation)?,
        )
        .await
        .map_err(Into::into)
}
pub async fn reorder_query_definitions(
    collection_id: String,
    ids: Vec<String>,
) -> Result<(), BridgeError> {
    core()
        .await?
        .reorder_query_definitions(
            collection_id.parse().map_err(validation)?,
            ids.into_iter()
                .map(|id| id.parse().map_err(validation))
                .collect::<Result<_, _>>()?,
        )
        .await
        .map_err(Into::into)
}
pub async fn list_query_definitions(
    collection_id: String,
) -> Result<Vec<QueryDefinitionDto>, BridgeError> {
    core()
        .await?
        .query_definitions(collection_id.parse().map_err(validation)?)
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}
pub async fn validate_collection_query(query: CollectionQueryDto) -> Result<(), BridgeError> {
    core()
        .await?
        .validate_collection_query(&query.try_into()?)
        .map_err(|error| BridgeError::validation(error.path, error.message))
}
/// Runs core type inference for a candidate computed-field expression without
/// writing anything; errors keep the core's positional path (`$.left.right`).
pub async fn infer_computed_expression(
    collection_id: String,
    expression: ExpressionDto,
) -> Result<InferredTypeDto, BridgeError> {
    let collection_id = collection_id.parse().map_err(validation)?;
    let expression = expression.try_into()?;
    core()
        .await?
        .infer_computed_expression(collection_id, &expression)
        .map(Into::into)
        .map_err(inference_error)
}
pub async fn execute_collection_query(
    query: CollectionQueryDto,
    now_utc_ms: i64,
) -> Result<QueryResultDto, BridgeError> {
    core()
        .await?
        .execute_collection_query(&query.try_into()?, now_utc_ms)
        .map(Into::into)
        .map_err(|error| BridgeError::validation("query", error.to_string()))
}
pub async fn execute_query_definition(
    collection_id: String,
    id: String,
    now_utc_ms: i64,
) -> Result<QueryResultDto, BridgeError> {
    core()
        .await?
        .execute_query_definition(
            collection_id.parse().map_err(validation)?,
            id.parse().map_err(validation)?,
            now_utc_ms,
        )
        .map(Into::into)
        .map_err(|error| BridgeError::validation("query", error.to_string()))
}

fn inference_error(error: app_core::QueryValidationError) -> BridgeError {
    BridgeError::validation(error.path, error.message)
}
fn validation(error: impl std::fmt::Display) -> BridgeError {
    BridgeError::validation("id", error.to_string())
}
fn missing(field: &'static str) -> BridgeError {
    BridgeError::validation(field, "required typed payload is missing")
}

impl TryFrom<ValueTypeDto> for app_core::ValueType {
    type Error = BridgeError;
    fn try_from(value: ValueTypeDto) -> Result<Self, Self::Error> {
        Ok(match value.kind {
            ValueTypeKindDto::Text => Self::Text,
            ValueTypeKindDto::Integer => Self::Integer,
            ValueTypeKindDto::FixedDecimal => Self::FixedDecimal {
                scale: value.scale.ok_or_else(|| missing("scale"))?,
            },
            ValueTypeKindDto::Boolean => Self::Boolean,
            ValueTypeKindDto::Date => Self::Date,
            ValueTypeKindDto::DateTime => Self::DateTime,
            ValueTypeKindDto::Duration => Self::Duration,
            ValueTypeKindDto::Enum => Self::Enum,
            ValueTypeKindDto::Null => Self::Null,
        })
    }
}
impl From<app_core::InferredType> for InferredTypeDto {
    fn from(value: app_core::InferredType) -> Self {
        Self {
            value_type: value.value_type.into(),
            nullable: value.nullable,
        }
    }
}

impl From<app_core::ValueType> for ValueTypeDto {
    fn from(value: app_core::ValueType) -> Self {
        let (kind, scale) = match value {
            app_core::ValueType::Text => (ValueTypeKindDto::Text, None),
            app_core::ValueType::Integer => (ValueTypeKindDto::Integer, None),
            app_core::ValueType::FixedDecimal { scale } => {
                (ValueTypeKindDto::FixedDecimal, Some(scale))
            }
            app_core::ValueType::Boolean => (ValueTypeKindDto::Boolean, None),
            app_core::ValueType::Date => (ValueTypeKindDto::Date, None),
            app_core::ValueType::DateTime => (ValueTypeKindDto::DateTime, None),
            app_core::ValueType::Duration => (ValueTypeKindDto::Duration, None),
            app_core::ValueType::Enum => (ValueTypeKindDto::Enum, None),
            app_core::ValueType::Null => (ValueTypeKindDto::Null, None),
        };
        Self { kind, scale }
    }
}
impl TryFrom<TypedValueDto> for app_core::TypedValue {
    type Error = BridgeError;
    fn try_from(value: TypedValueDto) -> Result<Self, Self::Error> {
        Ok(match value.value_type.kind {
            ValueTypeKindDto::Null => Self::Null,
            ValueTypeKindDto::Text => {
                Self::Text(value.text_value.ok_or_else(|| missing("text_value"))?)
            }
            ValueTypeKindDto::Integer => Self::Integer(
                value
                    .integer_value
                    .ok_or_else(|| missing("integer_value"))?,
            ),
            ValueTypeKindDto::FixedDecimal => Self::FixedDecimal {
                representation: value
                    .integer_value
                    .ok_or_else(|| missing("integer_value"))?,
                scale: value.value_type.scale.ok_or_else(|| missing("scale"))?,
            },
            ValueTypeKindDto::Boolean => Self::Boolean(
                value
                    .boolean_value
                    .ok_or_else(|| missing("boolean_value"))?,
            ),
            ValueTypeKindDto::Date => Self::Date(
                value
                    .integer_value
                    .ok_or_else(|| missing("integer_value"))?,
            ),
            ValueTypeKindDto::DateTime => Self::DateTime(
                value
                    .integer_value
                    .ok_or_else(|| missing("integer_value"))?,
            ),
            ValueTypeKindDto::Duration => Self::Duration(
                value
                    .integer_value
                    .ok_or_else(|| missing("integer_value"))?,
            ),
            ValueTypeKindDto::Enum => Self::Enum(
                value
                    .text_value
                    .ok_or_else(|| missing("text_value"))?
                    .parse()
                    .map_err(validation)?,
            ),
        })
    }
}
impl From<app_core::TypedValue> for TypedValueDto {
    fn from(value: app_core::TypedValue) -> Self {
        let value_type = value.value_type().into();
        let (integer_value, text_value, boolean_value) = match value {
            app_core::TypedValue::Null => (None, None, None),
            app_core::TypedValue::Text(v) => (None, Some(v), None),
            app_core::TypedValue::Integer(v)
            | app_core::TypedValue::Date(v)
            | app_core::TypedValue::DateTime(v)
            | app_core::TypedValue::Duration(v) => (Some(v), None, None),
            app_core::TypedValue::FixedDecimal { representation, .. } => {
                (Some(representation), None, None)
            }
            app_core::TypedValue::Boolean(v) => (None, None, Some(v)),
            app_core::TypedValue::Enum(v) => (None, Some(v.to_string()), None),
        };
        Self {
            value_type,
            integer_value,
            text_value,
            boolean_value,
        }
    }
}
impl TryFrom<FieldReferenceDto> for app_core::FieldReference {
    type Error = BridgeError;
    fn try_from(value: FieldReferenceDto) -> Result<Self, Self::Error> {
        Ok(match value.kind {
            FieldReferenceKindDto::Source => Self::Source(value.id.parse().map_err(validation)?),
            FieldReferenceKindDto::Computed => {
                Self::Computed(value.id.parse().map_err(validation)?)
            }
        })
    }
}
impl From<app_core::FieldReference> for FieldReferenceDto {
    fn from(value: app_core::FieldReference) -> Self {
        match value {
            app_core::FieldReference::Source(id) => Self {
                kind: FieldReferenceKindDto::Source,
                id: id.to_string(),
            },
            app_core::FieldReference::Computed(id) => Self {
                kind: FieldReferenceKindDto::Computed,
                id: id.to_string(),
            },
        }
    }
}

impl TryFrom<ExpressionDto> for app_core::Expression {
    type Error = BridgeError;
    fn try_from(value: ExpressionDto) -> Result<Self, Self::Error> {
        decode_node(value.root, &value.nodes, &mut vec![])
    }
}

impl From<app_core::Expression> for ExpressionDto {
    fn from(value: app_core::Expression) -> Self {
        let mut nodes = Vec::new();
        let root = encode_node(value, &mut nodes);
        Self { root, nodes }
    }
}

fn empty_node(kind: ExpressionKindDto) -> ExpressionNodeDto {
    ExpressionNodeDto {
        kind,
        value: None,
        field: None,
        arithmetic_operator: None,
        comparison_operator: None,
        boolean_operator: None,
        left: None,
        right: None,
        expression: None,
        output_scale: None,
        rounding: None,
        boundary: None,
    }
}
fn encode_node(value: app_core::Expression, nodes: &mut Vec<ExpressionNodeDto>) -> u32 {
    let mut node = empty_node(ExpressionKindDto::Constant);
    match value {
        app_core::Expression::Constant { value } => {
            node.value = Some(value.into());
        }
        app_core::Expression::Field { field } => {
            node.kind = ExpressionKindDto::Field;
            node.field = Some(field.into());
        }
        app_core::Expression::Arithmetic {
            operator,
            left,
            right,
        } => {
            node.kind = ExpressionKindDto::Arithmetic;
            node.arithmetic_operator = Some(match operator {
                app_core::ArithmeticOperator::Add => ArithmeticOperatorDto::Add,
                app_core::ArithmeticOperator::Subtract => ArithmeticOperatorDto::Subtract,
                app_core::ArithmeticOperator::Multiply => ArithmeticOperatorDto::Multiply,
            });
            node.left = Some(encode_node(*left, nodes));
            node.right = Some(encode_node(*right, nodes));
        }
        app_core::Expression::Divide {
            left,
            right,
            output_scale,
            rounding: policy,
        } => {
            node.kind = ExpressionKindDto::Divide;
            node.left = Some(encode_node(*left, nodes));
            node.right = Some(encode_node(*right, nodes));
            node.output_scale = Some(output_scale);
            node.rounding = Some(policy.into());
        }
        app_core::Expression::Compare {
            operator,
            left,
            right,
        } => {
            node.kind = ExpressionKindDto::Compare;
            node.comparison_operator = Some(operator.into());
            node.left = Some(encode_node(*left, nodes));
            node.right = Some(encode_node(*right, nodes));
        }
        app_core::Expression::Boolean {
            operator,
            left,
            right,
        } => {
            node.kind = ExpressionKindDto::Boolean;
            node.boolean_operator = Some(match operator {
                app_core::BooleanOperator::And => BooleanOperatorDto::And,
                app_core::BooleanOperator::Or => BooleanOperatorDto::Or,
            });
            node.left = Some(encode_node(*left, nodes));
            node.right = Some(encode_node(*right, nodes));
        }
        app_core::Expression::Not { expression } => {
            node.kind = ExpressionKindDto::Not;
            node.expression = Some(encode_node(*expression, nodes));
        }
        app_core::Expression::IsNull { expression } => {
            node.kind = ExpressionKindDto::IsNull;
            node.expression = Some(encode_node(*expression, nodes));
        }
        app_core::Expression::IsNotNull { expression } => {
            node.kind = ExpressionKindDto::IsNotNull;
            node.expression = Some(encode_node(*expression, nodes));
        }
        app_core::Expression::Abs { expression } => {
            node.kind = ExpressionKindDto::Abs;
            node.expression = Some(encode_node(*expression, nodes));
        }
        app_core::Expression::StartOfCurrent { boundary } => {
            node.kind = ExpressionKindDto::StartOfCurrent;
            node.boundary = Some(match boundary {
                app_core::CurrentBoundary::Day => CurrentBoundaryDto::Day,
                app_core::CurrentBoundary::Week => CurrentBoundaryDto::Week,
                app_core::CurrentBoundary::Month => CurrentBoundaryDto::Month,
                app_core::CurrentBoundary::Year => CurrentBoundaryDto::Year,
            });
        }
    }
    let index = u32::try_from(nodes.len()).expect("expression node count fits u32");
    nodes.push(node);
    index
}
fn decode_node(
    index: u32,
    nodes: &[ExpressionNodeDto],
    stack: &mut Vec<u32>,
) -> Result<app_core::Expression, BridgeError> {
    if stack.contains(&index) {
        return Err(BridgeError::validation(
            "expression",
            "node graph contains a cycle",
        ));
    }
    stack.push(index);
    let node = nodes
        .get(index as usize)
        .ok_or_else(|| BridgeError::validation("expression", "node index is out of bounds"))?
        .clone();
    let child = |value: Option<u32>, name: &'static str, stack: &mut Vec<u32>| {
        decode_node(value.ok_or_else(|| missing(name))?, nodes, stack)
    };
    let result = match node.kind {
        ExpressionKindDto::Constant => app_core::Expression::Constant {
            value: node.value.ok_or_else(|| missing("value"))?.try_into()?,
        },
        ExpressionKindDto::Field => app_core::Expression::Field {
            field: node.field.ok_or_else(|| missing("field"))?.try_into()?,
        },
        ExpressionKindDto::Arithmetic => app_core::Expression::Arithmetic {
            operator: match node
                .arithmetic_operator
                .ok_or_else(|| missing("arithmetic_operator"))?
            {
                ArithmeticOperatorDto::Add => app_core::ArithmeticOperator::Add,
                ArithmeticOperatorDto::Subtract => app_core::ArithmeticOperator::Subtract,
                ArithmeticOperatorDto::Multiply => app_core::ArithmeticOperator::Multiply,
            },
            left: Box::new(child(node.left, "left", stack)?),
            right: Box::new(child(node.right, "right", stack)?),
        },
        ExpressionKindDto::Divide => app_core::Expression::Divide {
            left: Box::new(child(node.left, "left", stack)?),
            right: Box::new(child(node.right, "right", stack)?),
            output_scale: node.output_scale.ok_or_else(|| missing("output_scale"))?,
            rounding: rounding(node.rounding.ok_or_else(|| missing("rounding"))?),
        },
        ExpressionKindDto::Compare => app_core::Expression::Compare {
            operator: comparison(
                node.comparison_operator
                    .ok_or_else(|| missing("comparison_operator"))?,
            ),
            left: Box::new(child(node.left, "left", stack)?),
            right: Box::new(child(node.right, "right", stack)?),
        },
        ExpressionKindDto::Boolean => app_core::Expression::Boolean {
            operator: match node
                .boolean_operator
                .ok_or_else(|| missing("boolean_operator"))?
            {
                BooleanOperatorDto::And => app_core::BooleanOperator::And,
                BooleanOperatorDto::Or => app_core::BooleanOperator::Or,
            },
            left: Box::new(child(node.left, "left", stack)?),
            right: Box::new(child(node.right, "right", stack)?),
        },
        ExpressionKindDto::Not => app_core::Expression::Not {
            expression: Box::new(child(node.expression, "expression", stack)?),
        },
        ExpressionKindDto::IsNull => app_core::Expression::IsNull {
            expression: Box::new(child(node.expression, "expression", stack)?),
        },
        ExpressionKindDto::IsNotNull => app_core::Expression::IsNotNull {
            expression: Box::new(child(node.expression, "expression", stack)?),
        },
        ExpressionKindDto::Abs => app_core::Expression::Abs {
            expression: Box::new(child(node.expression, "expression", stack)?),
        },
        ExpressionKindDto::StartOfCurrent => app_core::Expression::StartOfCurrent {
            boundary: match node.boundary.ok_or_else(|| missing("boundary"))? {
                CurrentBoundaryDto::Day => app_core::CurrentBoundary::Day,
                CurrentBoundaryDto::Week => app_core::CurrentBoundary::Week,
                CurrentBoundaryDto::Month => app_core::CurrentBoundary::Month,
                CurrentBoundaryDto::Year => app_core::CurrentBoundary::Year,
            },
        },
    };
    stack.pop();
    Ok(result)
}
fn rounding(value: RoundingPolicyDto) -> app_core::RoundingPolicy {
    match value {
        RoundingPolicyDto::RejectInexact => app_core::RoundingPolicy::RejectInexact,
        RoundingPolicyDto::HalfEven => app_core::RoundingPolicy::HalfEven,
    }
}
impl From<app_core::RoundingPolicy> for RoundingPolicyDto {
    fn from(value: app_core::RoundingPolicy) -> Self {
        match value {
            app_core::RoundingPolicy::RejectInexact => Self::RejectInexact,
            app_core::RoundingPolicy::HalfEven => Self::HalfEven,
        }
    }
}
fn comparison(value: ComparisonOperatorDto) -> app_core::ComparisonOperator {
    match value {
        ComparisonOperatorDto::Equal => app_core::ComparisonOperator::Equal,
        ComparisonOperatorDto::NotEqual => app_core::ComparisonOperator::NotEqual,
        ComparisonOperatorDto::GreaterThan => app_core::ComparisonOperator::GreaterThan,
        ComparisonOperatorDto::GreaterThanOrEqual => {
            app_core::ComparisonOperator::GreaterThanOrEqual
        }
        ComparisonOperatorDto::LessThan => app_core::ComparisonOperator::LessThan,
        ComparisonOperatorDto::LessThanOrEqual => app_core::ComparisonOperator::LessThanOrEqual,
    }
}
impl From<app_core::ComparisonOperator> for ComparisonOperatorDto {
    fn from(v: app_core::ComparisonOperator) -> Self {
        match v {
            app_core::ComparisonOperator::Equal => Self::Equal,
            app_core::ComparisonOperator::NotEqual => Self::NotEqual,
            app_core::ComparisonOperator::GreaterThan => Self::GreaterThan,
            app_core::ComparisonOperator::GreaterThanOrEqual => Self::GreaterThanOrEqual,
            app_core::ComparisonOperator::LessThan => Self::LessThan,
            app_core::ComparisonOperator::LessThanOrEqual => Self::LessThanOrEqual,
        }
    }
}

impl TryFrom<CalendarPolicyDto> for app_core::CalendarPolicy {
    type Error = BridgeError;
    fn try_from(v: CalendarPolicyDto) -> Result<Self, Self::Error> {
        Ok(Self {
            timezone: v.timezone,
            week_start: match v.week_start {
                WeekStartDto::Monday => app_core::WeekStart::Monday,
                WeekStartDto::Tuesday => app_core::WeekStart::Tuesday,
                WeekStartDto::Wednesday => app_core::WeekStart::Wednesday,
                WeekStartDto::Thursday => app_core::WeekStart::Thursday,
                WeekStartDto::Friday => app_core::WeekStart::Friday,
                WeekStartDto::Saturday => app_core::WeekStart::Saturday,
                WeekStartDto::Sunday => app_core::WeekStart::Sunday,
            },
        })
    }
}
impl From<app_core::CalendarPolicy> for CalendarPolicyDto {
    fn from(v: app_core::CalendarPolicy) -> Self {
        Self {
            timezone: v.timezone,
            week_start: match v.week_start {
                app_core::WeekStart::Monday => WeekStartDto::Monday,
                app_core::WeekStart::Tuesday => WeekStartDto::Tuesday,
                app_core::WeekStart::Wednesday => WeekStartDto::Wednesday,
                app_core::WeekStart::Thursday => WeekStartDto::Thursday,
                app_core::WeekStart::Friday => WeekStartDto::Friday,
                app_core::WeekStart::Saturday => WeekStartDto::Saturday,
                app_core::WeekStart::Sunday => WeekStartDto::Sunday,
            },
        }
    }
}

impl TryFrom<AggregationDto> for app_core::Aggregation {
    type Error = BridgeError;
    fn try_from(v: AggregationDto) -> Result<Self, Self::Error> {
        Ok(match v.kind {
            AggregationKindDto::Count => Self::Count,
            AggregationKindDto::Sum => Self::Sum {
                expression: v
                    .expression
                    .ok_or_else(|| missing("aggregation.expression"))?
                    .try_into()?,
            },
            AggregationKindDto::Average => Self::Average {
                expression: v
                    .expression
                    .ok_or_else(|| missing("aggregation.expression"))?
                    .try_into()?,
                output_scale: v
                    .output_scale
                    .ok_or_else(|| missing("aggregation.output_scale"))?,
                rounding: rounding(v.rounding.ok_or_else(|| missing("aggregation.rounding"))?),
            },
            AggregationKindDto::Min => Self::Min {
                expression: v
                    .expression
                    .ok_or_else(|| missing("aggregation.expression"))?
                    .try_into()?,
            },
            AggregationKindDto::Max => Self::Max {
                expression: v
                    .expression
                    .ok_or_else(|| missing("aggregation.expression"))?
                    .try_into()?,
            },
        })
    }
}
impl From<app_core::Aggregation> for AggregationDto {
    fn from(v: app_core::Aggregation) -> Self {
        match v {
            app_core::Aggregation::Count => Self {
                kind: AggregationKindDto::Count,
                expression: None,
                output_scale: None,
                rounding: None,
            },
            app_core::Aggregation::Sum { expression } => Self {
                kind: AggregationKindDto::Sum,
                expression: Some(expression.into()),
                output_scale: None,
                rounding: None,
            },
            app_core::Aggregation::Average {
                expression,
                output_scale,
                rounding,
            } => Self {
                kind: AggregationKindDto::Average,
                expression: Some(expression.into()),
                output_scale: Some(output_scale),
                rounding: Some(rounding.into()),
            },
            app_core::Aggregation::Min { expression } => Self {
                kind: AggregationKindDto::Min,
                expression: Some(expression.into()),
                output_scale: None,
                rounding: None,
            },
            app_core::Aggregation::Max { expression } => Self {
                kind: AggregationKindDto::Max,
                expression: Some(expression.into()),
                output_scale: None,
                rounding: None,
            },
        }
    }
}

impl TryFrom<CollectionQueryDto> for app_core::CollectionQuery {
    type Error = BridgeError;
    fn try_from(v: CollectionQueryDto) -> Result<Self, Self::Error> {
        Ok(Self {
            collection_id: v.collection_id.parse().map_err(validation)?,
            filter: v.filter.map(TryInto::try_into).transpose()?,
            grouping: v
                .grouping
                .map(|g| {
                    Ok::<_, BridgeError>(app_core::Grouping {
                        expression: g.expression.try_into()?,
                        period: match g.period {
                            BucketPeriodDto::Day => app_core::BucketPeriod::Day,
                            BucketPeriodDto::Week => app_core::BucketPeriod::Week,
                            BucketPeriodDto::Month => app_core::BucketPeriod::Month,
                            BucketPeriodDto::Year => app_core::BucketPeriod::Year,
                        },
                    })
                })
                .transpose()?,
            shape: v.shape.try_into()?,
            sorting: v
                .sorting
                .into_iter()
                .map(|s| {
                    Ok::<_, BridgeError>(app_core::SortClause {
                        expression: s.expression.try_into()?,
                        direction: match s.direction {
                            SortDirectionDto::Ascending => app_core::SortDirection::Ascending,
                            SortDirectionDto::Descending => app_core::SortDirection::Descending,
                        },
                        null_order: match s.null_order {
                            NullOrderDto::First => app_core::NullOrder::First,
                            NullOrderDto::Last => app_core::NullOrder::Last,
                        },
                    })
                })
                .collect::<Result<_, _>>()?,
            limit: v.limit,
            calendar: v.calendar.try_into()?,
        })
    }
}
impl TryFrom<QueryShapeDto> for app_core::QueryShape {
    type Error = BridgeError;
    fn try_from(v: QueryShapeDto) -> Result<Self, Self::Error> {
        Ok(match v.kind {
            QueryShapeKindDto::Scalar => Self::Scalar {
                aggregation: v
                    .aggregation
                    .ok_or_else(|| missing("shape.aggregation"))?
                    .try_into()?,
            },
            QueryShapeKindDto::Series => Self::Series {
                x: v.x.ok_or_else(|| missing("shape.x"))?.try_into()?,
                y: v.y.ok_or_else(|| missing("shape.y"))?.try_into()?,
            },
            QueryShapeKindDto::CategorySeries => Self::CategorySeries {
                category: v
                    .category
                    .ok_or_else(|| missing("shape.category"))?
                    .try_into()?,
                aggregation: v
                    .aggregation
                    .ok_or_else(|| missing("shape.aggregation"))?
                    .try_into()?,
            },
            QueryShapeKindDto::RecordSet => Self::RecordSet {
                fields: v
                    .fields
                    .into_iter()
                    .map(TryInto::try_into)
                    .collect::<Result<_, _>>()?,
            },
        })
    }
}

impl TryFrom<ComputedFieldDefinitionDto> for app_core::ComputedFieldDefinition {
    type Error = BridgeError;
    fn try_from(v: ComputedFieldDefinitionDto) -> Result<Self, Self::Error> {
        let body = if let Some(expression) = v.expression {
            serde_json::to_value(app_core::Expression::try_from(expression)?)
                .map_err(|e| BridgeError::validation("expression", e.to_string()))?
        } else {
            serde_json::from_str(
                &v.unsupported_body_json
                    .ok_or_else(|| missing("expression"))?,
            )
            .map_err(|e| BridgeError::validation("expression", e.to_string()))?
        };
        Ok(Self {
            id: v.id.parse().map_err(validation)?,
            collection_id: v.collection_id.parse().map_err(validation)?,
            name: v.name,
            declared_type: v.declared_type.try_into()?,
            nullable: v.nullable,
            expression: app_core::VersionedExpression {
                version: v.expression_version,
                body,
            },
            order: v.order,
            deleted: v.deleted,
        })
    }
}
impl From<app_core::ComputedFieldDefinition> for ComputedFieldDefinitionDto {
    fn from(v: app_core::ComputedFieldDefinition) -> Self {
        let parsed = v.expression.expression().ok().map(Into::into);
        let unsupported_body_json = parsed.is_none().then(|| v.expression.body.to_string());
        Self {
            id: v.id.to_string(),
            collection_id: v.collection_id.to_string(),
            name: v.name,
            declared_type: v.declared_type.into(),
            nullable: v.nullable,
            expression_version: v.expression.version,
            expression: parsed,
            unsupported_body_json,
            order: v.order,
            deleted: v.deleted,
        }
    }
}
impl TryFrom<QueryDefinitionDto> for app_core::QueryDefinition {
    type Error = BridgeError;
    fn try_from(v: QueryDefinitionDto) -> Result<Self, Self::Error> {
        let body = if let Some(query) = v.query {
            serde_json::to_value(app_core::CollectionQuery::try_from(query)?)
                .map_err(|e| BridgeError::validation("query", e.to_string()))?
        } else {
            serde_json::from_str(&v.unsupported_body_json.ok_or_else(|| missing("query"))?)
                .map_err(|e| BridgeError::validation("query", e.to_string()))?
        };
        Ok(Self {
            id: v.id.parse().map_err(validation)?,
            collection_id: v.collection_id.parse().map_err(validation)?,
            name: v.name,
            query: app_core::VersionedCollectionQuery {
                version: v.query_version,
                body,
            },
            order: v.order,
            deleted: v.deleted,
        })
    }
}
impl From<app_core::QueryDefinition> for QueryDefinitionDto {
    fn from(v: app_core::QueryDefinition) -> Self {
        let query = v.query.query().ok().map(Into::into);
        let unsupported_body_json = query.is_none().then(|| v.query.body.to_string());
        Self {
            id: v.id.to_string(),
            collection_id: v.collection_id.to_string(),
            name: v.name,
            query_version: v.query.version,
            query,
            unsupported_body_json,
            order: v.order,
            deleted: v.deleted,
        }
    }
}

impl From<app_core::CollectionQuery> for CollectionQueryDto {
    fn from(v: app_core::CollectionQuery) -> Self {
        Self {
            collection_id: v.collection_id.to_string(),
            filter: v.filter.map(Into::into),
            grouping: v.grouping.map(|g| GroupingDto {
                expression: g.expression.into(),
                period: match g.period {
                    app_core::BucketPeriod::Day => BucketPeriodDto::Day,
                    app_core::BucketPeriod::Week => BucketPeriodDto::Week,
                    app_core::BucketPeriod::Month => BucketPeriodDto::Month,
                    app_core::BucketPeriod::Year => BucketPeriodDto::Year,
                },
            }),
            shape: v.shape.into(),
            sorting: v
                .sorting
                .into_iter()
                .map(|s| SortClauseDto {
                    expression: s.expression.into(),
                    direction: match s.direction {
                        app_core::SortDirection::Ascending => SortDirectionDto::Ascending,
                        app_core::SortDirection::Descending => SortDirectionDto::Descending,
                    },
                    null_order: match s.null_order {
                        app_core::NullOrder::First => NullOrderDto::First,
                        app_core::NullOrder::Last => NullOrderDto::Last,
                    },
                })
                .collect(),
            limit: v.limit,
            calendar: v.calendar.into(),
        }
    }
}
impl From<app_core::QueryShape> for QueryShapeDto {
    fn from(v: app_core::QueryShape) -> Self {
        match v {
            app_core::QueryShape::Scalar { aggregation } => Self {
                kind: QueryShapeKindDto::Scalar,
                aggregation: Some(aggregation.into()),
                x: None,
                y: None,
                category: None,
                fields: vec![],
            },
            app_core::QueryShape::Series { x, y } => Self {
                kind: QueryShapeKindDto::Series,
                aggregation: None,
                x: Some(x.into()),
                y: Some(y.into()),
                category: None,
                fields: vec![],
            },
            app_core::QueryShape::CategorySeries {
                category,
                aggregation,
            } => Self {
                kind: QueryShapeKindDto::CategorySeries,
                aggregation: Some(aggregation.into()),
                x: None,
                y: None,
                category: Some(category.into()),
                fields: vec![],
            },
            app_core::QueryShape::RecordSet { fields } => Self {
                kind: QueryShapeKindDto::RecordSet,
                aggregation: None,
                x: None,
                y: None,
                category: None,
                fields: fields.into_iter().map(Into::into).collect(),
            },
        }
    }
}

impl From<app_core::QueryResult> for QueryResultDto {
    fn from(v: app_core::QueryResult) -> Self {
        let mut dto = Self {
            kind: QueryResultKindDto::Scalar,
            value: None,
            value_type: None,
            points: vec![],
            category_points: vec![],
            x_type: None,
            y_type: None,
            category_type: None,
            records: vec![],
        };
        match v {
            app_core::QueryResult::Scalar { value, value_type } => {
                dto.value = Some(value.into());
                dto.value_type = Some(value_type.into());
            }
            app_core::QueryResult::Series {
                points,
                x_type,
                y_type,
            } => {
                dto.kind = QueryResultKindDto::Series;
                dto.points = points
                    .into_iter()
                    .map(|p| SeriesPointDto {
                        x: p.x.into(),
                        y: p.y.into(),
                    })
                    .collect();
                dto.x_type = Some(x_type.into());
                dto.y_type = Some(y_type.into());
            }
            app_core::QueryResult::CategorySeries {
                points,
                category_type,
                value_type,
            } => {
                dto.kind = QueryResultKindDto::CategorySeries;
                dto.category_points = points
                    .into_iter()
                    .map(|p| CategoryPointDto {
                        category: p.category.into(),
                        value: p.value.into(),
                    })
                    .collect();
                dto.category_type = Some(category_type.into());
                dto.value_type = Some(value_type.into());
            }
            app_core::QueryResult::RecordSet { records } => {
                dto.kind = QueryResultKindDto::RecordSet;
                dto.records = records
                    .into_iter()
                    .map(|r| ResultRecordDto {
                        id: r.id.to_string(),
                        values: r
                            .values
                            .into_iter()
                            .map(|(field, value)| ResultRecordValueDto {
                                field: field.into(),
                                value: value.into(),
                            })
                            .collect(),
                    })
                    .collect();
            }
        }
        dto
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unsupported_versions_remain_structurally_visible_to_dart() {
        let core = app_core::VersionedExpression {
            version: 77,
            body: serde_json::json!({"future":"node"}),
        };
        let definition = app_core::ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id: app_core::CollectionSchemaId::new(),
            name: "Future".into(),
            declared_type: app_core::ValueType::Integer,
            nullable: false,
            expression: core,
            order: 0,
            deleted: false,
        };
        let dto = ComputedFieldDefinitionDto::from(definition);
        assert!(dto.expression.is_none());
        assert_eq!(dto.expression_version, 77);
        assert!(dto.unsupported_body_json.unwrap().contains("future"));
    }

    #[test]
    fn nested_inference_errors_keep_their_path_through_the_dto_boundary() {
        use app_core::{
            ArithmeticOperator, CollectionSchema, CollectionSchemaId, DisplayMetadata, Expression,
            FieldDefinition, FieldId, FieldReference, FieldType, TypeEnvironment,
            ValidationMetadata, infer_expression,
        };
        let field = |name: &str, scale: u8| FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type: FieldType::FixedDecimal { scale },
            required: true,
            default: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order: 0,
            deleted: false,
            enum_options: vec![],
        };
        let amount = field("Amount", 2);
        let rate = field("Rate", 3);
        let schema = CollectionSchema {
            id: CollectionSchemaId::new(),
            name: "Ledger".into(),
            description: String::new(),
            fields: vec![amount.clone(), rate.clone()],
            deleted: false,
        };
        let source = |field: &FieldDefinition| {
            Box::new(Expression::Field {
                field: FieldReference::Source(field.id),
            })
        };
        // abs(amount) * (amount + rate): the inner `+` mixes scales.
        let expression = Expression::Arithmetic {
            operator: ArithmeticOperator::Multiply,
            left: Box::new(Expression::Abs {
                expression: source(&amount),
            }),
            right: Box::new(Expression::Arithmetic {
                operator: ArithmeticOperator::Add,
                left: source(&amount),
                right: source(&rate),
            }),
        };
        let dto = ExpressionDto::from(expression);
        let decoded = app_core::Expression::try_from(dto).unwrap();
        let error = infer_expression(
            &decoded,
            &TypeEnvironment {
                schema: &schema,
                computed: &[],
            },
            false,
        )
        .map(InferredTypeDto::from)
        .map_err(inference_error)
        .unwrap_err();
        assert_eq!(error.kind, crate::api::models::BridgeErrorKind::Validation);
        assert_eq!(error.field.as_deref(), Some("$.right"));
        assert_eq!(error.message, "arithmetic operands are incompatible");
    }
}
