use app_core::{QueryResultShape, WidgetId, WidgetSize, WidgetType, builtin_descriptors};

use crate::api::{
    lifecycle::core,
    models::{
        BridgeError, DiagnosticDto, QueryResultDto, QueryResultShapeDto, StructuredEntryDto,
        StructuredValueDto, StructuredValueKindDto, WidgetConfigurationDto, WidgetDefinitionDto,
        WidgetDescriptorDto, WidgetErrorKindDto, WidgetEvaluationDto, WidgetLayoutDto,
        WidgetSizeDto, WidgetUpdateDto,
    },
};

pub async fn list_widgets(collection_id: String) -> Result<Vec<WidgetDefinitionDto>, BridgeError> {
    core()
        .await?
        .widget_definitions(collection_id.parse().map_err(validation)?)
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}

/// Reads one widget including tombstoned and unsupported definitions, so preserved data can be
/// inspected and edited through safe metadata changes only.
pub async fn get_widget(
    collection_id: String,
    id: String,
) -> Result<Option<WidgetDefinitionDto>, BridgeError> {
    core()
        .await?
        .widget_definition(
            collection_id.parse().map_err(validation)?,
            id.parse().map_err(validation)?,
        )
        .map(|item| item.map(Into::into))
        .map_err(Into::into)
}

pub async fn create_widget(mut definition: WidgetDefinitionDto) -> Result<String, BridgeError> {
    let id = if definition.id.is_empty() {
        WidgetId::new()
    } else {
        definition.id.parse().map_err(validation)?
    };
    definition.id = id.to_string();
    core()
        .await?
        .create_widget(definition.try_into()?)
        .await
        .map_err(BridgeError::from)?;
    Ok(id.to_string())
}

pub async fn update_widget(update: WidgetUpdateDto) -> Result<(), BridgeError> {
    core()
        .await?
        .update_widget(update.try_into()?)
        .await
        .map_err(Into::into)
}

pub async fn remove_widget(collection_id: String, id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .remove_widget(
            collection_id.parse().map_err(validation)?,
            id.parse().map_err(validation)?,
        )
        .await
        .map_err(Into::into)
}

pub async fn reorder_widgets(collection_id: String, ids: Vec<String>) -> Result<(), BridgeError> {
    core()
        .await?
        .reorder_widgets(
            collection_id.parse().map_err(validation)?,
            ids.into_iter()
                .map(|id| id.parse().map_err(validation))
                .collect::<Result<_, _>>()?,
        )
        .await
        .map_err(Into::into)
}

/// The descriptor registry this build implements. Widget types not listed here are still valid
/// synchronized data; `get_widget_descriptor` reports them as unsupported instead of failing.
pub fn list_widget_descriptors() -> Vec<WidgetDescriptorDto> {
    builtin_descriptors()
        .iter()
        .map(|descriptor| WidgetDescriptorDto {
            widget_type: descriptor.widget_type.into(),
            label: descriptor.label.into(),
            accepted_shapes: descriptor
                .accepted_shapes
                .iter()
                .copied()
                .map(Into::into)
                .collect(),
            configuration_version: i64::from(descriptor.configuration_version),
            supported: true,
        })
        .collect()
}

/// Resolves one widget type against the local registry. Unknown types yield an unsupported
/// descriptor with no accepted shapes rather than an error, so the UI can render a placeholder.
pub fn get_widget_descriptor(widget_type: String) -> WidgetDescriptorDto {
    match app_core::descriptor_for(&widget_type) {
        Some(descriptor) => WidgetDescriptorDto {
            widget_type: descriptor.widget_type.into(),
            label: descriptor.label.into(),
            accepted_shapes: descriptor
                .accepted_shapes
                .iter()
                .copied()
                .map(Into::into)
                .collect(),
            configuration_version: i64::from(descriptor.configuration_version),
            supported: true,
        },
        None => WidgetDescriptorDto {
            widget_type,
            label: String::new(),
            accepted_shapes: vec![],
            configuration_version: 0,
            supported: false,
        },
    }
}

pub async fn evaluate_widget(
    collection_id: String,
    id: String,
    now_utc_ms: i64,
) -> Result<WidgetEvaluationDto, BridgeError> {
    core()
        .await?
        .evaluate_widget(
            collection_id.parse().map_err(validation)?,
            id.parse().map_err(validation)?,
            now_utc_ms,
        )
        .map(Into::into)
        .map_err(Into::into)
}

/// Evaluates every active widget of a collection. Duplicate query references are executed once per
/// call. A failing widget returns a typed error entry; the others still return results.
pub async fn evaluate_widgets(
    collection_id: String,
    now_utc_ms: i64,
) -> Result<Vec<WidgetEvaluationDto>, BridgeError> {
    core()
        .await?
        .evaluate_widgets(collection_id.parse().map_err(validation)?, now_utc_ms)
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}

pub async fn widget_diagnostics(id: String) -> Result<Vec<DiagnosticDto>, BridgeError> {
    core()
        .await?
        .widget_diagnostics(id.parse().map_err(validation)?)
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}

fn validation(error: impl std::fmt::Display) -> BridgeError {
    BridgeError::validation("id", error.to_string())
}
fn missing(field: &'static str) -> BridgeError {
    BridgeError::validation(field, "required typed payload is missing")
}

impl From<QueryResultShape> for QueryResultShapeDto {
    fn from(value: QueryResultShape) -> Self {
        match value {
            QueryResultShape::Scalar => Self::Scalar,
            QueryResultShape::Series => Self::Series,
            QueryResultShape::CategorySeries => Self::CategorySeries,
            QueryResultShape::RecordSet => Self::RecordSet,
        }
    }
}

impl From<app_core::StructuredValue> for StructuredValueDto {
    fn from(value: app_core::StructuredValue) -> Self {
        let (kind, boolean_value, integer_value, text_value) = match &value {
            app_core::StructuredValue::Null => (StructuredValueKindDto::Null, None, None, None),
            app_core::StructuredValue::Boolean(item) => {
                (StructuredValueKindDto::Boolean, Some(*item), None, None)
            }
            app_core::StructuredValue::Integer(item) => {
                (StructuredValueKindDto::Integer, None, Some(*item), None)
            }
            app_core::StructuredValue::Text(item) => {
                (StructuredValueKindDto::Text, None, None, Some(item.clone()))
            }
            app_core::StructuredValue::List(_) => (StructuredValueKindDto::List, None, None, None),
            app_core::StructuredValue::Map(_) => (StructuredValueKindDto::Map, None, None, None),
        };
        let (items, entries) = match value {
            app_core::StructuredValue::List(items) => (
                items
                    .into_iter()
                    .map(|item| Box::new(item.into()))
                    .collect::<Vec<_>>(),
                vec![],
            ),
            app_core::StructuredValue::Map(entries) => (
                vec![],
                entries
                    .into_iter()
                    .map(|(key, value)| {
                        Box::new(StructuredEntryDto {
                            key,
                            value: Box::new(value.into()),
                        })
                    })
                    .collect::<Vec<_>>(),
            ),
            _ => (vec![], vec![]),
        };
        Self {
            kind,
            boolean_value,
            integer_value,
            text_value,
            items,
            entries,
        }
    }
}

impl TryFrom<StructuredValueDto> for app_core::StructuredValue {
    type Error = BridgeError;
    fn try_from(value: StructuredValueDto) -> Result<Self, Self::Error> {
        Ok(match value.kind {
            StructuredValueKindDto::Null => Self::Null,
            StructuredValueKindDto::Boolean => Self::Boolean(
                value
                    .boolean_value
                    .ok_or_else(|| missing("boolean_value"))?,
            ),
            StructuredValueKindDto::Integer => Self::Integer(
                value
                    .integer_value
                    .ok_or_else(|| missing("integer_value"))?,
            ),
            StructuredValueKindDto::Text => {
                Self::Text(value.text_value.ok_or_else(|| missing("text_value"))?)
            }
            StructuredValueKindDto::List => Self::List(
                value
                    .items
                    .into_iter()
                    .map(|item| (*item).try_into())
                    .collect::<Result<_, _>>()?,
            ),
            StructuredValueKindDto::Map => Self::Map(
                value
                    .entries
                    .into_iter()
                    .map(|entry| Ok((entry.key, (*entry.value).try_into()?)))
                    .collect::<Result<_, Self::Error>>()?,
            ),
        })
    }
}

impl From<WidgetSize> for WidgetSizeDto {
    fn from(value: WidgetSize) -> Self {
        match value {
            WidgetSize::Small => Self::Small,
            WidgetSize::Medium => Self::Medium,
            WidgetSize::Large => Self::Large,
            WidgetSize::Full => Self::Full,
        }
    }
}

impl From<WidgetSizeDto> for WidgetSize {
    fn from(value: WidgetSizeDto) -> Self {
        match value {
            WidgetSizeDto::Small => Self::Small,
            WidgetSizeDto::Medium => Self::Medium,
            WidgetSizeDto::Large => Self::Large,
            WidgetSizeDto::Full => Self::Full,
        }
    }
}

impl From<app_core::WidgetConfiguration> for WidgetConfigurationDto {
    fn from(value: app_core::WidgetConfiguration) -> Self {
        Self {
            version: i64::from(value.version),
            body: value.body.into(),
        }
    }
}

impl TryFrom<WidgetConfigurationDto> for app_core::WidgetConfiguration {
    type Error = BridgeError;
    fn try_from(value: WidgetConfigurationDto) -> Result<Self, Self::Error> {
        Ok(Self {
            version: u32::try_from(value.version).map_err(|_| {
                BridgeError::validation("configuration.version", "must be non-negative")
            })?,
            body: value.body.try_into()?,
        })
    }
}

impl From<app_core::WidgetLayout> for WidgetLayoutDto {
    fn from(value: app_core::WidgetLayout) -> Self {
        Self {
            version: i64::from(value.version),
            size: value.size.into(),
            hints: value.hints.into(),
        }
    }
}

impl TryFrom<WidgetLayoutDto> for app_core::WidgetLayout {
    type Error = BridgeError;
    fn try_from(value: WidgetLayoutDto) -> Result<Self, Self::Error> {
        Ok(Self {
            version: u32::try_from(value.version)
                .map_err(|_| BridgeError::validation("layout.version", "must be non-negative"))?,
            size: value.size.into(),
            hints: value.hints.try_into()?,
        })
    }
}

impl From<app_core::WidgetDefinition> for WidgetDefinitionDto {
    fn from(value: app_core::WidgetDefinition) -> Self {
        Self {
            id: value.id.to_string(),
            collection_id: value.collection_id.to_string(),
            // The type crosses as an open string so an unrecognized value stays inspectable
            // instead of failing the whole list.
            widget_type: value.widget_type.to_string(),
            query_id: value.query_id.to_string(),
            title: value.title,
            configuration: value.configuration.into(),
            layout: value.layout.into(),
            order: value.order,
            deleted: value.deleted,
        }
    }
}

impl TryFrom<WidgetDefinitionDto> for app_core::WidgetDefinition {
    type Error = BridgeError;
    fn try_from(value: WidgetDefinitionDto) -> Result<Self, Self::Error> {
        Ok(Self {
            id: value.id.parse().map_err(validation)?,
            collection_id: value.collection_id.parse().map_err(validation)?,
            widget_type: WidgetType::new(value.widget_type)
                .map_err(|error| BridgeError::validation("widget_type", error.to_string()))?,
            query_id: value.query_id.parse().map_err(validation)?,
            title: value.title,
            configuration: value.configuration.try_into()?,
            layout: value.layout.try_into()?,
            order: value.order,
            deleted: value.deleted,
        })
    }
}

impl TryFrom<WidgetUpdateDto> for app_core::WidgetUpdate {
    type Error = BridgeError;
    fn try_from(value: WidgetUpdateDto) -> Result<Self, Self::Error> {
        Ok(Self {
            id: value.id.parse().map_err(validation)?,
            collection_id: value.collection_id.parse().map_err(validation)?,
            title: value.title,
            query_id: value
                .query_id
                .map(|id| id.parse().map_err(validation))
                .transpose()?,
            configuration: value.configuration.map(TryInto::try_into).transpose()?,
            layout: value.layout.map(TryInto::try_into).transpose()?,
            order: value.order,
        })
    }
}

impl From<app_core::WidgetError> for WidgetErrorKindDto {
    fn from(value: app_core::WidgetError) -> Self {
        match value {
            app_core::WidgetError::Removed => Self::Removed,
            app_core::WidgetError::UnsupportedType { .. } => Self::UnsupportedType,
            app_core::WidgetError::UnsupportedConfigurationVersion { .. } => {
                Self::UnsupportedConfigurationVersion
            }
            app_core::WidgetError::InvalidConfiguration { .. } => Self::InvalidConfiguration,
            app_core::WidgetError::UnknownQuery => Self::UnknownQuery,
            app_core::WidgetError::InvalidQuery { .. } => Self::InvalidQuery,
            app_core::WidgetError::ShapeMismatch { .. } => Self::ShapeMismatch,
            app_core::WidgetError::Overflow => Self::Overflow,
            app_core::WidgetError::QueryFailed { .. } => Self::QueryFailed,
        }
    }
}

impl From<app_core::WidgetEvaluation> for WidgetEvaluationDto {
    fn from(value: app_core::WidgetEvaluation) -> Self {
        let widget_id = value.widget_id().to_string();
        let widget_type = value.widget_type().to_owned();
        match value {
            app_core::WidgetEvaluation::Ready { result, .. } => Self {
                widget_id,
                widget_type,
                ready: true,
                result: Some(QueryResultDto::from(result)),
                error_kind: None,
                message: None,
            },
            app_core::WidgetEvaluation::Failed { error, .. } => Self {
                widget_id,
                widget_type,
                ready: false,
                result: None,
                error_kind: Some(error.clone().into()),
                // Per-widget messages stay in the domain vocabulary; they never carry paths or
                // infrastructure detail because WidgetError is built from validation strings.
                message: Some(error.to_string()),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use app_core::{
        CollectionSchemaId, QueryId, QueryResult, StructuredValue, TypedValue, ValueType,
        WidgetConfiguration, WidgetDefinition, WidgetError, WidgetEvaluation, WidgetId,
        WidgetLayout,
    };

    use super::*;

    #[test]
    fn structured_values_round_trip_through_the_bridge_losslessly() {
        let value = StructuredValue::Map(BTreeMap::from([
            ("null".into(), StructuredValue::Null),
            ("boolean".into(), StructuredValue::Boolean(false)),
            ("integer".into(), StructuredValue::Integer(i64::MIN)),
            ("scaled".into(), StructuredValue::Integer(-2350)),
            ("text".into(), StructuredValue::Text("2576.50".into())),
            (
                "list".into(),
                StructuredValue::List(vec![
                    StructuredValue::Integer(i64::MAX),
                    StructuredValue::Map(BTreeMap::from([(
                        "nested".into(),
                        StructuredValue::Text("x".into()),
                    )])),
                ]),
            ),
        ]));
        let dto: StructuredValueDto = value.clone().into();
        assert_eq!(app_core::StructuredValue::try_from(dto).unwrap(), value);
    }

    #[test]
    fn definitions_and_updates_round_trip_with_an_open_widget_type() {
        let definition = WidgetDefinition {
            id: WidgetId::new(),
            collection_id: CollectionSchemaId::new(),
            widget_type: WidgetType::new("com.example.future-widget").unwrap(),
            query_id: QueryId::new(),
            title: "Future".into(),
            configuration: WidgetConfiguration {
                version: 12,
                body: StructuredValue::Map(BTreeMap::from([(
                    "opaque".into(),
                    StructuredValue::Integer(7),
                )])),
            },
            layout: WidgetLayout::default(),
            order: 2,
            deleted: false,
        };
        let dto = WidgetDefinitionDto::from(definition.clone());
        assert_eq!(dto.widget_type, "com.example.future-widget");
        assert_eq!(
            app_core::WidgetDefinition::try_from(dto.clone()).unwrap(),
            definition
        );
        // A malformed type is rejected at the boundary rather than silently stored.
        assert!(
            app_core::WidgetDefinition::try_from(WidgetDefinitionDto {
                widget_type: "not namespaced".into(),
                ..dto.clone()
            })
            .is_err()
        );
        let update = WidgetUpdateDto {
            id: definition.id.to_string(),
            collection_id: definition.collection_id.to_string(),
            title: Some("Renamed".into()),
            query_id: None,
            configuration: None,
            layout: None,
            order: Some(4),
        };
        let core_update = app_core::WidgetUpdate::try_from(update).unwrap();
        assert_eq!(core_update.title.as_deref(), Some("Renamed"));
        // Omitted fields stay None so their registers are never rewritten.
        assert!(core_update.configuration.is_none());
        assert!(core_update.query_id.is_none());
    }

    #[test]
    fn evaluations_expose_results_and_typed_errors_without_leaking_internals() {
        let widget_id = WidgetId::new();
        let ready = WidgetEvaluation::Ready {
            widget_id,
            widget_type: "core.aggregate-number".into(),
            result: QueryResult::Scalar {
                value: TypedValue::FixedDecimal {
                    representation: -2350,
                    scale: 2,
                },
                value_type: ValueType::FixedDecimal { scale: 2 },
            },
        };
        let dto = WidgetEvaluationDto::from(ready);
        assert!(dto.ready);
        assert_eq!(dto.widget_id, widget_id.to_string());
        assert_eq!(dto.error_kind, None);
        let result = dto.result.unwrap();
        assert_eq!(result.value.unwrap().integer_value, Some(-2350));

        let failed = WidgetEvaluation::Failed {
            widget_id,
            widget_type: "com.example.future-widget".into(),
            error: WidgetError::UnsupportedType {
                widget_type: "com.example.future-widget".into(),
            },
        };
        let dto = WidgetEvaluationDto::from(failed);
        assert!(!dto.ready);
        assert_eq!(dto.result, None);
        assert_eq!(dto.error_kind, Some(WidgetErrorKindDto::UnsupportedType));
        assert_eq!(dto.widget_type, "com.example.future-widget");
    }

    #[test]
    fn descriptors_report_unsupported_types_instead_of_failing() {
        let descriptors = list_widget_descriptors();
        assert_eq!(descriptors.len(), 4);
        assert!(descriptors.iter().all(|item| item.supported));
        assert!(
            descriptors
                .iter()
                .any(|item| item.widget_type == "core.bar-chart"
                    && item.accepted_shapes
                        == vec![
                            QueryResultShapeDto::CategorySeries,
                            QueryResultShapeDto::Series
                        ])
        );
        let unknown = get_widget_descriptor("com.example.future-widget".into());
        assert!(!unknown.supported);
        assert!(unknown.accepted_shapes.is_empty());
        assert_eq!(unknown.widget_type, "com.example.future-widget");
    }
}
