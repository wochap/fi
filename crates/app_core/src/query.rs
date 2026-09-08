//! Typed, serializable collection expressions and deterministic pure query evaluation.

use std::{cmp::Ordering, fmt, str::FromStr};

use chrono::{DateTime, Datelike, Duration, NaiveDate, TimeZone, Utc, Weekday};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    CollectionSchema, CollectionSchemaId, EnumOptionId, FieldId, FieldType, FieldValue,
    GenericRecord, RecordId,
};

pub const EXPRESSION_VERSION: u32 = 1;
pub const QUERY_VERSION: u32 = 1;
pub const MAX_QUERY_LIMIT: u32 = 10_000;

macro_rules! query_id {
    ($name:ident, $label:literal) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);
        impl $name {
            #[must_use]
            pub fn new() -> Self {
                Self(Uuid::now_v7())
            }
        }
        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
        impl FromStr for $name {
            type Err = QueryValidationError;
            fn from_str(value: &str) -> Result<Self, Self::Err> {
                let id = Uuid::parse_str(value)
                    .map_err(|_| QueryValidationError::new($label, "must be a canonical UUIDv7"))?;
                if id.get_version_num() != 7 || id.hyphenated().to_string() != value {
                    return Err(QueryValidationError::new(
                        $label,
                        "must be a canonical UUIDv7",
                    ));
                }
                Ok(Self(id))
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
                String::deserialize(d)?
                    .parse()
                    .map_err(serde::de::Error::custom)
            }
        }
    };
}

query_id!(QueryId, "query_id");
query_id!(ComputedFieldId, "computed_field_id");

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ValueType {
    Text,
    Integer,
    FixedDecimal { scale: u8 },
    Boolean,
    Date,
    DateTime,
    Duration,
    Enum,
    Null,
}

impl From<&FieldType> for ValueType {
    fn from(value: &FieldType) -> Self {
        match value {
            FieldType::Text => Self::Text,
            FieldType::Integer => Self::Integer,
            FieldType::FixedDecimal { scale } => Self::FixedDecimal { scale: *scale },
            FieldType::Boolean => Self::Boolean,
            FieldType::Date => Self::Date,
            FieldType::DateTime => Self::DateTime,
            FieldType::Duration => Self::Duration,
            FieldType::Enum => Self::Enum,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum TypedValue {
    Null,
    Text(String),
    Integer(i64),
    FixedDecimal { representation: i64, scale: u8 },
    Boolean(bool),
    Date(i64),
    DateTime(i64),
    Duration(i64),
    Enum(EnumOptionId),
}

impl TypedValue {
    #[must_use]
    pub fn value_type(&self) -> ValueType {
        match self {
            Self::Null => ValueType::Null,
            Self::Text(_) => ValueType::Text,
            Self::Integer(_) => ValueType::Integer,
            Self::FixedDecimal { scale, .. } => ValueType::FixedDecimal { scale: *scale },
            Self::Boolean(_) => ValueType::Boolean,
            Self::Date(_) => ValueType::Date,
            Self::DateTime(_) => ValueType::DateTime,
            Self::Duration(_) => ValueType::Duration,
            Self::Enum(_) => ValueType::Enum,
        }
    }

    fn from_field(
        value: &FieldValue,
        field_type: &FieldType,
    ) -> Result<Self, QueryEvaluationError> {
        Ok(match (value, field_type) {
            (FieldValue::Null, _) => Self::Null,
            (FieldValue::Text(v), FieldType::Text) => Self::Text(v.clone()),
            (FieldValue::Integer(v), FieldType::Integer) => Self::Integer(*v),
            (FieldValue::FixedDecimal(v), FieldType::FixedDecimal { scale }) => {
                Self::FixedDecimal {
                    representation: *v,
                    scale: *scale,
                }
            }
            (FieldValue::Boolean(v), FieldType::Boolean) => Self::Boolean(*v),
            (FieldValue::Date(v), FieldType::Date) => Self::Date(*v),
            (FieldValue::DateTime(v), FieldType::DateTime) => Self::DateTime(*v),
            (FieldValue::Duration(v), FieldType::Duration) => Self::Duration(*v),
            (FieldValue::Enum(v), FieldType::Enum) => Self::Enum(*v),
            _ => {
                return Err(QueryEvaluationError::InvalidRecord(
                    "projected value does not match schema".into(),
                ));
            }
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub enum FieldReference {
    Source(FieldId),
    Computed(ComputedFieldId),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArithmeticOperator {
    Add,
    Subtract,
    Multiply,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComparisonOperator {
    Equal,
    NotEqual,
    GreaterThan,
    GreaterThanOrEqual,
    LessThan,
    LessThanOrEqual,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BooleanOperator {
    And,
    Or,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RoundingPolicy {
    RejectInexact,
    HalfEven,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CurrentBoundary {
    Day,
    Week,
    Month,
    Year,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Expression {
    Constant {
        value: TypedValue,
    },
    Field {
        field: FieldReference,
    },
    Arithmetic {
        operator: ArithmeticOperator,
        left: Box<Expression>,
        right: Box<Expression>,
    },
    Divide {
        left: Box<Expression>,
        right: Box<Expression>,
        output_scale: u8,
        rounding: RoundingPolicy,
    },
    Compare {
        operator: ComparisonOperator,
        left: Box<Expression>,
        right: Box<Expression>,
    },
    Boolean {
        operator: BooleanOperator,
        left: Box<Expression>,
        right: Box<Expression>,
    },
    Not {
        expression: Box<Expression>,
    },
    IsNull {
        expression: Box<Expression>,
    },
    IsNotNull {
        expression: Box<Expression>,
    },
    Abs {
        expression: Box<Expression>,
    },
    StartOfCurrent {
        boundary: CurrentBoundary,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct VersionedExpression {
    pub version: u32,
    pub body: serde_json::Value,
}

impl VersionedExpression {
    pub fn new(expression: Expression) -> Self {
        Self {
            version: EXPRESSION_VERSION,
            body: serde_json::to_value(expression).expect("Expression is serializable"),
        }
    }
    pub fn expression(&self) -> Result<Expression, QueryValidationError> {
        if self.version != EXPRESSION_VERSION {
            return Err(QueryValidationError::new(
                "version",
                format!("unsupported expression version {}", self.version),
            ));
        }
        serde_json::from_value(self.body.clone())
            .map_err(|error| QueryValidationError::new("expression", error.to_string()))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WeekStart {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

impl WeekStart {
    fn weekday(self) -> Weekday {
        match self {
            Self::Monday => Weekday::Mon,
            Self::Tuesday => Weekday::Tue,
            Self::Wednesday => Weekday::Wed,
            Self::Thursday => Weekday::Thu,
            Self::Friday => Weekday::Fri,
            Self::Saturday => Weekday::Sat,
            Self::Sunday => Weekday::Sun,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CalendarPolicy {
    pub timezone: String,
    pub week_start: WeekStart,
}

impl Default for CalendarPolicy {
    fn default() -> Self {
        Self {
            timezone: "UTC".into(),
            week_start: WeekStart::Monday,
        }
    }
}

impl CalendarPolicy {
    fn timezone(&self) -> Result<Tz, QueryValidationError> {
        self.timezone.parse().map_err(|_| {
            QueryValidationError::new("calendar.timezone", "must be a supported IANA timezone")
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SortDirection {
    Ascending,
    Descending,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NullOrder {
    First,
    Last,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SortClause {
    pub expression: Expression,
    pub direction: SortDirection,
    pub null_order: NullOrder,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BucketPeriod {
    Day,
    Week,
    Month,
    Year,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Grouping {
    pub expression: Expression,
    pub period: BucketPeriod,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Aggregation {
    Count,
    Sum {
        expression: Expression,
    },
    Average {
        expression: Expression,
        output_scale: u8,
        rounding: RoundingPolicy,
    },
    Min {
        expression: Expression,
    },
    Max {
        expression: Expression,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum QueryShape {
    Scalar {
        aggregation: Aggregation,
    },
    Series {
        x: Expression,
        y: Expression,
    },
    CategorySeries {
        category: Expression,
        aggregation: Aggregation,
    },
    RecordSet {
        fields: Vec<FieldReference>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CollectionQuery {
    pub collection_id: CollectionSchemaId,
    pub filter: Option<Expression>,
    pub grouping: Option<Grouping>,
    pub shape: QueryShape,
    pub sorting: Vec<SortClause>,
    pub limit: Option<u32>,
    pub calendar: CalendarPolicy,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct VersionedCollectionQuery {
    pub version: u32,
    pub body: serde_json::Value,
}

impl VersionedCollectionQuery {
    pub fn new(query: CollectionQuery) -> Self {
        Self {
            version: QUERY_VERSION,
            body: serde_json::to_value(query).expect("CollectionQuery is serializable"),
        }
    }
    pub fn query(&self) -> Result<CollectionQuery, QueryValidationError> {
        if self.version != QUERY_VERSION {
            return Err(QueryValidationError::new(
                "version",
                format!("unsupported query version {}", self.version),
            ));
        }
        serde_json::from_value(self.body.clone())
            .map_err(|error| QueryValidationError::new("query", error.to_string()))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ComputedFieldDefinition {
    pub id: ComputedFieldId,
    pub collection_id: CollectionSchemaId,
    pub name: String,
    pub declared_type: ValueType,
    pub nullable: bool,
    pub expression: VersionedExpression,
    pub order: i64,
    pub deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct QueryDefinition {
    pub id: QueryId,
    pub collection_id: CollectionSchemaId,
    pub name: String,
    pub query: VersionedCollectionQuery,
    pub order: i64,
    pub deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InferredType {
    pub value_type: ValueType,
    pub nullable: bool,
}

#[derive(Clone, Debug, Error, Eq, PartialEq, Serialize, Deserialize)]
#[error("{path}: {message}")]
pub struct QueryValidationError {
    pub path: String,
    pub message: String,
}
impl QueryValidationError {
    pub fn new(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "message", rename_all = "snake_case")]
pub enum QueryEvaluationError {
    #[error("numeric overflow")]
    Overflow,
    #[error("division by zero")]
    DivisionByZero,
    #[error("inexact result rejected")]
    Inexact,
    #[error("invalid definition: {0}")]
    InvalidDefinition(String),
    #[error("invalid record: {0}")]
    InvalidRecord(String),
    #[error("invalid calendar value: {0}")]
    Calendar(String),
}

pub struct TypeEnvironment<'a> {
    pub schema: &'a CollectionSchema,
    pub computed: &'a [ComputedFieldDefinition],
}

impl TypeEnvironment<'_> {
    fn resolve(
        &self,
        reference: &FieldReference,
        path: &str,
        computed_allowed: bool,
    ) -> Result<InferredType, QueryValidationError> {
        match reference {
            FieldReference::Source(id) => {
                let field = self
                    .schema
                    .fields
                    .iter()
                    .find(|field| field.id == *id && !field.deleted)
                    .ok_or_else(|| {
                        QueryValidationError::new(path, "source field was not found or is removed")
                    })?;
                Ok(InferredType {
                    value_type: (&field.field_type).into(),
                    nullable: !field.required,
                })
            }
            FieldReference::Computed(id) if computed_allowed => {
                let field = self
                    .computed
                    .iter()
                    .find(|field| field.id == *id && !field.deleted)
                    .ok_or_else(|| {
                        QueryValidationError::new(
                            path,
                            "computed field was not found or is removed",
                        )
                    })?;
                Ok(InferredType {
                    value_type: field.declared_type.clone(),
                    nullable: field.nullable,
                })
            }
            FieldReference::Computed(_) => Err(QueryValidationError::new(
                path,
                "computed fields may reference source fields only",
            )),
        }
    }
}

pub fn infer_expression(
    expression: &Expression,
    env: &TypeEnvironment<'_>,
    computed_allowed: bool,
) -> Result<InferredType, QueryValidationError> {
    infer_at(expression, env, computed_allowed, "$")
}

fn infer_at(
    expression: &Expression,
    env: &TypeEnvironment<'_>,
    computed_allowed: bool,
    path: &str,
) -> Result<InferredType, QueryValidationError> {
    let child = |suffix: &str| format!("{path}.{suffix}");
    match expression {
        Expression::Constant { value } => Ok(InferredType {
            value_type: value.value_type(),
            nullable: matches!(value, TypedValue::Null),
        }),
        Expression::Field { field } => env.resolve(field, path, computed_allowed),
        Expression::Arithmetic {
            operator,
            left,
            right,
        } => {
            let left = infer_at(left, env, computed_allowed, &child("left"))?;
            let right = infer_at(right, env, computed_allowed, &child("right"))?;
            let value_type = match (&left.value_type, &right.value_type, operator) {
                (ValueType::Integer, ValueType::Integer, _) => ValueType::Integer,
                (
                    ValueType::FixedDecimal { scale: a },
                    ValueType::FixedDecimal { scale: b },
                    ArithmeticOperator::Add | ArithmeticOperator::Subtract,
                ) if a == b => ValueType::FixedDecimal { scale: *a },
                (
                    ValueType::FixedDecimal { scale: a },
                    ValueType::FixedDecimal { scale: b },
                    ArithmeticOperator::Multiply,
                ) => ValueType::FixedDecimal {
                    scale: a
                        .checked_add(*b)
                        .filter(|scale| *scale <= 18)
                        .ok_or_else(|| {
                            QueryValidationError::new(path, "decimal result scale exceeds 18")
                        })?,
                },
                (ValueType::DateTime, ValueType::DateTime, ArithmeticOperator::Subtract)
                | (ValueType::Date, ValueType::Date, ArithmeticOperator::Subtract) => {
                    ValueType::Duration
                }
                _ => {
                    return Err(QueryValidationError::new(
                        path,
                        "arithmetic operands are incompatible",
                    ));
                }
            };
            Ok(InferredType {
                value_type,
                nullable: left.nullable || right.nullable,
            })
        }
        Expression::Divide {
            left,
            right,
            output_scale,
            ..
        } => {
            if *output_scale > 18 {
                return Err(QueryValidationError::new(
                    path,
                    "division output scale exceeds 18",
                ));
            }
            let left = infer_at(left, env, computed_allowed, &child("left"))?;
            let right = infer_at(right, env, computed_allowed, &child("right"))?;
            if !is_numeric(&left.value_type) || !is_numeric(&right.value_type) {
                return Err(QueryValidationError::new(
                    path,
                    "division operands must be numeric",
                ));
            }
            Ok(InferredType {
                value_type: ValueType::FixedDecimal {
                    scale: *output_scale,
                },
                nullable: left.nullable || right.nullable,
            })
        }
        Expression::Compare { left, right, .. } => {
            let left = infer_at(left, env, computed_allowed, &child("left"))?;
            let right = infer_at(right, env, computed_allowed, &child("right"))?;
            if left.value_type != ValueType::Null
                && right.value_type != ValueType::Null
                && left.value_type != right.value_type
            {
                return Err(QueryValidationError::new(
                    path,
                    "comparison operands are incompatible",
                ));
            }
            Ok(InferredType {
                value_type: ValueType::Boolean,
                nullable: left.nullable
                    || right.nullable
                    || left.value_type == ValueType::Null
                    || right.value_type == ValueType::Null,
            })
        }
        Expression::Boolean { left, right, .. } => {
            let left = infer_at(left, env, computed_allowed, &child("left"))?;
            let right = infer_at(right, env, computed_allowed, &child("right"))?;
            if left.value_type != ValueType::Boolean || right.value_type != ValueType::Boolean {
                return Err(QueryValidationError::new(
                    path,
                    "boolean operands must be Boolean",
                ));
            }
            Ok(InferredType {
                value_type: ValueType::Boolean,
                nullable: left.nullable || right.nullable,
            })
        }
        Expression::Not { expression } => {
            let inner = infer_at(expression, env, computed_allowed, &child("expression"))?;
            if inner.value_type != ValueType::Boolean {
                return Err(QueryValidationError::new(
                    path,
                    "Not operand must be Boolean",
                ));
            }
            Ok(inner)
        }
        Expression::IsNull { expression } | Expression::IsNotNull { expression } => {
            infer_at(expression, env, computed_allowed, &child("expression"))?;
            Ok(InferredType {
                value_type: ValueType::Boolean,
                nullable: false,
            })
        }
        Expression::Abs { expression } => {
            let inner = infer_at(expression, env, computed_allowed, &child("expression"))?;
            if !is_numeric(&inner.value_type) && inner.value_type != ValueType::Duration {
                return Err(QueryValidationError::new(
                    path,
                    "Abs operand must be numeric or Duration",
                ));
            }
            Ok(inner)
        }
        Expression::StartOfCurrent { .. } if computed_allowed => Ok(InferredType {
            value_type: ValueType::DateTime,
            nullable: false,
        }),
        Expression::StartOfCurrent { .. } => Err(QueryValidationError::new(
            path,
            "contextual time is not allowed in computed fields",
        )),
    }
}

fn is_numeric(value: &ValueType) -> bool {
    matches!(value, ValueType::Integer | ValueType::FixedDecimal { .. })
}

pub fn validate_computed_field(
    definition: &ComputedFieldDefinition,
    schema: &CollectionSchema,
) -> Result<(), QueryValidationError> {
    if definition.collection_id != schema.id {
        return Err(QueryValidationError::new(
            "collection_id",
            "does not match schema",
        ));
    }
    validate_name(&definition.name, "name")?;
    let expression = definition.expression.expression()?;
    let inferred = infer_expression(
        &expression,
        &TypeEnvironment {
            schema,
            computed: &[],
        },
        false,
    )?;
    if inferred.value_type != definition.declared_type {
        return Err(QueryValidationError::new(
            "declared_type",
            "does not match inferred expression type",
        ));
    }
    if inferred.nullable != definition.nullable {
        return Err(QueryValidationError::new(
            "nullable",
            "does not match inferred expression nullability",
        ));
    }
    Ok(())
}

pub fn validate_query(
    query: &CollectionQuery,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
) -> Result<(), QueryValidationError> {
    if query.collection_id != schema.id {
        return Err(QueryValidationError::new(
            "collection_id",
            "does not match schema",
        ));
    }
    query.calendar.timezone()?;
    if let Some(limit) = query.limit
        && !(1..=MAX_QUERY_LIMIT).contains(&limit)
    {
        return Err(QueryValidationError::new(
            "limit",
            format!("must be between 1 and {MAX_QUERY_LIMIT}"),
        ));
    }
    if query.limit.is_some() && matches!(query.shape, QueryShape::Scalar { .. }) {
        return Err(QueryValidationError::new(
            "limit",
            "is not valid for a Scalar result",
        ));
    }
    let env = TypeEnvironment { schema, computed };
    if let Some(filter) = &query.filter {
        let inferred = infer_expression(filter, &env, true)?;
        if inferred.value_type != ValueType::Boolean {
            return Err(QueryValidationError::new("filter", "must produce Boolean"));
        }
    }
    if let Some(grouping) = &query.grouping {
        let inferred = infer_expression(&grouping.expression, &env, true)?;
        if !matches!(inferred.value_type, ValueType::Date | ValueType::DateTime) {
            return Err(QueryValidationError::new(
                "grouping",
                "requires Date or DateTime",
            ));
        }
    }
    for (index, sort) in query.sorting.iter().enumerate() {
        let inferred = infer_expression(&sort.expression, &env, true)?;
        if matches!(inferred.value_type, ValueType::Boolean | ValueType::Null) {
            return Err(QueryValidationError::new(
                format!("sorting[{index}]"),
                "type is not orderable",
            ));
        }
    }
    match &query.shape {
        QueryShape::Scalar { aggregation } | QueryShape::CategorySeries { aggregation, .. } => {
            validate_aggregation(aggregation, &env)?
        }
        QueryShape::Series { x, y } => {
            infer_expression(x, &env, true)?;
            infer_expression(y, &env, true)?;
        }
        QueryShape::RecordSet { fields } => {
            for (index, field) in fields.iter().enumerate() {
                env.resolve(field, &format!("shape.fields[{index}]"), true)?;
            }
        }
    }
    if let QueryShape::CategorySeries { category, .. } = &query.shape {
        infer_expression(category, &env, true)?;
    }
    Ok(())
}

fn validate_aggregation(
    aggregation: &Aggregation,
    env: &TypeEnvironment<'_>,
) -> Result<(), QueryValidationError> {
    let (expression, numeric) = match aggregation {
        Aggregation::Count => return Ok(()),
        Aggregation::Sum { expression } | Aggregation::Average { expression, .. } => {
            (expression, true)
        }
        Aggregation::Min { expression } | Aggregation::Max { expression } => (expression, false),
    };
    let inferred = infer_expression(expression, env, true)?;
    if numeric && !is_numeric(&inferred.value_type) {
        return Err(QueryValidationError::new(
            "aggregation",
            "requires a numeric expression",
        ));
    }
    if let Aggregation::Average { output_scale, .. } = aggregation
        && *output_scale > 18
    {
        return Err(QueryValidationError::new(
            "aggregation.output_scale",
            "must be at most 18",
        ));
    }
    Ok(())
}

fn validate_name(value: &str, path: &str) -> Result<(), QueryValidationError> {
    if !(1..=120).contains(&value.trim().chars().count()) {
        Err(QueryValidationError::new(
            path,
            "must contain 1 to 120 non-padding characters",
        ))
    } else {
        Ok(())
    }
}

pub struct EvaluationContext<'a> {
    pub schema: &'a CollectionSchema,
    pub computed_definitions: &'a [ComputedFieldDefinition],
    pub now_utc_ms: i64,
    pub calendar: &'a CalendarPolicy,
}

pub fn evaluate_expression(
    expression: &Expression,
    record: &GenericRecord,
    context: &EvaluationContext<'_>,
) -> Result<TypedValue, QueryEvaluationError> {
    match expression {
        Expression::Constant { value } => Ok(value.clone()),
        Expression::Field {
            field: FieldReference::Source(id),
        } => {
            let definition = context
                .schema
                .fields
                .iter()
                .find(|field| field.id == *id && !field.deleted)
                .ok_or_else(|| {
                    QueryEvaluationError::InvalidDefinition("source field unavailable".into())
                })?;
            match record.values.get(id) {
                Some(value) => TypedValue::from_field(value, &definition.field_type),
                None => Ok(TypedValue::Null),
            }
        }
        Expression::Field {
            field: FieldReference::Computed(id),
        } => {
            let definition = context
                .computed_definitions
                .iter()
                .find(|field| field.id == *id && !field.deleted)
                .ok_or_else(|| {
                    QueryEvaluationError::InvalidDefinition("computed field unavailable".into())
                })?;
            validate_computed_field(definition, context.schema)
                .map_err(|error| QueryEvaluationError::InvalidDefinition(error.to_string()))?;
            evaluate_expression(
                &definition
                    .expression
                    .expression()
                    .map_err(|error| QueryEvaluationError::InvalidDefinition(error.to_string()))?,
                record,
                context,
            )
        }
        Expression::Arithmetic {
            operator,
            left,
            right,
        } => {
            let left = evaluate_expression(left, record, context)?;
            let right = evaluate_expression(right, record, context)?;
            arithmetic(*operator, left, right)
        }
        Expression::Divide {
            left,
            right,
            output_scale,
            rounding,
        } => divide(
            evaluate_expression(left, record, context)?,
            evaluate_expression(right, record, context)?,
            *output_scale,
            *rounding,
        ),
        Expression::Compare {
            operator,
            left,
            right,
        } => compare(
            *operator,
            evaluate_expression(left, record, context)?,
            evaluate_expression(right, record, context)?,
        ),
        Expression::Boolean {
            operator,
            left,
            right,
        } => boolean(
            *operator,
            evaluate_expression(left, record, context)?,
            evaluate_expression(right, record, context)?,
        ),
        Expression::Not { expression } => match evaluate_expression(expression, record, context)? {
            TypedValue::Null => Ok(TypedValue::Null),
            TypedValue::Boolean(value) => Ok(TypedValue::Boolean(!value)),
            _ => Err(QueryEvaluationError::InvalidDefinition(
                "Not operand is not Boolean".into(),
            )),
        },
        Expression::IsNull { expression } => Ok(TypedValue::Boolean(matches!(
            evaluate_expression(expression, record, context)?,
            TypedValue::Null
        ))),
        Expression::IsNotNull { expression } => Ok(TypedValue::Boolean(!matches!(
            evaluate_expression(expression, record, context)?,
            TypedValue::Null
        ))),
        Expression::Abs { expression } => abs(evaluate_expression(expression, record, context)?),
        Expression::StartOfCurrent { boundary } => Ok(TypedValue::DateTime(current_boundary(
            context.now_utc_ms,
            *boundary,
            context.calendar,
        )?)),
    }
}

fn arithmetic(
    operator: ArithmeticOperator,
    left: TypedValue,
    right: TypedValue,
) -> Result<TypedValue, QueryEvaluationError> {
    if matches!(left, TypedValue::Null) || matches!(right, TypedValue::Null) {
        return Ok(TypedValue::Null);
    }
    let checked = |a: i64, b: i64| {
        match operator {
            ArithmeticOperator::Add => a.checked_add(b),
            ArithmeticOperator::Subtract => a.checked_sub(b),
            ArithmeticOperator::Multiply => a.checked_mul(b),
        }
        .ok_or(QueryEvaluationError::Overflow)
    };
    match (left, right) {
        (TypedValue::Integer(a), TypedValue::Integer(b)) => Ok(TypedValue::Integer(checked(a, b)?)),
        (
            TypedValue::FixedDecimal {
                representation: a,
                scale: sa,
            },
            TypedValue::FixedDecimal {
                representation: b,
                scale: sb,
            },
        ) => {
            let scale = match operator {
                ArithmeticOperator::Add | ArithmeticOperator::Subtract if sa == sb => sa,
                ArithmeticOperator::Multiply => sa
                    .checked_add(sb)
                    .filter(|scale| *scale <= 18)
                    .ok_or(QueryEvaluationError::Overflow)?,
                _ => {
                    return Err(QueryEvaluationError::InvalidDefinition(
                        "incompatible decimal scales".into(),
                    ));
                }
            };
            Ok(TypedValue::FixedDecimal {
                representation: checked(a, b)?,
                scale,
            })
        }
        (TypedValue::DateTime(a), TypedValue::DateTime(b))
            if operator == ArithmeticOperator::Subtract =>
        {
            Ok(TypedValue::Duration(
                a.checked_sub(b).ok_or(QueryEvaluationError::Overflow)?,
            ))
        }
        (TypedValue::Date(a), TypedValue::Date(b)) if operator == ArithmeticOperator::Subtract => {
            Ok(TypedValue::Duration(
                a.checked_sub(b)
                    .and_then(|days| days.checked_mul(86_400_000))
                    .ok_or(QueryEvaluationError::Overflow)?,
            ))
        }
        _ => Err(QueryEvaluationError::InvalidDefinition(
            "incompatible arithmetic operands".into(),
        )),
    }
}

fn numeric_parts(value: TypedValue) -> Result<(i128, u8), QueryEvaluationError> {
    match value {
        TypedValue::Integer(value) => Ok((i128::from(value), 0)),
        TypedValue::FixedDecimal {
            representation,
            scale,
        } => Ok((i128::from(representation), scale)),
        _ => Err(QueryEvaluationError::InvalidDefinition(
            "numeric value required".into(),
        )),
    }
}

fn divide(
    left: TypedValue,
    right: TypedValue,
    output_scale: u8,
    rounding: RoundingPolicy,
) -> Result<TypedValue, QueryEvaluationError> {
    if matches!(left, TypedValue::Null) || matches!(right, TypedValue::Null) {
        return Ok(TypedValue::Null);
    }
    let (left, left_scale) = numeric_parts(left)?;
    let (right, right_scale) = numeric_parts(right)?;
    if right == 0 {
        return Err(QueryEvaluationError::DivisionByZero);
    }
    let exponent = i32::from(output_scale) + i32::from(right_scale) - i32::from(left_scale);
    let (numerator, denominator) = if exponent >= 0 {
        (
            left.checked_mul(pow10(exponent as u8)?)
                .ok_or(QueryEvaluationError::Overflow)?,
            right,
        )
    } else {
        (
            left,
            right
                .checked_mul(pow10((-exponent) as u8)?)
                .ok_or(QueryEvaluationError::Overflow)?,
        )
    };
    let result = rounded_quotient(numerator, denominator, rounding)?;
    Ok(TypedValue::FixedDecimal {
        representation: i64::try_from(result).map_err(|_| QueryEvaluationError::Overflow)?,
        scale: output_scale,
    })
}

fn pow10(scale: u8) -> Result<i128, QueryEvaluationError> {
    10_i128
        .checked_pow(u32::from(scale))
        .ok_or(QueryEvaluationError::Overflow)
}

fn rounded_quotient(
    numerator: i128,
    denominator: i128,
    policy: RoundingPolicy,
) -> Result<i128, QueryEvaluationError> {
    let quotient = numerator
        .checked_div(denominator)
        .ok_or(QueryEvaluationError::Overflow)?;
    let remainder = numerator
        .checked_rem(denominator)
        .ok_or(QueryEvaluationError::Overflow)?;
    if remainder == 0 {
        return Ok(quotient);
    }
    if policy == RoundingPolicy::RejectInexact {
        return Err(QueryEvaluationError::Inexact);
    }
    let twice = remainder
        .abs()
        .checked_mul(2)
        .ok_or(QueryEvaluationError::Overflow)?;
    let divisor = denominator.abs();
    if twice < divisor || (twice == divisor && quotient % 2 == 0) {
        Ok(quotient)
    } else {
        quotient
            .checked_add(if numerator.signum() == denominator.signum() {
                1
            } else {
                -1
            })
            .ok_or(QueryEvaluationError::Overflow)
    }
}

fn compare(
    operator: ComparisonOperator,
    left: TypedValue,
    right: TypedValue,
) -> Result<TypedValue, QueryEvaluationError> {
    if matches!(left, TypedValue::Null) || matches!(right, TypedValue::Null) {
        return Ok(TypedValue::Null);
    }
    let ordering = typed_cmp(&left, &right).ok_or_else(|| {
        QueryEvaluationError::InvalidDefinition("incompatible comparison operands".into())
    })?;
    Ok(TypedValue::Boolean(match operator {
        ComparisonOperator::Equal => ordering == Ordering::Equal,
        ComparisonOperator::NotEqual => ordering != Ordering::Equal,
        ComparisonOperator::GreaterThan => ordering == Ordering::Greater,
        ComparisonOperator::GreaterThanOrEqual => ordering != Ordering::Less,
        ComparisonOperator::LessThan => ordering == Ordering::Less,
        ComparisonOperator::LessThanOrEqual => ordering != Ordering::Greater,
    }))
}

fn typed_cmp(left: &TypedValue, right: &TypedValue) -> Option<Ordering> {
    match (left, right) {
        (TypedValue::Text(a), TypedValue::Text(b)) => Some(a.cmp(b)),
        (TypedValue::Integer(a), TypedValue::Integer(b)) => Some(a.cmp(b)),
        (
            TypedValue::FixedDecimal {
                representation: a,
                scale: sa,
            },
            TypedValue::FixedDecimal {
                representation: b,
                scale: sb,
            },
        ) if sa == sb => Some(a.cmp(b)),
        (TypedValue::Boolean(a), TypedValue::Boolean(b)) => Some(a.cmp(b)),
        (TypedValue::Date(a), TypedValue::Date(b)) => Some(a.cmp(b)),
        (TypedValue::DateTime(a), TypedValue::DateTime(b)) => Some(a.cmp(b)),
        (TypedValue::Duration(a), TypedValue::Duration(b)) => Some(a.cmp(b)),
        (TypedValue::Enum(a), TypedValue::Enum(b)) => Some(a.cmp(b)),
        _ => None,
    }
}

fn boolean(
    operator: BooleanOperator,
    left: TypedValue,
    right: TypedValue,
) -> Result<TypedValue, QueryEvaluationError> {
    let left = match left {
        TypedValue::Boolean(v) => Some(v),
        TypedValue::Null => None,
        _ => {
            return Err(QueryEvaluationError::InvalidDefinition(
                "boolean value required".into(),
            ));
        }
    };
    let right = match right {
        TypedValue::Boolean(v) => Some(v),
        TypedValue::Null => None,
        _ => {
            return Err(QueryEvaluationError::InvalidDefinition(
                "boolean value required".into(),
            ));
        }
    };
    Ok(match (operator, left, right) {
        (BooleanOperator::And, Some(false), _) | (BooleanOperator::And, _, Some(false)) => {
            TypedValue::Boolean(false)
        }
        (BooleanOperator::And, Some(true), Some(true)) => TypedValue::Boolean(true),
        (BooleanOperator::Or, Some(true), _) | (BooleanOperator::Or, _, Some(true)) => {
            TypedValue::Boolean(true)
        }
        (BooleanOperator::Or, Some(false), Some(false)) => TypedValue::Boolean(false),
        _ => TypedValue::Null,
    })
}

fn abs(value: TypedValue) -> Result<TypedValue, QueryEvaluationError> {
    match value {
        TypedValue::Null => Ok(TypedValue::Null),
        TypedValue::Integer(v) => Ok(TypedValue::Integer(
            v.checked_abs().ok_or(QueryEvaluationError::Overflow)?,
        )),
        TypedValue::FixedDecimal {
            representation,
            scale,
        } => Ok(TypedValue::FixedDecimal {
            representation: representation
                .checked_abs()
                .ok_or(QueryEvaluationError::Overflow)?,
            scale,
        }),
        TypedValue::Duration(v) => Ok(TypedValue::Duration(
            v.checked_abs().ok_or(QueryEvaluationError::Overflow)?,
        )),
        _ => Err(QueryEvaluationError::InvalidDefinition(
            "Abs value is not numeric".into(),
        )),
    }
}

fn utc_datetime(milliseconds: i64) -> Result<DateTime<Utc>, QueryEvaluationError> {
    Utc.timestamp_millis_opt(milliseconds)
        .single()
        .ok_or_else(|| QueryEvaluationError::Calendar("timestamp is out of range".into()))
}

fn current_boundary(
    now_ms: i64,
    boundary: CurrentBoundary,
    calendar: &CalendarPolicy,
) -> Result<i64, QueryEvaluationError> {
    let timezone: Tz = calendar
        .timezone
        .parse()
        .map_err(|_| QueryEvaluationError::Calendar("unsupported IANA timezone".into()))?;
    let local = utc_datetime(now_ms)?.with_timezone(&timezone);
    let date = local.date_naive();
    let date = match boundary {
        CurrentBoundary::Day => date,
        CurrentBoundary::Week => date
            .checked_sub_signed(Duration::days(i64::from(
                (7 + date.weekday().num_days_from_monday() as i32
                    - calendar.week_start.weekday().num_days_from_monday() as i32)
                    % 7,
            )))
            .ok_or(QueryEvaluationError::Overflow)?,
        CurrentBoundary::Month => NaiveDate::from_ymd_opt(date.year(), date.month(), 1)
            .ok_or_else(|| QueryEvaluationError::Calendar("invalid month".into()))?,
        CurrentBoundary::Year => NaiveDate::from_ymd_opt(date.year(), 1, 1)
            .ok_or_else(|| QueryEvaluationError::Calendar("invalid year".into()))?,
    };
    timezone
        .from_local_datetime(
            &date
                .and_hms_opt(0, 0, 0)
                .ok_or_else(|| QueryEvaluationError::Calendar("invalid boundary".into()))?,
        )
        .earliest()
        .ok_or_else(|| QueryEvaluationError::Calendar("local boundary does not exist".into()))
        .map(|value| value.timestamp_millis())
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SeriesPoint {
    pub x: TypedValue,
    pub y: TypedValue,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CategoryPoint {
    pub category: TypedValue,
    pub value: TypedValue,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ResultRecord {
    pub id: RecordId,
    pub values: Vec<(FieldReference, TypedValue)>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum QueryResult {
    Scalar {
        value: TypedValue,
        value_type: ValueType,
    },
    Series {
        points: Vec<SeriesPoint>,
        x_type: ValueType,
        y_type: ValueType,
    },
    CategorySeries {
        points: Vec<CategoryPoint>,
        category_type: ValueType,
        value_type: ValueType,
    },
    RecordSet {
        records: Vec<ResultRecord>,
    },
}

pub fn execute_query(
    query: &CollectionQuery,
    schema: &CollectionSchema,
    computed: &[ComputedFieldDefinition],
    records: &[GenericRecord],
    now_utc_ms: i64,
) -> Result<QueryResult, QueryEvaluationError> {
    validate_query(query, schema, computed)
        .map_err(|error| QueryEvaluationError::InvalidDefinition(error.to_string()))?;
    let context = EvaluationContext {
        schema,
        computed_definitions: computed,
        now_utc_ms,
        calendar: &query.calendar,
    };
    let mut selected = Vec::new();
    for record in records
        .iter()
        .filter(|record| !record.deleted && record.collection_id == schema.id)
    {
        let retain = match &query.filter {
            None => true,
            Some(filter) => matches!(
                evaluate_expression(filter, record, &context)?,
                TypedValue::Boolean(true)
            ),
        };
        if retain {
            selected.push(record);
        }
    }
    selected.sort_by(|a, b| {
        compare_records(a, b, &query.sorting, &context).unwrap_or_else(|_| a.id.cmp(&b.id))
    });
    match &query.shape {
        QueryShape::Scalar { aggregation } => {
            let value = aggregate(aggregation, &selected, &context)?;
            let value_type = value.value_type();
            Ok(QueryResult::Scalar { value, value_type })
        }
        QueryShape::Series { x, y } => {
            if let Some(limit) = query.limit {
                selected.truncate(limit as usize);
            }
            let points = selected
                .iter()
                .map(|record| {
                    Ok(SeriesPoint {
                        x: evaluate_expression(x, record, &context)?,
                        y: evaluate_expression(y, record, &context)?,
                    })
                })
                .collect::<Result<Vec<_>, QueryEvaluationError>>()?;
            let env = TypeEnvironment { schema, computed };
            let x_type = infer_expression(x, &env, true)
                .map_err(|e| QueryEvaluationError::InvalidDefinition(e.to_string()))?
                .value_type;
            let y_type = infer_expression(y, &env, true)
                .map_err(|e| QueryEvaluationError::InvalidDefinition(e.to_string()))?
                .value_type;
            Ok(QueryResult::Series {
                points,
                x_type,
                y_type,
            })
        }
        QueryShape::RecordSet { fields } => {
            if let Some(limit) = query.limit {
                selected.truncate(limit as usize);
            }
            let records = selected
                .iter()
                .map(|record| {
                    fields
                        .iter()
                        .map(|field| {
                            evaluate_expression(
                                &Expression::Field {
                                    field: field.clone(),
                                },
                                record,
                                &context,
                            )
                            .map(|value| (field.clone(), value))
                        })
                        .collect::<Result<Vec<_>, _>>()
                        .map(|values| ResultRecord {
                            id: record.id,
                            values,
                        })
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(QueryResult::RecordSet { records })
        }
        QueryShape::CategorySeries {
            category,
            aggregation,
        } => {
            let mut groups: Vec<(TypedValue, Vec<&GenericRecord>)> = Vec::new();
            for record in selected {
                let key = match &query.grouping {
                    Some(grouping) => bucket_value(
                        &evaluate_expression(&grouping.expression, record, &context)?,
                        grouping.period,
                        &query.calendar,
                    )?,
                    None => evaluate_expression(category, record, &context)?,
                };
                if let Some((_, rows)) = groups.iter_mut().find(|(candidate, _)| candidate == &key)
                {
                    rows.push(record);
                } else {
                    groups.push((key, vec![record]));
                }
            }
            groups.sort_by(|(a, _), (b, _)| null_cmp(a, b, NullOrder::Last));
            let mut points = groups
                .into_iter()
                .map(|(category, rows)| {
                    aggregate(aggregation, &rows, &context)
                        .map(|value| CategoryPoint { category, value })
                })
                .collect::<Result<Vec<_>, _>>()?;
            if let Some(limit) = query.limit {
                points.truncate(limit as usize);
            }
            let env = TypeEnvironment { schema, computed };
            let category_type = match &query.grouping {
                Some(grouping) => infer_expression(&grouping.expression, &env, true),
                None => infer_expression(category, &env, true),
            }
            .map_err(|e| QueryEvaluationError::InvalidDefinition(e.to_string()))?
            .value_type;
            let value_type = points
                .first()
                .map_or(ValueType::Null, |point| point.value.value_type());
            Ok(QueryResult::CategorySeries {
                points,
                category_type,
                value_type,
            })
        }
    }
}

fn compare_records(
    a: &GenericRecord,
    b: &GenericRecord,
    sorts: &[SortClause],
    context: &EvaluationContext<'_>,
) -> Result<Ordering, QueryEvaluationError> {
    for sort in sorts {
        let av = evaluate_expression(&sort.expression, a, context)?;
        let bv = evaluate_expression(&sort.expression, b, context)?;
        let order = match (&av, &bv) {
            (TypedValue::Null, _) | (_, TypedValue::Null) => null_cmp(&av, &bv, sort.null_order),
            _ => {
                let order = typed_cmp(&av, &bv).unwrap_or(Ordering::Equal);
                if sort.direction == SortDirection::Descending {
                    order.reverse()
                } else {
                    order
                }
            }
        };
        if order != Ordering::Equal {
            return Ok(order);
        }
    }
    Ok(a.id.cmp(&b.id))
}

fn null_cmp(a: &TypedValue, b: &TypedValue, null_order: NullOrder) -> Ordering {
    match (a, b) {
        (TypedValue::Null, TypedValue::Null) => Ordering::Equal,
        (TypedValue::Null, _) => {
            if null_order == NullOrder::First {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        }
        (_, TypedValue::Null) => {
            if null_order == NullOrder::First {
                Ordering::Greater
            } else {
                Ordering::Less
            }
        }
        _ => typed_cmp(a, b).unwrap_or(Ordering::Equal),
    }
}

fn aggregate(
    aggregation: &Aggregation,
    records: &[&GenericRecord],
    context: &EvaluationContext<'_>,
) -> Result<TypedValue, QueryEvaluationError> {
    if matches!(aggregation, Aggregation::Count) {
        return Ok(TypedValue::Integer(
            i64::try_from(records.len()).map_err(|_| QueryEvaluationError::Overflow)?,
        ));
    }
    let expression = match aggregation {
        Aggregation::Sum { expression }
        | Aggregation::Average { expression, .. }
        | Aggregation::Min { expression }
        | Aggregation::Max { expression } => expression,
        Aggregation::Count => unreachable!(),
    };
    let values = records
        .iter()
        .map(|record| evaluate_expression(expression, record, context))
        .filter_map(|result| match result {
            Ok(TypedValue::Null) => None,
            other => Some(other),
        })
        .collect::<Result<Vec<_>, _>>()?;
    if values.is_empty() {
        return Ok(TypedValue::Null);
    }
    match aggregation {
        Aggregation::Sum { .. } => sum_values(&values),
        Aggregation::Average {
            output_scale,
            rounding,
            ..
        } => {
            let sum = sum_values(&values)?;
            divide(
                sum,
                TypedValue::Integer(
                    i64::try_from(values.len()).map_err(|_| QueryEvaluationError::Overflow)?,
                ),
                *output_scale,
                *rounding,
            )
        }
        Aggregation::Min { .. } => values
            .into_iter()
            .min_by(|a, b| typed_cmp(a, b).unwrap_or(Ordering::Equal))
            .ok_or_else(|| QueryEvaluationError::InvalidRecord("empty aggregate".into())),
        Aggregation::Max { .. } => values
            .into_iter()
            .max_by(|a, b| typed_cmp(a, b).unwrap_or(Ordering::Equal))
            .ok_or_else(|| QueryEvaluationError::InvalidRecord("empty aggregate".into())),
        Aggregation::Count => unreachable!(),
    }
}

fn sum_values(values: &[TypedValue]) -> Result<TypedValue, QueryEvaluationError> {
    match &values[0] {
        TypedValue::Integer(_) => values
            .iter()
            .try_fold(TypedValue::Integer(0), |sum, value| {
                arithmetic(ArithmeticOperator::Add, sum, value.clone())
            }),
        TypedValue::FixedDecimal { scale, .. } => values.iter().try_fold(
            TypedValue::FixedDecimal {
                representation: 0,
                scale: *scale,
            },
            |sum, value| arithmetic(ArithmeticOperator::Add, sum, value.clone()),
        ),
        _ => Err(QueryEvaluationError::InvalidDefinition(
            "Sum requires numeric values".into(),
        )),
    }
}

pub fn bucket_value(
    value: &TypedValue,
    period: BucketPeriod,
    calendar: &CalendarPolicy,
) -> Result<TypedValue, QueryEvaluationError> {
    let timezone: Tz = calendar
        .timezone
        .parse()
        .map_err(|_| QueryEvaluationError::Calendar("unsupported IANA timezone".into()))?;
    let (date, date_only) = match value {
        TypedValue::Date(days) => (
            NaiveDate::from_ymd_opt(1970, 1, 1)
                .and_then(|epoch| epoch.checked_add_signed(Duration::days(*days)))
                .ok_or_else(|| QueryEvaluationError::Calendar("date out of range".into()))?,
            true,
        ),
        TypedValue::DateTime(ms) => (
            utc_datetime(*ms)?.with_timezone(&timezone).date_naive(),
            false,
        ),
        TypedValue::Null => return Ok(TypedValue::Null),
        _ => {
            return Err(QueryEvaluationError::InvalidDefinition(
                "bucket requires Date or DateTime".into(),
            ));
        }
    };
    let start = match period {
        BucketPeriod::Day => date,
        BucketPeriod::Week => date
            .checked_sub_signed(Duration::days(i64::from(
                (7 + date.weekday().num_days_from_monday() as i32
                    - calendar.week_start.weekday().num_days_from_monday() as i32)
                    % 7,
            )))
            .ok_or(QueryEvaluationError::Overflow)?,
        BucketPeriod::Month => NaiveDate::from_ymd_opt(date.year(), date.month(), 1)
            .ok_or_else(|| QueryEvaluationError::Calendar("invalid month".into()))?,
        BucketPeriod::Year => NaiveDate::from_ymd_opt(date.year(), 1, 1)
            .ok_or_else(|| QueryEvaluationError::Calendar("invalid year".into()))?,
    };
    if date_only {
        let epoch = NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid epoch");
        Ok(TypedValue::Date(
            start.signed_duration_since(epoch).num_days(),
        ))
    } else {
        timezone
            .from_local_datetime(&start.and_hms_opt(0, 0, 0).expect("valid midnight"))
            .earliest()
            .ok_or_else(|| {
                QueryEvaluationError::Calendar("local bucket boundary does not exist".into())
            })
            .map(|value| TypedValue::DateTime(value.timestamp_millis()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DisplayMetadata, FieldDefinition, ValidationMetadata};
    use std::collections::BTreeMap;

    fn schema() -> (CollectionSchema, FieldId, FieldId) {
        let integer = FieldId::new();
        let optional = FieldId::new();
        (
            CollectionSchema {
                id: CollectionSchemaId::new(),
                name: "Headaches".into(),
                description: String::new(),
                deleted: false,
                fields: vec![
                    FieldDefinition {
                        id: integer,
                        name: "intensity".into(),
                        field_type: FieldType::Integer,
                        required: true,
                        default: None,
                        validation: ValidationMetadata::default(),
                        display: DisplayMetadata::default(),
                        order: 0,
                        deleted: false,
                        enum_options: vec![],
                    },
                    FieldDefinition {
                        id: optional,
                        name: "ended".into(),
                        field_type: FieldType::DateTime,
                        required: false,
                        default: None,
                        validation: ValidationMetadata::default(),
                        display: DisplayMetadata::default(),
                        order: 1,
                        deleted: false,
                        enum_options: vec![],
                    },
                ],
            },
            integer,
            optional,
        )
    }

    #[test]
    fn ids_and_every_version_wrapper_round_trip_and_preserve_unknown_body() {
        let id = QueryId::new();
        assert_eq!(id.to_string().parse::<QueryId>().unwrap(), id);
        let computed = ComputedFieldId::new();
        assert_eq!(
            serde_json::from_str::<ComputedFieldId>(&serde_json::to_string(&computed).unwrap())
                .unwrap(),
            computed
        );
        let versioned = VersionedExpression::new(Expression::Abs {
            expression: Box::new(Expression::Constant {
                value: TypedValue::Integer(-2),
            }),
        });
        assert_eq!(
            serde_json::from_str::<VersionedExpression>(
                &serde_json::to_string(&versioned).unwrap()
            )
            .unwrap(),
            versioned
        );
        let unknown = VersionedExpression {
            version: 99,
            body: serde_json::json!({"future": [1, 2]}),
        };
        assert_eq!(
            serde_json::from_str::<VersionedExpression>(&serde_json::to_string(&unknown).unwrap())
                .unwrap(),
            unknown
        );
        assert!(
            unknown
                .expression()
                .unwrap_err()
                .message
                .contains("unsupported")
        );
    }

    #[test]
    fn every_ast_and_definition_variant_serializes_losslessly() {
        fn round_trip<T>(value: &T)
        where
            T: Serialize + for<'de> Deserialize<'de> + Eq + fmt::Debug,
        {
            let encoded = serde_json::to_string(value).unwrap();
            let decoded: T = serde_json::from_str(&encoded).unwrap();
            assert_eq!(&decoded, value);
        }
        let source = FieldReference::Source(FieldId::new());
        let field = Expression::Field {
            field: source.clone(),
        };
        let constant = Expression::Constant {
            value: TypedValue::Integer(2),
        };
        let expressions = vec![
            field.clone(),
            constant.clone(),
            Expression::Arithmetic {
                operator: ArithmeticOperator::Add,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Arithmetic {
                operator: ArithmeticOperator::Subtract,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Arithmetic {
                operator: ArithmeticOperator::Multiply,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Divide {
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
                output_scale: 2,
                rounding: RoundingPolicy::RejectInexact,
            },
            Expression::Divide {
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
                output_scale: 2,
                rounding: RoundingPolicy::HalfEven,
            },
            Expression::Compare {
                operator: ComparisonOperator::Equal,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Compare {
                operator: ComparisonOperator::NotEqual,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Compare {
                operator: ComparisonOperator::GreaterThan,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Compare {
                operator: ComparisonOperator::GreaterThanOrEqual,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Compare {
                operator: ComparisonOperator::LessThan,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Compare {
                operator: ComparisonOperator::LessThanOrEqual,
                left: Box::new(constant.clone()),
                right: Box::new(constant.clone()),
            },
            Expression::Boolean {
                operator: BooleanOperator::And,
                left: Box::new(Expression::Constant {
                    value: TypedValue::Boolean(true),
                }),
                right: Box::new(Expression::Constant {
                    value: TypedValue::Boolean(false),
                }),
            },
            Expression::Boolean {
                operator: BooleanOperator::Or,
                left: Box::new(Expression::Constant {
                    value: TypedValue::Boolean(true),
                }),
                right: Box::new(Expression::Constant {
                    value: TypedValue::Boolean(false),
                }),
            },
            Expression::Not {
                expression: Box::new(Expression::Constant {
                    value: TypedValue::Boolean(true),
                }),
            },
            Expression::IsNull {
                expression: Box::new(field.clone()),
            },
            Expression::IsNotNull {
                expression: Box::new(field.clone()),
            },
            Expression::Abs {
                expression: Box::new(constant.clone()),
            },
            Expression::StartOfCurrent {
                boundary: CurrentBoundary::Day,
            },
            Expression::StartOfCurrent {
                boundary: CurrentBoundary::Week,
            },
            Expression::StartOfCurrent {
                boundary: CurrentBoundary::Month,
            },
            Expression::StartOfCurrent {
                boundary: CurrentBoundary::Year,
            },
        ];
        for expression in expressions {
            round_trip(&VersionedExpression::new(expression));
        }
        for value in [
            TypedValue::Null,
            TypedValue::Text("x".into()),
            TypedValue::Integer(1),
            TypedValue::FixedDecimal {
                representation: 1,
                scale: 2,
            },
            TypedValue::Boolean(true),
            TypedValue::Date(1),
            TypedValue::DateTime(1),
            TypedValue::Duration(1),
            TypedValue::Enum(EnumOptionId::new()),
        ] {
            round_trip(&value);
        }
        let collection_id = CollectionSchemaId::new();
        let aggregations = vec![
            Aggregation::Count,
            Aggregation::Sum {
                expression: constant.clone(),
            },
            Aggregation::Average {
                expression: constant.clone(),
                output_scale: 2,
                rounding: RoundingPolicy::HalfEven,
            },
            Aggregation::Min {
                expression: constant.clone(),
            },
            Aggregation::Max {
                expression: constant.clone(),
            },
        ];
        for aggregation in aggregations {
            let query = CollectionQuery {
                collection_id,
                filter: None,
                grouping: Some(Grouping {
                    expression: Expression::Constant {
                        value: TypedValue::Date(0),
                    },
                    period: BucketPeriod::Month,
                }),
                shape: QueryShape::Scalar { aggregation },
                sorting: vec![SortClause {
                    expression: constant.clone(),
                    direction: SortDirection::Descending,
                    null_order: NullOrder::First,
                }],
                limit: None,
                calendar: CalendarPolicy {
                    timezone: "UTC".into(),
                    week_start: WeekStart::Sunday,
                },
            };
            round_trip(&VersionedCollectionQuery::new(query));
        }
        for shape in [
            QueryShape::Series {
                x: constant.clone(),
                y: constant.clone(),
            },
            QueryShape::CategorySeries {
                category: constant.clone(),
                aggregation: Aggregation::Count,
            },
            QueryShape::RecordSet {
                fields: vec![source],
            },
        ] {
            let query = VersionedCollectionQuery::new(CollectionQuery {
                collection_id,
                filter: None,
                grouping: None,
                shape,
                sorting: vec![],
                limit: Some(1),
                calendar: CalendarPolicy::default(),
            });
            round_trip(&query);
        }
        let unknown = VersionedCollectionQuery {
            version: 42,
            body: serde_json::json!({"future":true}),
        };
        round_trip(&unknown);
        assert!(unknown.query().is_err());
    }

    #[test]
    fn validation_has_stable_paths_and_rejects_invalid_nodes() {
        let (schema, integer, optional) = schema();
        let env = TypeEnvironment {
            schema: &schema,
            computed: &[],
        };
        let bad = Expression::Arithmetic {
            operator: ArithmeticOperator::Add,
            left: Box::new(Expression::Field {
                field: FieldReference::Source(optional),
            }),
            right: Box::new(Expression::Field {
                field: FieldReference::Source(integer),
            }),
        };
        assert_eq!(infer_expression(&bad, &env, true).unwrap_err().path, "$");
        let removed = FieldId::new();
        let error = infer_expression(
            &Expression::Field {
                field: FieldReference::Source(removed),
            },
            &env,
            true,
        )
        .unwrap_err();
        assert_eq!(error.path, "$");
        let contextual = ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id: schema.id,
            name: "Current".into(),
            declared_type: ValueType::DateTime,
            nullable: false,
            expression: VersionedExpression::new(Expression::StartOfCurrent {
                boundary: CurrentBoundary::Month,
            }),
            order: 0,
            deleted: false,
        };
        assert!(
            validate_computed_field(&contextual, &schema)
                .unwrap_err()
                .message
                .contains("contextual")
        );
    }

    #[test]
    fn invalid_operator_combinations_cover_all_field_type_families() {
        let kinds = [
            FieldType::Text,
            FieldType::Integer,
            FieldType::FixedDecimal { scale: 2 },
            FieldType::Boolean,
            FieldType::Date,
            FieldType::DateTime,
            FieldType::Duration,
            FieldType::Enum,
        ];
        let fields = kinds
            .iter()
            .enumerate()
            .map(|(index, kind)| FieldDefinition {
                id: FieldId::new(),
                name: format!("field {index}"),
                field_type: kind.clone(),
                required: true,
                default: None,
                validation: ValidationMetadata::default(),
                display: DisplayMetadata::default(),
                order: index as i64,
                deleted: false,
                enum_options: vec![],
            })
            .collect::<Vec<_>>();
        let schema = CollectionSchema {
            id: CollectionSchemaId::new(),
            name: "Types".into(),
            description: String::new(),
            fields: fields.clone(),
            deleted: false,
        };
        let env = TypeEnvironment {
            schema: &schema,
            computed: &[],
        };
        for definition in &fields {
            let expression = Expression::Field {
                field: FieldReference::Source(definition.id),
            };
            let add = Expression::Arithmetic {
                operator: ArithmeticOperator::Add,
                left: Box::new(expression.clone()),
                right: Box::new(expression.clone()),
            };
            let valid = matches!(
                definition.field_type,
                FieldType::Integer | FieldType::FixedDecimal { .. }
            );
            assert_eq!(
                infer_expression(&add, &env, true).is_ok(),
                valid,
                "add for {:?}",
                definition.field_type
            );
            let absolute = Expression::Abs {
                expression: Box::new(expression.clone()),
            };
            let valid = matches!(
                definition.field_type,
                FieldType::Integer | FieldType::FixedDecimal { .. } | FieldType::Duration
            );
            assert_eq!(
                infer_expression(&absolute, &env, true).is_ok(),
                valid,
                "abs for {:?}",
                definition.field_type
            );
            let boolean = Expression::Not {
                expression: Box::new(expression),
            };
            assert_eq!(
                infer_expression(&boolean, &env, true).is_ok(),
                matches!(definition.field_type, FieldType::Boolean)
            );
        }
        let scale_mismatch = Expression::Compare {
            operator: ComparisonOperator::Equal,
            left: Box::new(Expression::Constant {
                value: TypedValue::FixedDecimal {
                    representation: 1,
                    scale: 2,
                },
            }),
            right: Box::new(Expression::Constant {
                value: TypedValue::FixedDecimal {
                    representation: 1,
                    scale: 3,
                },
            }),
        };
        assert!(infer_expression(&scale_mismatch, &env, true).is_err());
        let date = Expression::Field {
            field: FieldReference::Source(fields[4].id),
        };
        let datetime = Expression::Field {
            field: FieldReference::Source(fields[5].id),
        };
        assert!(
            infer_expression(
                &Expression::Arithmetic {
                    operator: ArithmeticOperator::Subtract,
                    left: Box::new(date.clone()),
                    right: Box::new(date)
                },
                &env,
                true
            )
            .is_ok()
        );
        assert!(
            infer_expression(
                &Expression::Arithmetic {
                    operator: ArithmeticOperator::Subtract,
                    left: Box::new(datetime.clone()),
                    right: Box::new(datetime)
                },
                &env,
                true
            )
            .is_ok()
        );
    }

    #[test]
    fn exact_math_nulls_temporal_and_half_even_are_checked() {
        assert_eq!(
            divide(
                TypedValue::Integer(1),
                TypedValue::Integer(2),
                0,
                RoundingPolicy::HalfEven
            )
            .unwrap(),
            TypedValue::FixedDecimal {
                representation: 0,
                scale: 0
            }
        );
        assert_eq!(
            divide(
                TypedValue::Integer(3),
                TypedValue::Integer(2),
                0,
                RoundingPolicy::HalfEven
            )
            .unwrap(),
            TypedValue::FixedDecimal {
                representation: 2,
                scale: 0
            }
        );
        assert_eq!(
            divide(
                TypedValue::Integer(-3),
                TypedValue::Integer(2),
                0,
                RoundingPolicy::HalfEven
            )
            .unwrap(),
            TypedValue::FixedDecimal {
                representation: -2,
                scale: 0
            }
        );
        assert_eq!(
            divide(
                TypedValue::Null,
                TypedValue::Integer(2),
                2,
                RoundingPolicy::RejectInexact
            )
            .unwrap(),
            TypedValue::Null
        );
        assert_eq!(
            divide(
                TypedValue::Integer(1),
                TypedValue::Integer(3),
                0,
                RoundingPolicy::RejectInexact
            ),
            Err(QueryEvaluationError::Inexact)
        );
        assert_eq!(
            arithmetic(
                ArithmeticOperator::Subtract,
                TypedValue::DateTime(3_600_000),
                TypedValue::DateTime(0)
            )
            .unwrap(),
            TypedValue::Duration(3_600_000)
        );
        assert_eq!(
            abs(TypedValue::Integer(i64::MIN)),
            Err(QueryEvaluationError::Overflow)
        );
        assert_eq!(
            divide(
                TypedValue::Integer(1),
                TypedValue::Integer(0),
                2,
                RoundingPolicy::HalfEven
            ),
            Err(QueryEvaluationError::DivisionByZero)
        );
        assert_eq!(
            boolean(
                BooleanOperator::And,
                TypedValue::Null,
                TypedValue::Boolean(false)
            )
            .unwrap(),
            TypedValue::Boolean(false)
        );
        assert_eq!(
            boolean(
                BooleanOperator::Or,
                TypedValue::Null,
                TypedValue::Boolean(false)
            )
            .unwrap(),
            TypedValue::Null
        );
        for (operator, expected) in [
            (ComparisonOperator::Equal, false),
            (ComparisonOperator::NotEqual, true),
            (ComparisonOperator::GreaterThan, false),
            (ComparisonOperator::GreaterThanOrEqual, false),
            (ComparisonOperator::LessThan, true),
            (ComparisonOperator::LessThanOrEqual, true),
        ] {
            assert_eq!(
                compare(operator, TypedValue::Integer(1), TypedValue::Integer(2)).unwrap(),
                TypedValue::Boolean(expected)
            );
        }
    }

    #[test]
    fn filtering_sorting_ties_limits_and_aggregates_are_deterministic() {
        let (schema, field, _) = schema();
        let make = |value| GenericRecord {
            id: RecordId::new(),
            collection_id: schema.id,
            values: BTreeMap::from([(field, FieldValue::Integer(value))]),
            stamps: BTreeMap::new(),
            deleted: false,
        };
        let a = make(7);
        let b = make(9);
        let c = make(7);
        let field_expr = Expression::Field {
            field: FieldReference::Source(field),
        };
        let query = CollectionQuery {
            collection_id: schema.id,
            filter: Some(Expression::Compare {
                operator: ComparisonOperator::GreaterThanOrEqual,
                left: Box::new(field_expr.clone()),
                right: Box::new(Expression::Constant {
                    value: TypedValue::Integer(7),
                }),
            }),
            grouping: None,
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Sum {
                    expression: field_expr.clone(),
                },
            },
            sorting: vec![SortClause {
                expression: field_expr,
                direction: SortDirection::Ascending,
                null_order: NullOrder::Last,
            }],
            limit: None,
            calendar: CalendarPolicy::default(),
        };
        assert_eq!(
            execute_query(&query, &schema, &[], &[b, c, a], 0).unwrap(),
            QueryResult::Scalar {
                value: TypedValue::Integer(23),
                value_type: ValueType::Integer
            }
        );
    }

    #[test]
    fn query_matrix_covers_sort_null_limit_min_max_and_overflow() {
        let (schema, field, optional) = schema();
        let make = |value, ended| {
            let mut values = BTreeMap::from([(field, FieldValue::Integer(value))]);
            if let Some(ended) = ended {
                values.insert(optional, FieldValue::DateTime(ended));
            }
            GenericRecord {
                id: RecordId::new(),
                collection_id: schema.id,
                values,
                stamps: BTreeMap::new(),
                deleted: false,
            }
        };
        let rows = vec![make(3, None), make(1, Some(2)), make(2, Some(1))];
        let expr = Expression::Field {
            field: FieldReference::Source(field),
        };
        let optional_expr = Expression::Field {
            field: FieldReference::Source(optional),
        };
        let base = CollectionQuery {
            collection_id: schema.id,
            filter: None,
            grouping: None,
            shape: QueryShape::RecordSet {
                fields: vec![FieldReference::Source(field)],
            },
            sorting: vec![SortClause {
                expression: optional_expr.clone(),
                direction: SortDirection::Descending,
                null_order: NullOrder::First,
            }],
            limit: Some(2),
            calendar: CalendarPolicy::default(),
        };
        let result = execute_query(&base, &schema, &[], &rows, 0).unwrap();
        assert!(
            matches!(result,QueryResult::RecordSet{records} if records.len()==2 && records[0].id==rows[0].id && records[1].id==rows[1].id)
        );
        let ascending = CollectionQuery {
            sorting: vec![SortClause {
                expression: expr.clone(),
                direction: SortDirection::Ascending,
                null_order: NullOrder::Last,
            }],
            ..base.clone()
        };
        assert!(
            matches!(execute_query(&ascending,&schema,&[],&rows,0).unwrap(),QueryResult::RecordSet{records} if records[0].id==rows[1].id)
        );
        for (aggregation, expected) in [
            (
                Aggregation::Min {
                    expression: expr.clone(),
                },
                TypedValue::Integer(1),
            ),
            (
                Aggregation::Max {
                    expression: expr.clone(),
                },
                TypedValue::Integer(3),
            ),
        ] {
            let query = CollectionQuery {
                shape: QueryShape::Scalar { aggregation },
                sorting: vec![],
                limit: None,
                ..base.clone()
            };
            assert!(
                matches!(execute_query(&query,&schema,&[],&rows,0).unwrap(),QueryResult::Scalar{value,..} if value==expected)
            );
        }
        let overflow_rows = vec![make(i64::MAX, None), make(1, None)];
        let overflow = CollectionQuery {
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Sum { expression: expr },
            },
            sorting: vec![],
            limit: None,
            ..base
        };
        assert_eq!(
            execute_query(&overflow, &schema, &[], &overflow_rows, 0),
            Err(QueryEvaluationError::Overflow)
        );
        let calendar = CalendarPolicy::default();
        let date = TypedValue::Date(400);
        for period in [
            BucketPeriod::Day,
            BucketPeriod::Week,
            BucketPeriod::Month,
            BucketPeriod::Year,
        ] {
            assert!(matches!(
                bucket_value(&date, period, &calendar),
                Ok(TypedValue::Date(_))
            ));
        }
    }

    #[test]
    fn calendar_boundaries_and_buckets_use_persisted_policy() {
        let policy = CalendarPolicy {
            timezone: "America/New_York".into(),
            week_start: WeekStart::Monday,
        };
        let now = DateTime::parse_from_rfc3339("2024-03-15T14:00:00Z")
            .unwrap()
            .timestamp_millis();
        let start = current_boundary(now, CurrentBoundary::Month, &policy).unwrap();
        assert_eq!(
            utc_datetime(start).unwrap().to_rfc3339(),
            "2024-03-01T05:00:00+00:00"
        );
        assert_eq!(
            bucket_value(
                &TypedValue::Date(4),
                BucketPeriod::Week,
                &CalendarPolicy::default()
            )
            .unwrap(),
            TypedValue::Date(4)
        );
    }

    #[test]
    fn headache_acceptance_duration_current_month_average_history_and_weekly_frequency() {
        let collection_id = CollectionSchemaId::new();
        let started = FieldId::new();
        let ended = FieldId::new();
        let intensity = FieldId::new();
        let field = |id, name: &str, field_type, required, order| FieldDefinition {
            id,
            name: name.into(),
            field_type,
            required,
            default: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order,
            deleted: false,
            enum_options: vec![],
        };
        let schema = CollectionSchema {
            id: collection_id,
            name: "Headaches".into(),
            description: String::new(),
            deleted: false,
            fields: vec![
                field(started, "started", FieldType::DateTime, true, 0),
                field(ended, "ended", FieldType::DateTime, false, 1),
                field(intensity, "intensity", FieldType::Integer, true, 2),
            ],
        };
        let duration = ComputedFieldDefinition {
            id: ComputedFieldId::new(),
            collection_id,
            name: "duration".into(),
            declared_type: ValueType::Duration,
            nullable: true,
            expression: VersionedExpression::new(Expression::Arithmetic {
                operator: ArithmeticOperator::Subtract,
                left: Box::new(Expression::Field {
                    field: FieldReference::Source(ended),
                }),
                right: Box::new(Expression::Field {
                    field: FieldReference::Source(started),
                }),
            }),
            order: 0,
            deleted: false,
        };
        validate_computed_field(&duration, &schema).unwrap();
        let now = DateTime::parse_from_rfc3339("2024-03-20T12:00:00Z")
            .unwrap()
            .timestamp_millis();
        let march_1 = DateTime::parse_from_rfc3339("2024-03-01T00:00:00Z")
            .unwrap()
            .timestamp_millis();
        let make = |start: i64, end: Option<i64>, score: i64| {
            let mut values = BTreeMap::from([
                (started, FieldValue::DateTime(start)),
                (intensity, FieldValue::Integer(score)),
            ]);
            if let Some(end) = end {
                values.insert(ended, FieldValue::DateTime(end));
            }
            GenericRecord {
                id: RecordId::new(),
                collection_id,
                values,
                stamps: BTreeMap::new(),
                deleted: false,
            }
        };
        let rows = vec![
            make(march_1 + 3_600_000, Some(march_1 + 7_200_000), 7),
            make(march_1 + 8 * 86_400_000, None, 8),
            make(march_1 - 86_400_000, Some(march_1), 3),
        ];
        let context = EvaluationContext {
            schema: &schema,
            computed_definitions: std::slice::from_ref(&duration),
            now_utc_ms: now,
            calendar: &CalendarPolicy::default(),
        };
        assert_eq!(
            evaluate_expression(
                &Expression::Field {
                    field: FieldReference::Computed(duration.id)
                },
                &rows[0],
                &context
            )
            .unwrap(),
            TypedValue::Duration(3_600_000)
        );
        assert_eq!(
            evaluate_expression(
                &Expression::Field {
                    field: FieldReference::Computed(duration.id)
                },
                &rows[1],
                &context
            )
            .unwrap(),
            TypedValue::Null
        );
        let started_expr = Expression::Field {
            field: FieldReference::Source(started),
        };
        let intensity_expr = Expression::Field {
            field: FieldReference::Source(intensity),
        };
        let base = CollectionQuery {
            collection_id,
            filter: Some(Expression::Compare {
                operator: ComparisonOperator::GreaterThanOrEqual,
                left: Box::new(started_expr.clone()),
                right: Box::new(Expression::StartOfCurrent {
                    boundary: CurrentBoundary::Month,
                }),
            }),
            grouping: None,
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Count,
            },
            sorting: vec![],
            limit: None,
            calendar: CalendarPolicy::default(),
        };
        assert_eq!(
            execute_query(&base, &schema, std::slice::from_ref(&duration), &rows, now).unwrap(),
            QueryResult::Scalar {
                value: TypedValue::Integer(2),
                value_type: ValueType::Integer
            }
        );
        let average = CollectionQuery {
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Average {
                    expression: intensity_expr.clone(),
                    output_scale: 1,
                    rounding: RoundingPolicy::HalfEven,
                },
            },
            ..base.clone()
        };
        assert_eq!(
            execute_query(
                &average,
                &schema,
                std::slice::from_ref(&duration),
                &rows,
                now
            )
            .unwrap(),
            QueryResult::Scalar {
                value: TypedValue::FixedDecimal {
                    representation: 75,
                    scale: 1
                },
                value_type: ValueType::FixedDecimal { scale: 1 }
            }
        );
        let history = CollectionQuery {
            filter: None,
            shape: QueryShape::Series {
                x: started_expr.clone(),
                y: intensity_expr.clone(),
            },
            sorting: vec![SortClause {
                expression: started_expr.clone(),
                direction: SortDirection::Ascending,
                null_order: NullOrder::Last,
            }],
            limit: Some(10),
            ..base.clone()
        };
        assert!(
            matches!(execute_query(&history,&schema,std::slice::from_ref(&duration),&rows,now).unwrap(),QueryResult::Series{points,..} if points.len()==3)
        );
        let weekly = CollectionQuery {
            filter: None,
            grouping: Some(Grouping {
                expression: started_expr.clone(),
                period: BucketPeriod::Week,
            }),
            shape: QueryShape::CategorySeries {
                category: started_expr,
                aggregation: Aggregation::Count,
            },
            limit: None,
            ..base
        };
        assert!(
            matches!(execute_query(&weekly,&schema,&[duration],&rows,now).unwrap(),QueryResult::CategorySeries{points,..} if points.len()==2)
        );
    }

    #[test]
    fn money_acceptance_exact_balance_monthly_cashflow_abs_and_scale_rejection() {
        let collection_id = CollectionSchemaId::new();
        let occurred = FieldId::new();
        let amount = FieldId::new();
        let other_scale = FieldId::new();
        let schema = CollectionSchema {
            id: collection_id,
            name: "Money Movement".into(),
            description: String::new(),
            deleted: false,
            fields: vec![
                FieldDefinition {
                    id: occurred,
                    name: "occurred".into(),
                    field_type: FieldType::DateTime,
                    required: true,
                    default: None,
                    validation: ValidationMetadata::default(),
                    display: DisplayMetadata::default(),
                    order: 0,
                    deleted: false,
                    enum_options: vec![],
                },
                FieldDefinition {
                    id: amount,
                    name: "amount".into(),
                    field_type: FieldType::FixedDecimal { scale: 2 },
                    required: true,
                    default: None,
                    validation: ValidationMetadata::default(),
                    display: DisplayMetadata::default(),
                    order: 1,
                    deleted: false,
                    enum_options: vec![],
                },
                FieldDefinition {
                    id: other_scale,
                    name: "tax".into(),
                    field_type: FieldType::FixedDecimal { scale: 3 },
                    required: true,
                    default: None,
                    validation: ValidationMetadata::default(),
                    display: DisplayMetadata::default(),
                    order: 2,
                    deleted: false,
                    enum_options: vec![],
                },
            ],
        };
        let month = DateTime::parse_from_rfc3339("2024-01-10T00:00:00Z")
            .unwrap()
            .timestamp_millis();
        let values = [350_000, -90_000, -2_350];
        let rows = values
            .into_iter()
            .enumerate()
            .map(|(index, value)| GenericRecord {
                id: RecordId::new(),
                collection_id,
                values: BTreeMap::from([
                    (
                        occurred,
                        FieldValue::DateTime(month + index as i64 * 86_400_000),
                    ),
                    (amount, FieldValue::FixedDecimal(value)),
                    (other_scale, FieldValue::FixedDecimal(1_000)),
                ]),
                stamps: BTreeMap::new(),
                deleted: false,
            })
            .collect::<Vec<_>>();
        let amount_expr = Expression::Field {
            field: FieldReference::Source(amount),
        };
        let occurred_expr = Expression::Field {
            field: FieldReference::Source(occurred),
        };
        let balance = CollectionQuery {
            collection_id,
            filter: None,
            grouping: None,
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Sum {
                    expression: amount_expr.clone(),
                },
            },
            sorting: vec![],
            limit: None,
            calendar: CalendarPolicy::default(),
        };
        assert_eq!(
            execute_query(&balance, &schema, &[], &rows, month).unwrap(),
            QueryResult::Scalar {
                value: TypedValue::FixedDecimal {
                    representation: 257_650,
                    scale: 2
                },
                value_type: ValueType::FixedDecimal { scale: 2 }
            }
        );
        let cashflow = CollectionQuery {
            grouping: Some(Grouping {
                expression: occurred_expr.clone(),
                period: BucketPeriod::Month,
            }),
            shape: QueryShape::CategorySeries {
                category: occurred_expr,
                aggregation: Aggregation::Sum {
                    expression: amount_expr.clone(),
                },
            },
            ..balance.clone()
        };
        assert!(
            matches!(execute_query(&cashflow,&schema,&[],&rows,month).unwrap(),QueryResult::CategorySeries{points,..} if points[0].value==TypedValue::FixedDecimal{representation:257_650,scale:2})
        );
        let context = EvaluationContext {
            schema: &schema,
            computed_definitions: &[],
            now_utc_ms: month,
            calendar: &CalendarPolicy::default(),
        };
        assert_eq!(
            evaluate_expression(
                &Expression::Abs {
                    expression: Box::new(amount_expr.clone())
                },
                &rows[1],
                &context
            )
            .unwrap(),
            TypedValue::FixedDecimal {
                representation: 90_000,
                scale: 2
            }
        );
        let incompatible = Expression::Arithmetic {
            operator: ArithmeticOperator::Add,
            left: Box::new(amount_expr),
            right: Box::new(Expression::Field {
                field: FieldReference::Source(other_scale),
            }),
        };
        assert!(
            infer_expression(
                &incompatible,
                &TypeEnvironment {
                    schema: &schema,
                    computed: &[]
                },
                true
            )
            .unwrap_err()
            .message
            .contains("incompatible")
        );
    }
}
