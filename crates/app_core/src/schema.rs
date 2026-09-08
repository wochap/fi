use std::{collections::HashSet, fmt, str::FromStr};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{
    error::DomainError,
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
    FixedDecimal { scale: u8 },
    Boolean,
    Date,
    DateTime,
    Duration,
    Enum,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct ValidationMetadata {
    pub min_integer: Option<i64>,
    pub max_integer: Option<i64>,
    pub min_length: Option<u32>,
    pub max_length: Option<u32>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct DisplayMetadata {
    pub multiline: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct EnumOption {
    pub id: EnumOptionId,
    pub label: String,
    pub order: i64,
    pub deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FieldDefinition {
    pub id: FieldId,
    pub name: String,
    pub field_type: FieldType,
    pub required: bool,
    pub default: Option<FieldValue>,
    pub validation: ValidationMetadata,
    pub display: DisplayMetadata,
    pub order: i64,
    pub deleted: bool,
    pub enum_options: Vec<EnumOption>,
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
        if self.display.multiline && !matches!(self.field_type, FieldType::Text) {
            return Err(invalid("multiline", "is valid only for Text fields"));
        }
        if matches!(self.field_type, FieldType::Enum) {
            let mut ids = HashSet::new();
            for option in &self.enum_options {
                if !ids.insert(option.id) {
                    return Err(invalid("enum_option_id", "must be unique"));
                }
                validate_name("enum_option_label", &option.label)?;
            }
        } else if !self.enum_options.is_empty() {
            return Err(invalid("enum_options", "are valid only for Enum fields"));
        }
        if let Some(default) = &self.default {
            self.validate_value(default, true)?;
        }
        Ok(())
    }

    pub fn validate_value(
        &self,
        value: &FieldValue,
        default_context: bool,
    ) -> Result<(), DomainError> {
        if matches!(value, FieldValue::Null) {
            return if self.required {
                Err(invalid("value", "required fields cannot be null"))
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
        );
        if !type_matches {
            return Err(invalid(
                if default_context { "default" } else { "value" },
                "type does not match field definition",
            ));
        }
        match value {
            FieldValue::Text(text) => {
                let length = text.chars().count() as u32;
                if self.validation.min_length.is_some_and(|min| length < min)
                    || self.validation.max_length.is_some_and(|max| length > max)
                {
                    return Err(invalid("value", "text length is outside the allowed range"));
                }
            }
            FieldValue::Integer(number)
            | FieldValue::FixedDecimal(number)
            | FieldValue::Date(number)
            | FieldValue::DateTime(number)
            | FieldValue::Duration(number) => {
                if self.validation.min_integer.is_some_and(|min| *number < min)
                    || self.validation.max_integer.is_some_and(|max| *number > max)
                {
                    return Err(invalid("value", "number is outside the allowed range"));
                }
            }
            FieldValue::Enum(id) => {
                if !self
                    .enum_options
                    .iter()
                    .any(|option| option.id == *id && !option.deleted)
                {
                    return Err(invalid("value", "enum option is not an active member"));
                }
            }
            FieldValue::Null | FieldValue::Boolean(_) => {}
        }
        Ok(())
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

    fn text_field(name: &str, order: i64) -> FieldDefinition {
        FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type: FieldType::Text,
            required: false,
            default: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order,
            deleted: false,
            enum_options: Vec::new(),
        }
    }
}
