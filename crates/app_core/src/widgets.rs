//! Open-ended synchronized widget definitions and their lossless presentation values.
//!
//! Widget identity is a validated namespaced string rather than a closed enum so a future
//! build can register a renderer for an already-synchronized type without migrating data.

use std::{collections::BTreeMap, fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{query::QueryId, schema::CollectionSchemaId};

pub const WIDGET_CONFIGURATION_VERSION: u32 = 1;
pub const WIDGET_LAYOUT_VERSION: u32 = 1;
pub const MAX_WIDGET_TYPE_LENGTH: usize = 128;
pub const MAX_WIDGET_TITLE_LENGTH: usize = 120;
pub const MAX_STRUCTURED_DEPTH: usize = 32;
pub const MAX_STRUCTURED_NODES: usize = 4_096;
pub const MAX_STRUCTURED_KEY_LENGTH: usize = 128;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct WidgetId(Uuid);

impl WidgetId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::now_v7())
    }
    #[must_use]
    pub const fn as_uuid(self) -> Uuid {
        self.0
    }
}
impl Default for WidgetId {
    fn default() -> Self {
        Self::new()
    }
}
impl fmt::Display for WidgetId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}
impl FromStr for WidgetId {
    type Err = WidgetValidationError;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let id = Uuid::parse_str(value)
            .map_err(|_| WidgetValidationError::new("widget_id", "must be a canonical UUIDv7"))?;
        if id.get_version_num() != 7 || id.hyphenated().to_string() != value {
            return Err(WidgetValidationError::new(
                "widget_id",
                "must be a canonical UUIDv7",
            ));
        }
        Ok(Self(id))
    }
}
impl<'de> Deserialize<'de> for WidgetId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer)?
            .parse()
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq, Serialize, Deserialize)]
#[error("{path}: {message}")]
pub struct WidgetValidationError {
    pub path: String,
    pub message: String,
}
impl WidgetValidationError {
    pub fn new(path: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            message: message.into(),
        }
    }
}

/// A validated namespaced widget type identifier such as `core.aggregate-number`.
///
/// The string is authoritative: an unrecognized value stays valid preserved data instead of
/// failing to decode, and only the renderer registries decide whether it is supported locally.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WidgetType(String);

impl WidgetType {
    pub fn new(value: impl Into<String>) -> Result<Self, WidgetValidationError> {
        let value = value.into();
        validate_widget_type(&value)?;
        Ok(Self(value))
    }
    /// Wraps an already-synchronized identifier without re-validating it. Decoding authoritative
    /// data must never fail because a future build used naming rules this one does not know; the
    /// value stays preserved and surfaces as a diagnostic instead.
    #[must_use]
    pub const fn preserved(value: String) -> Self {
        Self(value)
    }
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl fmt::Display for WidgetType {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}
impl FromStr for WidgetType {
    type Err = WidgetValidationError;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::new(value)
    }
}

pub fn validate_widget_type(value: &str) -> Result<(), WidgetValidationError> {
    let path = "widget_type";
    if value.is_empty() || value.chars().count() > MAX_WIDGET_TYPE_LENGTH {
        return Err(WidgetValidationError::new(
            path,
            format!("must contain 1 to {MAX_WIDGET_TYPE_LENGTH} characters"),
        ));
    }
    let segments: Vec<&str> = value.split('.').collect();
    if segments.len() < 2 {
        return Err(WidgetValidationError::new(
            path,
            "must be namespaced, such as core.line-chart",
        ));
    }
    for segment in segments {
        if segment.is_empty() || segment.len() > 64 {
            return Err(WidgetValidationError::new(
                path,
                "segments must contain 1 to 64 characters",
            ));
        }
        let valid = segment.bytes().enumerate().all(|(index, byte)| {
            let separator = byte == b'-' || byte == b'_';
            if separator {
                return index != 0 && index + 1 != segment.len();
            }
            byte.is_ascii_lowercase() || byte.is_ascii_digit()
        });
        if !valid {
            return Err(WidgetValidationError::new(
                path,
                "segments must use lowercase letters, digits, hyphens, and underscores",
            ));
        }
    }
    Ok(())
}

/// A generic presentation value with lossless null, boolean, signed integer, text, list, and
/// string-keyed map nodes. Signed integers never pass through binary floating point.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum StructuredValue {
    Null,
    Boolean(bool),
    Integer(i64),
    Text(String),
    List(Vec<StructuredValue>),
    Map(BTreeMap<String, StructuredValue>),
}

impl Default for StructuredValue {
    fn default() -> Self {
        Self::Map(BTreeMap::new())
    }
}

impl StructuredValue {
    #[must_use]
    pub fn depth(&self) -> usize {
        match self {
            Self::Null | Self::Boolean(_) | Self::Integer(_) | Self::Text(_) => 1,
            Self::List(items) => 1 + items.iter().map(Self::depth).max().unwrap_or(0),
            Self::Map(entries) => 1 + entries.values().map(Self::depth).max().unwrap_or(0),
        }
    }
    #[must_use]
    pub fn node_count(&self) -> usize {
        1 + match self {
            Self::Null | Self::Boolean(_) | Self::Integer(_) | Self::Text(_) => 0,
            Self::List(items) => items.iter().map(Self::node_count).sum(),
            Self::Map(entries) => entries.values().map(Self::node_count).sum(),
        }
    }
    pub fn validate(&self, path: &str) -> Result<(), WidgetValidationError> {
        if self.depth() > MAX_STRUCTURED_DEPTH {
            return Err(WidgetValidationError::new(
                path,
                format!("is nested deeper than {MAX_STRUCTURED_DEPTH} levels"),
            ));
        }
        if self.node_count() > MAX_STRUCTURED_NODES {
            return Err(WidgetValidationError::new(
                path,
                format!("contains more than {MAX_STRUCTURED_NODES} nodes"),
            ));
        }
        self.validate_keys(path)
    }
    fn validate_keys(&self, path: &str) -> Result<(), WidgetValidationError> {
        match self {
            Self::Null | Self::Boolean(_) | Self::Integer(_) | Self::Text(_) => Ok(()),
            Self::List(items) => items
                .iter()
                .enumerate()
                .try_for_each(|(index, item)| item.validate_keys(&format!("{path}[{index}]"))),
            Self::Map(entries) => entries.iter().try_for_each(|(key, value)| {
                if key.is_empty() || key.chars().count() > MAX_STRUCTURED_KEY_LENGTH {
                    return Err(WidgetValidationError::new(
                        path,
                        format!("keys must contain 1 to {MAX_STRUCTURED_KEY_LENGTH} characters"),
                    ));
                }
                value.validate_keys(&format!("{path}.{key}"))
            }),
        }
    }
    #[must_use]
    pub fn get(&self, key: &str) -> Option<&StructuredValue> {
        match self {
            Self::Map(entries) => entries.get(key),
            _ => None,
        }
    }
}

/// Versioned presentation configuration. Unknown keys and unknown versions remain in `body`
/// so an unrelated metadata edit cannot drop data this build does not understand.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct WidgetConfiguration {
    pub version: u32,
    pub body: StructuredValue,
}

impl WidgetConfiguration {
    #[must_use]
    pub fn new(body: StructuredValue) -> Self {
        Self {
            version: WIDGET_CONFIGURATION_VERSION,
            body,
        }
    }
    #[must_use]
    pub fn empty() -> Self {
        Self::new(StructuredValue::Map(BTreeMap::new()))
    }
    pub fn validate(&self) -> Result<(), WidgetValidationError> {
        self.body.validate("configuration")
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WidgetSize {
    Small,
    #[default]
    Medium,
    Large,
    Full,
}

/// Ordered responsive sizing hints plus preserved extensible layout metadata. This is not a
/// free-form coordinate canvas.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct WidgetLayout {
    pub version: u32,
    pub size: WidgetSize,
    pub hints: StructuredValue,
}

impl Default for WidgetLayout {
    fn default() -> Self {
        Self {
            version: WIDGET_LAYOUT_VERSION,
            size: WidgetSize::default(),
            hints: StructuredValue::Map(BTreeMap::new()),
        }
    }
}

impl WidgetLayout {
    pub fn validate(&self) -> Result<(), WidgetValidationError> {
        self.hints.validate("layout.hints")
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct WidgetDefinition {
    pub id: WidgetId,
    pub collection_id: CollectionSchemaId,
    pub widget_type: WidgetType,
    pub query_id: QueryId,
    pub title: String,
    pub configuration: WidgetConfiguration,
    pub layout: WidgetLayout,
    pub order: i64,
    pub deleted: bool,
}

impl WidgetDefinition {
    /// Validates the parts of a definition that do not depend on other synchronized entities.
    /// Collection and query references are checked against the decoded snapshot by the caller.
    pub fn validate_standalone(&self) -> Result<(), WidgetValidationError> {
        validate_widget_type(self.widget_type.as_str())?;
        validate_title(&self.title)?;
        self.configuration.validate()?;
        self.layout.validate()
    }
}

pub fn validate_title(value: &str) -> Result<(), WidgetValidationError> {
    let length = value.trim().chars().count();
    if length > MAX_WIDGET_TITLE_LENGTH {
        Err(WidgetValidationError::new(
            "title",
            format!("must contain at most {MAX_WIDGET_TITLE_LENGTH} non-padding characters"),
        ))
    } else {
        Ok(())
    }
}

/// A granular widget metadata update. Each present field maps to its own HLC register so
/// independent edits compose and an omitted field — notably an unknown widget's opaque
/// configuration — is never rewritten.
#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct WidgetUpdate {
    pub id: WidgetId,
    pub collection_id: CollectionSchemaId,
    pub title: Option<String>,
    pub query_id: Option<QueryId>,
    pub configuration: Option<WidgetConfiguration>,
    pub layout: Option<WidgetLayout>,
    pub order: Option<i64>,
}

impl WidgetUpdate {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.query_id.is_none()
            && self.configuration.is_none()
            && self.layout.is_none()
            && self.order.is_none()
    }
    /// Applies this update to a decoded definition. Widget type and tombstone are never mutable
    /// through an update, so an unsupported definition cannot be destructively coerced.
    #[must_use]
    pub fn applied_to(&self, definition: &WidgetDefinition) -> WidgetDefinition {
        WidgetDefinition {
            title: self
                .title
                .clone()
                .unwrap_or_else(|| definition.title.clone()),
            query_id: self.query_id.unwrap_or(definition.query_id),
            configuration: self
                .configuration
                .clone()
                .unwrap_or_else(|| definition.configuration.clone()),
            layout: self
                .layout
                .clone()
                .unwrap_or_else(|| definition.layout.clone()),
            order: self.order.unwrap_or(definition.order),
            ..definition.clone()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widget_ids_are_canonical_uuidv7() {
        let id = WidgetId::new();
        assert_eq!(id.to_string().parse::<WidgetId>().unwrap(), id);
        assert_eq!(id.as_uuid().get_version_num(), 7);
        for invalid in [
            "",
            "not-a-uuid",
            "550e8400-e29b-41d4-a716-446655440000",
            &id.as_uuid().simple().to_string(),
        ] {
            assert!(
                invalid.parse::<WidgetId>().is_err(),
                "{invalid} must be rejected"
            );
        }
    }

    #[test]
    fn widget_types_accept_namespaces_and_reject_ambiguous_strings() {
        for valid in [
            "core.aggregate-number",
            "core.line-chart",
            "core.bar-chart",
            "core.scatter-plot",
            "com.example.calendar-heatmap",
            "com.example.future-widget",
            "dev.local.widget_v2",
        ] {
            assert_eq!(WidgetType::new(valid).unwrap().as_str(), valid);
        }
        for invalid in [
            "",
            "aggregate-number",
            "core.",
            ".core",
            "core..line-chart",
            "Core.LineChart",
            "core.line chart",
            "core.-line",
            &format!("core.{}", "a".repeat(65)),
            &format!("core.{}", "a".repeat(MAX_WIDGET_TYPE_LENGTH)),
        ] {
            assert!(
                WidgetType::new(invalid).is_err(),
                "{invalid} must be rejected"
            );
        }
    }

    #[test]
    fn structured_values_round_trip_losslessly() {
        let value = StructuredValue::Map(BTreeMap::from([
            ("null".into(), StructuredValue::Null),
            ("boolean".into(), StructuredValue::Boolean(true)),
            ("integer".into(), StructuredValue::Integer(i64::MIN)),
            ("text".into(), StructuredValue::Text("2576.50".into())),
            (
                "list".into(),
                StructuredValue::List(vec![
                    StructuredValue::Integer(-2350),
                    StructuredValue::Text("−".into()),
                ]),
            ),
            (
                "map".into(),
                StructuredValue::Map(BTreeMap::from([(
                    "nested".into(),
                    StructuredValue::Integer(i64::MAX),
                )])),
            ),
        ]));
        let encoded = serde_json::to_string(&value).unwrap();
        assert_eq!(
            serde_json::from_str::<StructuredValue>(&encoded).unwrap(),
            value
        );
        assert_eq!(value.depth(), 3);
        assert_eq!(value.node_count(), 10);
        assert_eq!(
            value.get("map").and_then(|item| item.get("nested")),
            Some(&StructuredValue::Integer(i64::MAX))
        );
    }

    #[test]
    fn structured_values_reject_unbounded_growth() {
        let mut deep = StructuredValue::Null;
        for _ in 0..MAX_STRUCTURED_DEPTH {
            deep = StructuredValue::List(vec![deep]);
        }
        assert!(deep.validate("configuration").is_err());
        let wide = StructuredValue::List(vec![StructuredValue::Null; MAX_STRUCTURED_NODES + 1]);
        assert!(wide.validate("configuration").is_err());
        let keyed = StructuredValue::Map(BTreeMap::from([(String::new(), StructuredValue::Null)]));
        assert!(keyed.validate("configuration").is_err());
    }

    #[test]
    fn definitions_validate_type_title_and_bounded_configuration() {
        let definition = WidgetDefinition {
            id: WidgetId::new(),
            collection_id: CollectionSchemaId::new(),
            widget_type: WidgetType::new("core.aggregate-number").unwrap(),
            query_id: QueryId::new(),
            title: "Average Intensity".into(),
            configuration: WidgetConfiguration::new(StructuredValue::Map(BTreeMap::from([(
                "unknown_future_key".into(),
                StructuredValue::Integer(7),
            )]))),
            layout: WidgetLayout::default(),
            order: 0,
            deleted: false,
        };
        definition.validate_standalone().unwrap();
        let overlong = WidgetDefinition {
            title: "a".repeat(MAX_WIDGET_TITLE_LENGTH + 1),
            ..definition.clone()
        };
        assert_eq!(overlong.validate_standalone().unwrap_err().path, "title");
        // Padding never counts toward the limit, so a whitespace title stays representable.
        let padded = WidgetDefinition {
            title: "  Average  ".into(),
            ..definition.clone()
        };
        padded.validate_standalone().unwrap();
        let unknown = WidgetDefinition {
            widget_type: WidgetType::new("com.example.future-widget").unwrap(),
            ..definition
        };
        unknown.validate_standalone().unwrap();
    }
}
