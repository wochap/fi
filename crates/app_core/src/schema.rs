use std::{collections::HashSet, fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    error::{DomainError, IssueCode, ValidationIssue},
    values::{FieldValue, MAX_DECIMAL_SCALE},
};

macro_rules! uuid_v7_id {
    ($name:ident, $field:literal) => {
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
        #[serde(transparent)]
        pub struct $name(Uuid);

        impl $name {
            #[must_use]
            pub fn new() -> Self {
                Self(Uuid::now_v7())
            }
            #[must_use]
            pub const fn as_uuid(self) -> Uuid {
                self.0
            }
        }
        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }
        impl FromStr for $name {
            type Err = DomainError;
            fn from_str(value: &str) -> Result<Self, Self::Err> {
                let uuid = Uuid::parse_str(value)
                    .map_err(|_| invalid($field, "must be a canonical UUIDv7"))?;
                if uuid.get_version_num() != 7 || uuid.hyphenated().to_string() != value {
                    return Err(invalid($field, "must be a canonical UUIDv7"));
                }
                Ok(Self(uuid))
            }
        }
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: serde::Deserializer<'de>,
            {
                String::deserialize(deserializer)?
                    .parse()
                    .map_err(serde::de::Error::custom)
            }
        }
    };
}

uuid_v7_id!(CollectionSchemaId, "collection_schema_id");
uuid_v7_id!(FieldId, "field_id");
uuid_v7_id!(EnumOptionId, "enum_option_id");

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum FieldType {
    Text,
    Integer,
    FixedDecimal {
        scale: u8,
    },
    Boolean,
    Date,
    DateTime,
    Duration,
    Enum,
    /// "Choices": a set of the field's options. Shares `enum_options` with [`FieldType::Enum`].
    EnumSet,
}

impl FieldType {
    /// Whether the type carries an option list (Choice or Choices).
    #[must_use]
    pub const fn has_options(&self) -> bool {
        matches!(self, Self::Enum | Self::EnumSet)
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct ValidationMetadata {
    #[serde(default)]
    pub min_integer: Option<i64>,
    #[serde(default)]
    pub max_integer: Option<i64>,
    #[serde(default)]
    pub min_length: Option<u32>,
    #[serde(default)]
    pub max_length: Option<u32>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct DisplayMetadata {
    #[serde(default)]
    pub multiline: bool,
    /// Integer-only presentation hint; requires both integer bounds.
    #[serde(default)]
    pub slider: bool,
    /// Slider step; `None` reads as 1. Must divide `max - min` exactly.
    #[serde(default)]
    pub slider_step: Option<u32>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EnumOption {
    pub id: EnumOptionId,
    pub label: String,
    pub order: i64,
    pub deleted: bool,
    /// Set on a removed option that was merged into another option of the same field. Additive:
    /// a device that does not know it reads an ordinary removed option.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub merged_into: Option<EnumOptionId>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FieldDefinition {
    pub id: FieldId,
    pub name: String,
    pub field_type: FieldType,
    pub required: bool,
    pub default: Option<FieldValue>,
    /// Date-only default: whole days added to the record's creation day. Stored as an
    /// additive key so a device that does not know it reads the field as having no default.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_relative_days: Option<i32>,
    pub validation: ValidationMetadata,
    pub display: DisplayMetadata,
    pub order: i64,
    pub deleted: bool,
    pub enum_options: Vec<EnumOption>,
    /// Choice/Choices only: records may add options to this field when they are saved.
    /// Additive: a definition without the key reads as off.
    #[serde(default, skip_serializing_if = "is_false")]
    pub allow_options_from_records: bool,
}

#[allow(clippy::trivially_copy_pass_by_ref)]
fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CollectionSchema {
    pub id: CollectionSchemaId,
    pub name: String,
    pub description: String,
    pub fields: Vec<FieldDefinition>,
    pub deleted: bool,
}

impl CollectionSchema {
    pub fn validate(&self) -> Result<(), DomainError> {
        validate_name("collection_name", &self.name)?;
        if self.description.chars().count() > 2_000 {
            return Err(invalid(
                "description",
                "must contain at most 2000 characters",
            ));
        }
        let mut ids = HashSet::new();
        for field in &self.fields {
            if !ids.insert(field.id) {
                return Err(invalid("field_id", "must be unique"));
            }
            field.validate()?;
        }
        Ok(())
    }

    #[must_use]
    pub fn ordered_fields(&self) -> Vec<&FieldDefinition> {
        let mut fields: Vec<_> = self.fields.iter().filter(|field| !field.deleted).collect();
        fields.sort_by_key(|field| (field.order, field.id));
        fields
    }
}

impl FieldDefinition {
    pub fn validate(&self) -> Result<(), DomainError> {
        validate_name("field_name", &self.name)?;
        if let FieldType::FixedDecimal { scale } = self.field_type
            && scale > MAX_DECIMAL_SCALE
        {
            return Err(invalid(
                "scale",
                format!("must be at most {MAX_DECIMAL_SCALE}"),
            ));
        }
        if self
            .validation
            .min_integer
            .zip(self.validation.max_integer)
            .is_some_and(|(min, max)| min > max)
        {
            return Err(invalid("numeric_range", "minimum must not exceed maximum"));
        }
        if self
            .validation
            .min_length
            .zip(self.validation.max_length)
            .is_some_and(|(min, max)| min > max)
        {
            return Err(invalid("length_range", "minimum must not exceed maximum"));
        }
        if self.allow_options_from_records && !self.field_type.has_options() {
            return Err(invalid(
                "allow_options_from_records",
                "is valid only for Choice and Choices fields",
            ));
        }
        if self.display.multiline && !matches!(self.field_type, FieldType::Text) {
            return Err(invalid("multiline", "is valid only for Text fields"));
        }
        if self.display.slider {
            if !matches!(self.field_type, FieldType::Integer) {
                return Err(invalid("slider", "is valid only for Integer fields"));
            }
            if self.validation.min_integer.is_none() || self.validation.max_integer.is_none() {
                return Err(invalid("slider", "requires both a minimum and a maximum"));
            }
        }
        if let Some(step) = self.display.slider_step {
            if step == 0 {
                return Err(invalid("slider_step", "must be positive"));
            }
            if !self.display.slider {
                return Err(invalid("slider_step", "requires the slider flag"));
            }
            if let Some((min, max)) = self.validation.min_integer.zip(self.validation.max_integer)
                && (i128::from(max) - i128::from(min)) % i128::from(step) != 0
            {
                return Err(invalid(
                    "slider_step",
                    "must divide the distance between minimum and maximum exactly",
                ));
            }
        }
        if self.field_type.has_options() {
            let mut ids = HashSet::new();
            for option in &self.enum_options {
                if !ids.insert(option.id) {
                    return Err(invalid("enum_option_id", "must be unique"));
                }
                validate_name("enum_option_label", &option.label)?;
                // Removed options are never exported, so only active labels must split cleanly.
                if !option.deleted {
                    self.validate_option_label(&option.label)?;
                }
            }
        } else if !self.enum_options.is_empty() {
            return Err(invalid("enum_options", "are valid only for Enum fields"));
        }
        if let Some(FieldValue::EnumSet(ids)) = &self.default
            && ids.is_empty()
        {
            return Err(invalid("default", "must pick at least one option"));
        }
        if let Some(default) = &self.default {
            self.validate_value(default)
                .map_err(|issue| invalid("default", issue.message))?;
        }
        // The resolved date depends on each record's creation day, so its range is checked when
        // a record is created, not here.
        if self.default_relative_days.is_some() {
            if !matches!(self.field_type, FieldType::Date) {
                return Err(invalid(
                    "default",
                    "a relative default is valid only for Date fields",
                ));
            }
            if self.default.is_some() {
                return Err(invalid(
                    "default",
                    "cannot have both a fixed and a relative default",
                ));
            }
        }
        Ok(())
    }

    /// Whether the field reads as having a default, fixed or relative.
    #[must_use]
    pub fn has_default(&self) -> bool {
        self.default.is_some() || self.default_relative_days.is_some()
    }

    /// The default for a record created on `creation_day` (days since the Unix epoch, UTC).
    #[must_use]
    pub fn resolved_default(&self, creation_day: i64) -> Option<FieldValue> {
        self.default.clone().or_else(|| {
            self.default_relative_days
                .map(|days| FieldValue::Date(creation_day.saturating_add(i64::from(days))))
        })
    }

    /// Checks one value against this field. The returned issue carries a
    /// specific, id-free message and no field context; callers attach it.
    pub fn validate_value(&self, value: &FieldValue) -> Result<(), ValidationIssue> {
        if matches!(value, FieldValue::Null) {
            return if self.required {
                Err(ValidationIssue::new(IssueCode::Required, "Required"))
            } else {
                Ok(())
            };
        }
        let type_matches = matches!(
            (&self.field_type, value),
            (FieldType::Text, FieldValue::Text(_))
                | (FieldType::Integer, FieldValue::Integer(_))
                | (FieldType::FixedDecimal { .. }, FieldValue::FixedDecimal(_))
                | (FieldType::Boolean, FieldValue::Boolean(_))
                | (FieldType::Date, FieldValue::Date(_))
                | (FieldType::DateTime, FieldValue::DateTime(_))
                | (FieldType::Duration, FieldValue::Duration(_))
                | (FieldType::Enum, FieldValue::Enum(_))
                | (FieldType::EnumSet, FieldValue::EnumSet(_))
        );
        if !type_matches {
            return Err(ValidationIssue::new(
                IssueCode::TypeMismatch,
                "Value does not match this field's type",
            ));
        }
        match value {
            FieldValue::Text(text) => {
                let length = u32::try_from(text.chars().count()).unwrap_or(u32::MAX);
                let ValidationMetadata {
                    min_length,
                    max_length,
                    ..
                } = self.validation;
                if min_length.is_some_and(|min| length < min)
                    || max_length.is_some_and(|max| length > max)
                {
                    return Err(ValidationIssue::new(
                        IssueCode::Length,
                        length_message(min_length, max_length),
                    ));
                }
            }
            FieldValue::Integer(number)
            | FieldValue::FixedDecimal(number)
            | FieldValue::Date(number)
            | FieldValue::DateTime(number)
            | FieldValue::Duration(number) => {
                let ValidationMetadata {
                    min_integer,
                    max_integer,
                    ..
                } = self.validation;
                if min_integer.is_some_and(|min| *number < min)
                    || max_integer.is_some_and(|max| *number > max)
                {
                    return Err(ValidationIssue::new(
                        IssueCode::OutOfRange,
                        range_message(
                            min_integer.map(|min| self.format_bound(min)),
                            max_integer.map(|max| self.format_bound(max)),
                        ),
                    ));
                }
            }
            FieldValue::Enum(id) => {
                if !self
                    .enum_options
                    .iter()
                    .any(|option| option.id == *id && !option.deleted)
                {
                    return Err(ValidationIssue::new(
                        IssueCode::InactiveOption,
                        "Pick an active option",
                    ));
                }
            }
            FieldValue::EnumSet(ids) => {
                if ids.is_empty() {
                    return if self.required {
                        Err(ValidationIssue::new(IssueCode::Required, "Required"))
                    } else {
                        Ok(())
                    };
                }
                let mut seen = HashSet::new();
                for id in ids {
                    if !seen.insert(id) {
                        return Err(ValidationIssue::new(
                            IssueCode::Invalid,
                            "An option is picked twice",
                        ));
                    }
                    if !self.is_active_option(*id) {
                        return Err(ValidationIssue::new(
                            IssueCode::InactiveOption,
                            "Pick active options",
                        ));
                    }
                }
            }
            FieldValue::Null | FieldValue::Boolean(_) => {}
        }
        Ok(())
    }

    fn is_active_option(&self, id: EnumOptionId) -> bool {
        self.enum_options
            .iter()
            .any(|option| option.id == id && !option.deleted)
    }

    /// Checks a label for an option of this field: Choices labels can't hold `;`, the CSV
    /// separator of a set.
    pub fn validate_option_label(&self, label: &str) -> Result<(), DomainError> {
        if matches!(self.field_type, FieldType::EnumSet) && label.contains(';') {
            return Err(invalid(
                "enum_option_label",
                format!("“{label}” can't contain “;” in a Choices field"),
            ));
        }
        Ok(())
    }

    /// Orders option ids by this field's option order (removed options included), id as the
    /// tie-breaker; unknown ids sort last by id.
    pub fn sort_option_ids(&self, ids: &mut [EnumOptionId]) {
        ids.sort_by_key(|id| {
            let order = self
                .enum_options
                .iter()
                .find(|option| option.id == *id)
                .map_or(i64::MAX, |option| option.order);
            (order, *id)
        });
    }

    /// Like [`Self::validate_value`], but a Choice value pointing at a removed option of this
    /// field is accepted: a stored record keeps the option it already holds.
    pub fn validate_kept_value(&self, value: &FieldValue) -> Result<(), ValidationIssue> {
        if let FieldValue::EnumSet(ids) = value
            && matches!(self.field_type, FieldType::EnumSet)
            && ids.iter().any(|id| {
                self.enum_options
                    .iter()
                    .any(|option| option.id == *id && option.deleted)
            })
        {
            // Members already held may be removed options; the rest must still be active.
            let active: Vec<_> = ids
                .iter()
                .copied()
                .filter(|id| {
                    !self
                        .enum_options
                        .iter()
                        .any(|option| option.id == *id && option.deleted)
                })
                .collect();
            return if active.is_empty() {
                Ok(())
            } else {
                self.validate_value(&FieldValue::EnumSet(active))
            };
        }
        if let FieldValue::Enum(id) = value
            && matches!(self.field_type, FieldType::Enum)
            && self
                .enum_options
                .iter()
                .any(|option| option.id == *id && option.deleted)
        {
            return Ok(());
        }
        self.validate_value(value)
    }

    fn format_bound(&self, bound: i64) -> String {
        match self.field_type {
            FieldType::FixedDecimal { scale } => crate::values::FixedDecimal::new(bound, scale)
                .map_or_else(|_| bound.to_string(), |decimal| decimal.to_string()),
            _ => bound.to_string(),
        }
    }

    #[must_use]
    pub fn ordered_enum_options(&self) -> Vec<&EnumOption> {
        let mut options: Vec<_> = self
            .enum_options
            .iter()
            .filter(|option| !option.deleted)
            .collect();
        options.sort_by_key(|option| (option.order, option.id));
        options
    }
}

fn characters(count: u32) -> String {
    if count == 1 {
        "1 character".into()
    } else {
        format!("{count} characters")
    }
}

fn length_message(min: Option<u32>, max: Option<u32>) -> String {
    match (min, max) {
        (Some(min), Some(max)) if min == max => format!("Must be exactly {}", characters(min)),
        (Some(min), Some(max)) => format!("Must be {min}–{max} characters"),
        (Some(min), None) => format!("Must be at least {}", characters(min)),
        (None, Some(max)) => format!("Must be at most {}", characters(max)),
        (None, None) => "Length is not allowed".into(),
    }
}

fn range_message(min: Option<String>, max: Option<String>) -> String {
    match (min, max) {
        (Some(min), Some(max)) => format!("Must be between {min} and {max}"),
        (Some(min), None) => format!("Must be at least {min}"),
        (None, Some(max)) => format!("Must be at most {max}"),
        (None, None) => "Value is out of range".into(),
    }
}

fn validate_name(field: &'static str, value: &str) -> Result<(), DomainError> {
    let length = value.trim().chars().count();
    if length == 0 || length > 120 {
        Err(invalid(
            field,
            "must contain 1 to 120 non-padding characters",
        ))
    } else {
        Ok(())
    }
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

    #[test]
    fn ids_are_canonical_v7_and_serde_round_trip() {
        let ids = [
            CollectionSchemaId::new().to_string(),
            FieldId::new().to_string(),
            EnumOptionId::new().to_string(),
        ];
        assert_eq!(
            ids[0].parse::<CollectionSchemaId>().unwrap().to_string(),
            ids[0]
        );
        assert_eq!(ids[1].parse::<FieldId>().unwrap().to_string(), ids[1]);
        assert_eq!(ids[2].parse::<EnumOptionId>().unwrap().to_string(), ids[2]);
        assert!(ids[0].to_uppercase().parse::<CollectionSchemaId>().is_err());
        let encoded =
            serde_json::to_string(&ids[0].parse::<CollectionSchemaId>().unwrap()).unwrap();
        assert_eq!(
            serde_json::from_str::<CollectionSchemaId>(&encoded)
                .unwrap()
                .to_string(),
            ids[0]
        );
        assert!(
            serde_json::from_str::<CollectionSchemaId>("\"550e8400-e29b-41d4-a716-446655440000\"")
                .is_err()
        );
    }

    #[test]
    fn definition_validation_and_ordering_are_deterministic() {
        let mut first = text_field("First", 4);
        let mut second = text_field("Second", 4);
        if first.id > second.id {
            std::mem::swap(&mut first, &mut second);
        }
        let schema = CollectionSchema {
            id: CollectionSchemaId::new(),
            name: "Things".into(),
            description: String::new(),
            fields: vec![second.clone(), first.clone()],
            deleted: false,
        };
        schema.validate().unwrap();
        assert_eq!(
            schema
                .ordered_fields()
                .iter()
                .map(|field| field.id)
                .collect::<Vec<_>>(),
            vec![first.id, second.id]
        );
        let mut invalid = first;
        invalid.validation = ValidationMetadata {
            min_integer: None,
            max_integer: None,
            min_length: Some(5),
            max_length: Some(2),
        };
        assert!(invalid.validate().is_err());
    }

    #[test]
    fn metadata_missing_keys_deserialize_to_defaults() {
        assert_eq!(
            serde_json::from_str::<DisplayMetadata>(r#"{"multiline":false}"#).unwrap(),
            DisplayMetadata::default()
        );
        assert_eq!(
            serde_json::from_str::<DisplayMetadata>("{}").unwrap(),
            DisplayMetadata::default()
        );
        assert_eq!(
            serde_json::from_str::<ValidationMetadata>("{}").unwrap(),
            ValidationMetadata::default()
        );
    }

    #[test]
    fn slider_requires_integer_with_both_bounds() {
        let mut field = text_field("Pain", 1);
        field.display.slider = true;
        assert_slider_rejected(&field);

        field.field_type = FieldType::Integer;
        field.validation.max_integer = Some(5);
        assert_slider_rejected(&field);

        field.validation.min_integer = Some(1);
        field.validation.max_integer = None;
        assert_slider_rejected(&field);

        field.validation.max_integer = Some(5);
        field.validate().unwrap();
    }

    #[test]
    fn slider_step_defaults_to_none_and_round_trips() {
        let display = serde_json::from_str::<DisplayMetadata>(r#"{"slider":true}"#).unwrap();
        assert!(display.slider);
        assert_eq!(display.slider_step, None);
        let stepped = DisplayMetadata {
            multiline: false,
            slider: true,
            slider_step: Some(10),
        };
        let encoded = serde_json::to_string(&stepped).unwrap();
        assert!(encoded.contains(r#""slider_step":10"#));
        assert_eq!(
            serde_json::from_str::<DisplayMetadata>(&encoded).unwrap(),
            stepped
        );
    }

    #[test]
    fn slider_step_validation() {
        let mut field = text_field("Pain", 1);
        field.field_type = FieldType::Integer;
        field.validation.min_integer = Some(0);
        field.validation.max_integer = Some(100);
        field.display.slider_step = Some(10);
        assert_step_rejected(&field);

        field.display.slider = true;
        field.display.slider_step = Some(0);
        assert_step_rejected(&field);

        field.display.slider_step = Some(30);
        assert_step_rejected(&field);

        for step in [None, Some(1), Some(10), Some(100)] {
            field.display.slider_step = step;
            field.validate().unwrap();
        }
        field.validation.min_integer = Some(1);
        field.validation.max_integer = Some(5);
        field.display.slider_step = Some(4);
        field.validate().unwrap();
    }

    #[test]
    fn relative_default_is_date_only_and_exclusive_with_a_fixed_default() {
        let mut field = text_field("Due", 1);
        field.default_relative_days = Some(7);
        assert!(matches!(
            field.validate(),
            Err(DomainError::Invalid {
                field: "default",
                ..
            })
        ));
        field.field_type = FieldType::Date;
        field.validate().unwrap();
        field.default = Some(FieldValue::Date(20_000));
        assert!(matches!(
            field.validate(),
            Err(DomainError::Invalid {
                field: "default",
                ..
            })
        ));
        field.default = None;
        field.default_relative_days = Some(-3);
        field.validate().unwrap();
        assert!(field.has_default());
        assert_eq!(field.resolved_default(100), Some(FieldValue::Date(97)));
    }

    #[test]
    fn relative_default_is_additive_for_older_and_newer_decoders() {
        // The field shape before the relative default existed.
        #[derive(Deserialize)]
        #[allow(dead_code)]
        struct OlderFieldDefinition {
            id: FieldId,
            name: String,
            field_type: FieldType,
            required: bool,
            default: Option<FieldValue>,
            validation: ValidationMetadata,
            display: DisplayMetadata,
            order: i64,
            deleted: bool,
            enum_options: Vec<EnumOption>,
        }
        let mut field = text_field("Due", 1);
        field.field_type = FieldType::Date;
        field.default_relative_days = Some(7);
        let encoded = serde_json::to_string(&field).unwrap();
        assert!(encoded.contains(r#""default_relative_days":7"#));
        let older: OlderFieldDefinition = serde_json::from_str(&encoded).unwrap();
        assert_eq!(older.default, None);
        assert_eq!(older.id, field.id);
        assert_eq!(
            serde_json::from_str::<FieldDefinition>(&encoded).unwrap(),
            field
        );

        // A definition written without the key reads as no relative default, and a field
        // without one does not write the key.
        field.default_relative_days = None;
        let plain = serde_json::to_string(&field).unwrap();
        assert!(!plain.contains("default_relative_days"));
        assert_eq!(
            serde_json::from_str::<FieldDefinition>(&plain)
                .unwrap()
                .default_relative_days,
            None
        );
    }

    #[test]
    fn choices_fields_round_trip_and_validate_labels_and_defaults() {
        let mut tags = text_field("tags", 0);
        tags.field_type = FieldType::EnumSet;
        tags.enum_options = ["work", "urgent", "gone"]
            .iter()
            .enumerate()
            .map(|(order, label)| EnumOption {
                merged_into: None,
                id: EnumOptionId::new(),
                label: (*label).into(),
                order: order as i64,
                deleted: *label == "gone",
            })
            .collect();
        tags.default = Some(FieldValue::EnumSet(vec![tags.enum_options[0].id]));
        tags.validate().unwrap();
        let encoded = serde_json::to_string(&tags).unwrap();
        assert!(encoded.contains(r#""field_type":{"kind":"enum_set"}"#));
        assert_eq!(
            serde_json::from_str::<FieldDefinition>(&encoded).unwrap(),
            tags
        );

        for default in [
            FieldValue::EnumSet(vec![]),
            FieldValue::EnumSet(vec![tags.enum_options[2].id]),
            FieldValue::EnumSet(vec![EnumOptionId::new()]),
            FieldValue::Enum(tags.enum_options[0].id),
        ] {
            let mut field = tags.clone();
            field.default = Some(default);
            assert!(matches!(
                field.validate(),
                Err(DomainError::Invalid {
                    field: "default",
                    ..
                })
            ));
        }
        let mut field = tags.clone();
        field.enum_options[1].label = "food; drinks".into();
        assert!(matches!(
            field.validate(),
            Err(DomainError::Invalid {
                field: "enum_option_label",
                ..
            })
        ));
        // A removed label is never exported, and a Choice label may hold `;`.
        field.enum_options[1].deleted = true;
        field.validate().unwrap();
        field.enum_options[1].deleted = false;
        field.field_type = FieldType::Enum;
        field.default = None;
        field.validate().unwrap();

        // Values: active members only, kept removed members on stored records, required non-empty.
        let removed = tags.enum_options[2].id;
        let active = tags.enum_options[0].id;
        assert!(
            tags.validate_value(&FieldValue::EnumSet(vec![active, removed]))
                .is_err()
        );
        tags.validate_kept_value(&FieldValue::EnumSet(vec![active, removed]))
            .unwrap();
        tags.validate_value(&FieldValue::EnumSet(vec![])).unwrap();
        tags.required = true;
        assert_eq!(
            tags.validate_value(&FieldValue::EnumSet(vec![]))
                .unwrap_err()
                .code,
            IssueCode::Required
        );
    }

    #[test]
    fn options_from_records_setting_round_trips_and_is_additive() {
        let mut field = text_field("category", 0);
        field.field_type = FieldType::Enum;
        let plain = serde_json::to_string(&field).unwrap();
        assert!(!plain.contains("allow_options_from_records"));
        let read: FieldDefinition = serde_json::from_str(&plain).unwrap();
        assert!(!read.allow_options_from_records);

        field.allow_options_from_records = true;
        field.validate().unwrap();
        let encoded = serde_json::to_string(&field).unwrap();
        assert!(encoded.contains(r#""allow_options_from_records":true"#));
        assert_eq!(
            serde_json::from_str::<FieldDefinition>(&encoded).unwrap(),
            field
        );
        field.field_type = FieldType::EnumSet;
        field.validate().unwrap();

        field.field_type = FieldType::Text;
        assert!(matches!(
            field.validate(),
            Err(DomainError::Invalid {
                field: "allow_options_from_records",
                ..
            })
        ));
    }

    #[test]
    fn merged_into_is_additive_for_older_and_newer_decoders() {
        #[derive(Deserialize)]
        #[allow(dead_code)]
        struct OlderEnumOption {
            id: EnumOptionId,
            label: String,
            order: i64,
            deleted: bool,
        }
        let keep = EnumOptionId::new();
        let merged = EnumOption {
            id: EnumOptionId::new(),
            label: "groceries".into(),
            order: 1,
            deleted: true,
            merged_into: Some(keep),
        };
        let encoded = serde_json::to_string(&merged).unwrap();
        assert!(encoded.contains("merged_into"));
        let older: OlderEnumOption = serde_json::from_str(&encoded).unwrap();
        assert!(older.deleted);
        assert_eq!(
            serde_json::from_str::<EnumOption>(&encoded).unwrap(),
            merged
        );
        let plain = r#"{"id":"%ID%","label":"a","order":0,"deleted":false}"#
            .replace("%ID%", &keep.to_string());
        let read: EnumOption = serde_json::from_str(&plain).unwrap();
        assert_eq!(read.merged_into, None);
        let rewritten = serde_json::to_string(&read).unwrap();
        assert!(!rewritten.contains("merged_into"));
    }

    fn assert_step_rejected(field: &FieldDefinition) {
        assert!(matches!(
            field.validate(),
            Err(DomainError::Invalid {
                field: "slider_step",
                ..
            })
        ));
    }

    fn assert_slider_rejected(field: &FieldDefinition) {
        assert!(matches!(
            field.validate(),
            Err(DomainError::Invalid {
                field: "slider",
                ..
            })
        ));
    }

    fn text_field(name: &str, order: i64) -> FieldDefinition {
        FieldDefinition {
            allow_options_from_records: false,
            id: FieldId::new(),
            name: name.into(),
            field_type: FieldType::Text,
            required: false,
            default: None,
            default_relative_days: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order,
            deleted: false,
            enum_options: Vec::new(),
        }
    }
}
