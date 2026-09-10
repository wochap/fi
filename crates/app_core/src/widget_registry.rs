//! Application-core widget descriptors: accepted query result shapes, supported configuration
//! versions, and presentation validation. This module knows no Flutter or chart-library types.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    query::{CollectionQuery, QueryEvaluationError, QueryResult, QueryShape},
    widgets::{
        StructuredValue, WIDGET_CONFIGURATION_VERSION, WidgetConfiguration, WidgetDefinition,
        WidgetId, WidgetValidationError,
    },
};

pub const CORE_AGGREGATE_NUMBER: &str = "core.aggregate-number";
pub const CORE_LINE_CHART: &str = "core.line-chart";
pub const CORE_BAR_CHART: &str = "core.bar-chart";
pub const CORE_SCATTER_PLOT: &str = "core.scatter-plot";

/// The result shape contract a widget descriptor accepts. Mirrors [`QueryShape`] variants so a
/// widget can declare what it renders without touching query semantics.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QueryResultShape {
    Scalar,
    Series,
    CategorySeries,
    RecordSet,
}

impl QueryResultShape {
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::Scalar => "scalar",
            Self::Series => "series",
            Self::CategorySeries => "category series",
            Self::RecordSet => "record set",
        }
    }
}

impl From<&QueryShape> for QueryResultShape {
    fn from(value: &QueryShape) -> Self {
        match value {
            QueryShape::Scalar { .. } => Self::Scalar,
            QueryShape::Series { .. } => Self::Series,
            QueryShape::CategorySeries { .. } => Self::CategorySeries,
            QueryShape::RecordSet { .. } => Self::RecordSet,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct WidgetDescriptor {
    pub widget_type: &'static str,
    pub label: &'static str,
    pub accepted_shapes: &'static [QueryResultShape],
    pub configuration_version: u32,
}

impl WidgetDescriptor {
    #[must_use]
    pub fn accepts(self, shape: &QueryShape) -> bool {
        self.accepted_shapes.contains(&shape.into())
    }
}

static DESCRIPTORS: &[WidgetDescriptor] = &[
    WidgetDescriptor {
        widget_type: CORE_AGGREGATE_NUMBER,
        label: "Aggregate number",
        accepted_shapes: &[QueryResultShape::Scalar],
        configuration_version: WIDGET_CONFIGURATION_VERSION,
    },
    WidgetDescriptor {
        widget_type: CORE_LINE_CHART,
        label: "Line chart",
        // A bucketed CategorySeries is the natural shape for a monthly trend, so a line chart
        // accepts both an ordered Series and grouped buckets.
        accepted_shapes: &[QueryResultShape::Series, QueryResultShape::CategorySeries],
        configuration_version: WIDGET_CONFIGURATION_VERSION,
    },
    WidgetDescriptor {
        widget_type: CORE_BAR_CHART,
        label: "Bar chart",
        accepted_shapes: &[QueryResultShape::CategorySeries, QueryResultShape::Series],
        configuration_version: WIDGET_CONFIGURATION_VERSION,
    },
    WidgetDescriptor {
        widget_type: CORE_SCATTER_PLOT,
        label: "Scatter plot",
        accepted_shapes: &[QueryResultShape::Series],
        configuration_version: WIDGET_CONFIGURATION_VERSION,
    },
];

#[must_use]
pub const fn builtin_descriptors() -> &'static [WidgetDescriptor] {
    DESCRIPTORS
}

#[must_use]
pub fn descriptor_for(widget_type: &str) -> Option<&'static WidgetDescriptor> {
    DESCRIPTORS
        .iter()
        .find(|descriptor| descriptor.widget_type == widget_type)
}

#[must_use]
pub fn is_supported(widget_type: &str) -> bool {
    descriptor_for(widget_type).is_some()
}

/// Typed presentation configuration for `core.aggregate-number`. Decoding ignores unknown keys;
/// the authoritative structured value keeps them.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct AggregateNumberConfig {
    pub suffix: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct LineChartConfig {
    pub show_points: bool,
    pub y_axis_label: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct BarChartConfig {
    /// Bar thickness in logical pixels. Kept an integer so presentation stays exact.
    pub bar_width: Option<i64>,
    pub y_axis_label: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct ScatterPlotConfig {
    pub point_radius: Option<i64>,
    pub y_axis_label: Option<String>,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum WidgetError {
    #[error("widget was removed")]
    Removed,
    #[error("widget type {widget_type} has no local implementation")]
    UnsupportedType { widget_type: String },
    #[error("configuration version {version} is not supported by {widget_type}")]
    UnsupportedConfigurationVersion { widget_type: String, version: u32 },
    #[error("widget configuration is invalid: {message}")]
    InvalidConfiguration { message: String },
    #[error("widget query is unavailable")]
    UnknownQuery,
    #[error("widget query definition is invalid: {message}")]
    InvalidQuery { message: String },
    #[error("query returns a {actual} result but {widget_type} accepts {accepted}")]
    ShapeMismatch {
        widget_type: String,
        actual: String,
        accepted: String,
    },
    #[error("widget aggregation overflowed exact integer bounds")]
    Overflow,
    #[error("widget query failed: {message}")]
    QueryFailed { message: String },
}

impl WidgetError {
    #[must_use]
    pub const fn kind(&self) -> &'static str {
        match self {
            Self::Removed => "removed",
            Self::UnsupportedType { .. } => "unsupported_type",
            Self::UnsupportedConfigurationVersion { .. } => "unsupported_configuration_version",
            Self::InvalidConfiguration { .. } => "invalid_configuration",
            Self::UnknownQuery => "unknown_query",
            Self::InvalidQuery { .. } => "invalid_query",
            Self::ShapeMismatch { .. } => "shape_mismatch",
            Self::Overflow => "overflow",
            Self::QueryFailed { .. } => "query_failed",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum WidgetEvaluation {
    /// The widget resolved, its query produced an accepted shape, and the result is exact.
    Ready {
        widget_id: WidgetId,
        widget_type: String,
        result: QueryResult,
    },
    /// A typed per-widget failure. The definition is preserved unchanged.
    Failed {
        widget_id: WidgetId,
        widget_type: String,
        error: WidgetError,
    },
}

impl WidgetEvaluation {
    #[must_use]
    pub fn is_ready(&self) -> bool {
        matches!(self, Self::Ready { .. })
    }
    #[must_use]
    pub const fn widget_id(&self) -> WidgetId {
        match self {
            Self::Ready { widget_id, .. } | Self::Failed { widget_id, .. } => *widget_id,
        }
    }
    #[must_use]
    pub fn widget_type(&self) -> &str {
        match self {
            Self::Ready { widget_type, .. } | Self::Failed { widget_type, .. } => widget_type,
        }
    }
}

/// The outcome of resolving a widget's query reference before execution. A missing and an invalid
/// reference are distinct failures so the UI can report which one it hit.
#[derive(Clone, Debug)]
pub enum ResolvedWidgetQuery<'a> {
    Query(&'a CollectionQuery),
    Missing,
    Invalid { message: String },
}

/// Validates a definition's presentation configuration against its descriptor without rewriting
/// it. Unknown types validate structurally only so preserved data is never rejected for being
/// unrecognized, and unknown keys inside a known type are retained by the caller.
pub fn validate_configuration(definition: &WidgetDefinition) -> Result<(), WidgetValidationError> {
    validate_widget_configuration(definition.widget_type.as_str(), &definition.configuration)
}

/// Validates one configuration value for a widget type. Accepts unknown types structurally so a
/// preserved definition is never rejected for being unrecognized.
pub fn validate_widget_configuration(
    widget_type: &str,
    configuration: &WidgetConfiguration,
) -> Result<(), WidgetValidationError> {
    configuration.validate()?;
    let Some(descriptor) = descriptor_for(widget_type) else {
        return Ok(());
    };
    if configuration.version != descriptor.configuration_version {
        return Err(WidgetValidationError::new(
            "configuration.version",
            format!(
                "{} supports version {} only",
                descriptor.widget_type, descriptor.configuration_version
            ),
        ));
    }
    decode_configuration(descriptor.widget_type, &configuration.body).map(|_| ())
}

/// Decodes the known keys of a built-in configuration into a typed model. Unknown keys are
/// ignored here and remain in the authoritative structured value.
pub fn decode_configuration(
    widget_type: &str,
    body: &StructuredValue,
) -> Result<DecodedConfiguration, WidgetValidationError> {
    let empty = BTreeMap::new();
    let entries = match body {
        StructuredValue::Map(entries) => entries,
        StructuredValue::Null => &empty,
        _ => {
            return Err(WidgetValidationError::new(
                "configuration",
                "must be a structured map",
            ));
        }
    };
    Ok(match widget_type {
        CORE_AGGREGATE_NUMBER => DecodedConfiguration::AggregateNumber(AggregateNumberConfig {
            suffix: optional_text(entries, "suffix")?,
        }),
        CORE_LINE_CHART => DecodedConfiguration::LineChart(LineChartConfig {
            show_points: optional_boolean(entries, "show_points")?.unwrap_or(false),
            y_axis_label: optional_text(entries, "y_axis_label")?,
        }),
        CORE_BAR_CHART => DecodedConfiguration::BarChart(BarChartConfig {
            bar_width: optional_integer(entries, "bar_width")?,
            y_axis_label: optional_text(entries, "y_axis_label")?,
        }),
        CORE_SCATTER_PLOT => DecodedConfiguration::ScatterPlot(ScatterPlotConfig {
            point_radius: optional_integer(entries, "point_radius")?,
            y_axis_label: optional_text(entries, "y_axis_label")?,
        }),
        other => DecodedConfiguration::Unsupported {
            widget_type: other.to_owned(),
        },
    })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DecodedConfiguration {
    AggregateNumber(AggregateNumberConfig),
    LineChart(LineChartConfig),
    BarChart(BarChartConfig),
    ScatterPlot(ScatterPlotConfig),
    /// Preserved definition this build cannot interpret. It must be rendered as unsupported and
    /// never coerced into a built-in.
    Unsupported {
        widget_type: String,
    },
}

fn optional_text(
    entries: &BTreeMap<String, StructuredValue>,
    key: &str,
) -> Result<Option<String>, WidgetValidationError> {
    match entries.get(key) {
        None | Some(StructuredValue::Null) => Ok(None),
        Some(StructuredValue::Text(value)) => Ok(Some(value.clone())),
        Some(_) => Err(WidgetValidationError::new(
            format!("configuration.{key}"),
            "must be text",
        )),
    }
}

fn optional_boolean(
    entries: &BTreeMap<String, StructuredValue>,
    key: &str,
) -> Result<Option<bool>, WidgetValidationError> {
    match entries.get(key) {
        None | Some(StructuredValue::Null) => Ok(None),
        Some(StructuredValue::Boolean(value)) => Ok(Some(*value)),
        Some(_) => Err(WidgetValidationError::new(
            format!("configuration.{key}"),
            "must be a boolean",
        )),
    }
}

fn optional_integer(
    entries: &BTreeMap<String, StructuredValue>,
    key: &str,
) -> Result<Option<i64>, WidgetValidationError> {
    match entries.get(key) {
        None | Some(StructuredValue::Null) => Ok(None),
        Some(StructuredValue::Integer(value)) => Ok(Some(*value)),
        Some(_) => Err(WidgetValidationError::new(
            format!("configuration.{key}"),
            "must be a signed integer",
        )),
    }
}

/// Evaluates one widget in isolation. Every failure path is a typed per-widget error so a single
/// invalid definition cannot stop the collection screen, its records, or other widgets.
pub fn evaluate_widget(
    definition: &WidgetDefinition,
    query: ResolvedWidgetQuery<'_>,
    outcome: Result<QueryResult, QueryEvaluationError>,
) -> WidgetEvaluation {
    let widget_id = definition.id;
    let widget_type = definition.widget_type.to_string();
    let failed = |error: WidgetError| WidgetEvaluation::Failed {
        widget_id,
        widget_type: widget_type.clone(),
        error,
    };
    if definition.deleted {
        return failed(WidgetError::Removed);
    }
    let Some(descriptor) = descriptor_for(definition.widget_type.as_str()) else {
        return failed(WidgetError::UnsupportedType {
            widget_type: widget_type.clone(),
        });
    };
    if definition.configuration.version != descriptor.configuration_version {
        return failed(WidgetError::UnsupportedConfigurationVersion {
            widget_type: widget_type.clone(),
            version: definition.configuration.version,
        });
    }
    if let Err(error) = decode_configuration(descriptor.widget_type, &definition.configuration.body)
    {
        return failed(WidgetError::InvalidConfiguration {
            message: error.to_string(),
        });
    }
    let query = match query {
        ResolvedWidgetQuery::Query(query) => query,
        ResolvedWidgetQuery::Missing => return failed(WidgetError::UnknownQuery),
        ResolvedWidgetQuery::Invalid { message } => {
            return failed(WidgetError::InvalidQuery { message });
        }
    };
    if !descriptor.accepts(&query.shape) {
        return failed(WidgetError::ShapeMismatch {
            widget_type: widget_type.clone(),
            actual: QueryResultShape::from(&query.shape).label().to_owned(),
            accepted: descriptor
                .accepted_shapes
                .iter()
                .map(|shape| shape.label())
                .collect::<Vec<_>>()
                .join(" or "),
        });
    }
    match outcome {
        Ok(result) => WidgetEvaluation::Ready {
            widget_id,
            widget_type,
            result,
        },
        Err(QueryEvaluationError::Overflow) => failed(WidgetError::Overflow),
        Err(error) => failed(WidgetError::QueryFailed {
            message: error.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use crate::{
        CollectionSchemaId, QueryId,
        query::{Aggregation, CalendarPolicy, Expression, QueryShape},
        widgets::{WidgetConfiguration, WidgetId, WidgetLayout, WidgetType},
    };

    use super::*;

    fn definition(widget_type: &str, body: StructuredValue) -> WidgetDefinition {
        WidgetDefinition {
            id: WidgetId::new(),
            collection_id: CollectionSchemaId::new(),
            widget_type: WidgetType::new(widget_type).unwrap(),
            query_id: QueryId::new(),
            title: "Balance".into(),
            configuration: WidgetConfiguration::new(body),
            layout: WidgetLayout::default(),
            order: 0,
            deleted: false,
        }
    }

    fn scalar_query() -> CollectionQuery {
        CollectionQuery {
            collection_id: CollectionSchemaId::new(),
            filter: None,
            grouping: None,
            shape: QueryShape::Scalar {
                aggregation: Aggregation::Count,
            },
            sorting: vec![],
            limit: None,
            calendar: CalendarPolicy::default(),
        }
    }

    fn series_query() -> CollectionQuery {
        let x = Expression::Constant {
            value: crate::query::TypedValue::Integer(0),
        };
        CollectionQuery {
            shape: QueryShape::Series { x: x.clone(), y: x },
            ..scalar_query()
        }
    }

    #[test]
    fn descriptors_are_keyed_by_open_strings_and_declare_shapes() {
        assert_eq!(builtin_descriptors().len(), 4);
        assert_eq!(
            descriptor_for(CORE_AGGREGATE_NUMBER)
                .unwrap()
                .accepted_shapes,
            [QueryResultShape::Scalar]
        );
        assert_eq!(
            descriptor_for(CORE_BAR_CHART).unwrap().accepted_shapes,
            [QueryResultShape::CategorySeries, QueryResultShape::Series]
        );
        assert_eq!(
            descriptor_for(CORE_LINE_CHART).unwrap().accepted_shapes,
            [QueryResultShape::Series, QueryResultShape::CategorySeries]
        );
        // A scatter plot renders individual observations, so it never accepts grouped buckets.
        assert_eq!(
            descriptor_for(CORE_SCATTER_PLOT).unwrap().accepted_shapes,
            [QueryResultShape::Series]
        );
        assert_eq!(descriptor_for("com.example.future-widget"), None);
        assert!(!is_supported("com.example.future-widget"));
        assert!(is_supported(CORE_SCATTER_PLOT));
    }

    #[test]
    fn unknown_types_evaluate_to_a_typed_error_without_coercion() {
        let preserved = definition(
            "com.example.future-widget",
            StructuredValue::Map(BTreeMap::from([(
                "opaque".into(),
                StructuredValue::Integer(1),
            )])),
        );
        // An unknown type validates structurally and keeps its opaque configuration.
        validate_configuration(&preserved).unwrap();
        match evaluate_widget(
            &preserved,
            ResolvedWidgetQuery::Query(&scalar_query()),
            Ok(scalar_result()),
        ) {
            WidgetEvaluation::Failed {
                widget_id,
                widget_type,
                error,
            } => {
                assert_eq!(widget_id, preserved.id);
                assert_eq!(widget_type, "com.example.future-widget");
                assert!(matches!(error, WidgetError::UnsupportedType { .. }));
            }
            ready => panic!("unknown type must not evaluate: {ready:?}"),
        }
        assert_eq!(
            decode_configuration("com.example.future-widget", &preserved.configuration.body)
                .unwrap(),
            DecodedConfiguration::Unsupported {
                widget_type: "com.example.future-widget".into()
            }
        );
    }

    #[test]
    fn shape_mismatch_and_query_failures_are_isolated_per_widget() {
        let aggregate = definition(CORE_AGGREGATE_NUMBER, StructuredValue::Map(BTreeMap::new()));
        match evaluate_widget(
            &aggregate,
            ResolvedWidgetQuery::Query(&series_query()),
            Ok(series_result()),
        ) {
            WidgetEvaluation::Failed { error, .. } => {
                assert!(
                    matches!(&error, WidgetError::ShapeMismatch { actual, .. } if actual == "series")
                );
            }
            ready => panic!("shape mismatch expected: {ready:?}"),
        }
        match evaluate_widget(
            &aggregate,
            ResolvedWidgetQuery::Missing,
            Err(QueryEvaluationError::InvalidDefinition("x".into())),
        ) {
            WidgetEvaluation::Failed { error, .. } => {
                assert_eq!(error, WidgetError::UnknownQuery);
            }
            ready => panic!("unknown query expected: {ready:?}"),
        }
        match evaluate_widget(
            &aggregate,
            ResolvedWidgetQuery::Invalid {
                message: "expression 2 is out of range".into(),
            },
            Err(QueryEvaluationError::InvalidDefinition("x".into())),
        ) {
            WidgetEvaluation::Failed { error, .. } => {
                assert!(matches!(error, WidgetError::InvalidQuery { .. }));
            }
            ready => panic!("invalid query expected: {ready:?}"),
        }
        match evaluate_widget(
            &aggregate,
            ResolvedWidgetQuery::Query(&scalar_query()),
            Err(QueryEvaluationError::Overflow),
        ) {
            WidgetEvaluation::Failed { error, .. } => assert_eq!(error, WidgetError::Overflow),
            ready => panic!("overflow expected: {ready:?}"),
        }
        match evaluate_widget(
            &aggregate,
            ResolvedWidgetQuery::Query(&scalar_query()),
            Err(QueryEvaluationError::DivisionByZero),
        ) {
            WidgetEvaluation::Failed { error, .. } => {
                assert!(matches!(error, WidgetError::QueryFailed { .. }));
            }
            ready => panic!("query failure expected: {ready:?}"),
        }
        let removed = WidgetDefinition {
            deleted: true,
            ..aggregate
        };
        match evaluate_widget(
            &removed,
            ResolvedWidgetQuery::Query(&scalar_query()),
            Ok(scalar_result()),
        ) {
            WidgetEvaluation::Failed { error, .. } => assert_eq!(error, WidgetError::Removed),
            ready => panic!("tombstone expected: {ready:?}"),
        }
    }

    #[test]
    fn accepted_shapes_and_typed_configuration_decode() {
        let line = definition(
            CORE_LINE_CHART,
            StructuredValue::Map(BTreeMap::from([
                ("show_points".into(), StructuredValue::Boolean(true)),
                (
                    "y_axis_label".into(),
                    StructuredValue::Text("Intensity".into()),
                ),
                ("future_key".into(), StructuredValue::Integer(9)),
            ])),
        );
        validate_configuration(&line).unwrap();
        assert_eq!(
            decode_configuration(CORE_LINE_CHART, &line.configuration.body).unwrap(),
            DecodedConfiguration::LineChart(LineChartConfig {
                show_points: true,
                y_axis_label: Some("Intensity".into())
            })
        );
        match evaluate_widget(
            &line,
            ResolvedWidgetQuery::Query(&series_query()),
            Ok(series_result()),
        ) {
            WidgetEvaluation::Ready { widget_type, .. } => {
                assert_eq!(widget_type, CORE_LINE_CHART);
            }
            failure => panic!("line chart should evaluate: {failure:?}"),
        }
        let stale = WidgetDefinition {
            configuration: WidgetConfiguration {
                version: 99,
                body: StructuredValue::Map(BTreeMap::new()),
            },
            ..line.clone()
        };
        assert_eq!(
            validate_configuration(&stale).unwrap_err().path,
            "configuration.version"
        );
        match evaluate_widget(
            &stale,
            ResolvedWidgetQuery::Query(&series_query()),
            Ok(series_result()),
        ) {
            WidgetEvaluation::Failed { error, .. } => {
                assert!(matches!(
                    error,
                    WidgetError::UnsupportedConfigurationVersion { version: 99, .. }
                ));
            }
            ready => panic!("version mismatch expected: {ready:?}"),
        }
        let malformed = definition(
            CORE_SCATTER_PLOT,
            StructuredValue::Map(BTreeMap::from([(
                "point_radius".into(),
                StructuredValue::Text("large".into()),
            )])),
        );
        assert!(validate_configuration(&malformed).is_err());
        match evaluate_widget(
            &malformed,
            ResolvedWidgetQuery::Query(&series_query()),
            Ok(series_result()),
        ) {
            WidgetEvaluation::Failed { error, .. } => {
                assert!(matches!(error, WidgetError::InvalidConfiguration { .. }));
            }
            ready => panic!("malformed configuration expected: {ready:?}"),
        }
    }

    fn scalar_result() -> QueryResult {
        QueryResult::Scalar {
            value: crate::query::TypedValue::FixedDecimal {
                representation: 257_650,
                scale: 2,
            },
            value_type: crate::query::ValueType::FixedDecimal { scale: 2 },
        }
    }
    fn series_result() -> QueryResult {
        QueryResult::Series {
            points: vec![],
            x_type: crate::query::ValueType::DateTime,
            y_type: crate::query::ValueType::Integer,
        }
    }
}
