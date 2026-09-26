use std::{collections::BTreeMap, str::FromStr};

use app_core::{CollectionSchemaId, FieldId, RecordId};

use crate::api::{
    lifecycle::core,
    models::{
        BootstrapDto, BridgeError, BridgeIssueDto, CollectionDto, CollectionSchemaDto,
        FieldDefinitionDto, FieldValueDto, RecordDto,
    },
};

pub async fn create_new_dataset() -> Result<BootstrapDto, BridgeError> {
    let app = core().await?;
    app.create_new_dataset().await.map_err(BridgeError::from)?;
    Ok(BootstrapDto::from_app(&app))
}
pub async fn create_collection(name: String, description: String) -> Result<String, BridgeError> {
    core()
        .await?
        .create_collection(name, description)
        .await
        .map(|id| id.to_string())
        .map_err(Into::into)
}
pub async fn rename_collection(id: String, name: String) -> Result<(), BridgeError> {
    core()
        .await?
        .rename_collection(parse_collection(&id)?, name)
        .await
        .map_err(Into::into)
}
/// Copies a collection's structure (no records) and returns the new collection id.
pub async fn clone_collection(source_id: String, name: String) -> Result<String, BridgeError> {
    core()
        .await?
        .clone_collection(parse_collection(&source_id)?, name)
        .await
        .map(|id| id.to_string())
        .map_err(Into::into)
}
pub async fn delete_collection(id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .delete_collection(parse_collection(&id)?)
        .await
        .map_err(Into::into)
}
pub async fn list_collections() -> Result<Vec<CollectionDto>, BridgeError> {
    core()
        .await?
        .collections()
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}
pub async fn get_collection_schema(id: String) -> Result<Option<CollectionSchemaDto>, BridgeError> {
    core()
        .await?
        .collection_schema(parse_collection(&id)?)
        .map(|schema| schema.map(Into::into))
        .map_err(Into::into)
}
pub async fn add_field(
    collection_id: String,
    mut field: FieldDefinitionDto,
) -> Result<String, BridgeError> {
    let id = if field.id.is_empty() {
        FieldId::new()
    } else {
        parse_field(&field.id)?
    };
    field.id = id.to_string();
    core()
        .await?
        .add_field(parse_collection(&collection_id)?, field.try_into()?)
        .await
        .map_err(BridgeError::from)?;
    Ok(id.to_string())
}
pub async fn update_field(
    collection_id: String,
    field: FieldDefinitionDto,
) -> Result<(), BridgeError> {
    core()
        .await?
        .update_field(parse_collection(&collection_id)?, field.try_into()?)
        .await
        .map_err(Into::into)
}
pub async fn remove_field(collection_id: String, field_id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .remove_field(parse_collection(&collection_id)?, parse_field(&field_id)?)
        .await
        .map_err(Into::into)
}
pub async fn reorder_fields(
    collection_id: String,
    field_ids: Vec<String>,
) -> Result<(), BridgeError> {
    core()
        .await?
        .reorder_fields(
            parse_collection(&collection_id)?,
            field_ids
                .iter()
                .map(|id| parse_field(id))
                .collect::<Result<Vec<_>, _>>()?,
        )
        .await
        .map_err(Into::into)
}
pub async fn upsert_enum_option(
    collection_id: String,
    field_id: String,
    mut option: crate::api::models::EnumOptionDto,
) -> Result<String, BridgeError> {
    let collection_id = parse_collection(&collection_id)?;
    let option_id = if option.id.is_empty() {
        app_core::EnumOptionId::new()
    } else {
        option.id.parse().map_err(core_error)?
    };
    option.id = option_id.to_string();
    core()
        .await?
        .upsert_enum_option(collection_id, parse_field(&field_id)?, option.try_into()?)
        .await
        .map_err(BridgeError::from)?;
    Ok(option_id.to_string())
}
pub async fn remove_enum_option(
    collection_id: String,
    field_id: String,
    option_id: String,
) -> Result<(), BridgeError> {
    let collection_id = parse_collection(&collection_id)?;
    core()
        .await?
        .remove_enum_option(
            collection_id,
            parse_field(&field_id)?,
            option_id.parse().map_err(core_error)?,
        )
        .await
        .map_err(Into::into)
}
pub async fn create_record(
    collection_id: String,
    values: Vec<crate::api::models::RecordValueDto>,
) -> Result<String, BridgeError> {
    let values = parse_values(values)?;
    core()
        .await?
        .create_record(parse_collection(&collection_id)?, values)
        .await
        .map(|id| id.to_string())
        .map_err(Into::into)
}
/// Dry-run record validation with create (no `record_id`) or merged-update
/// semantics. Returns every issue; empty when the draft is valid. Commits
/// nothing. Errs only for non-validation failures.
pub async fn validate_record_draft(
    collection_id: String,
    record_id: Option<String>,
    values: Vec<crate::api::models::RecordValueDto>,
) -> Result<Vec<BridgeIssueDto>, BridgeError> {
    let record_id = record_id.as_deref().map(parse_record).transpose()?;
    let values = parse_values(values)?;
    core()
        .await?
        .validate_record_draft(parse_collection(&collection_id)?, record_id, values)
        .map(|issues| issues.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}
pub async fn update_record_field(
    record_id: String,
    collection_id: String,
    field_id: String,
    value: FieldValueDto,
) -> Result<(), BridgeError> {
    core()
        .await?
        .update_record_field(
            parse_record(&record_id)?,
            parse_collection(&collection_id)?,
            parse_field(&field_id)?,
            FieldValueDto::into_core(value)?,
        )
        .await
        .map_err(Into::into)
}
pub async fn delete_record(record_id: String, collection_id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .delete_record(parse_record(&record_id)?, parse_collection(&collection_id)?)
        .await
        .map_err(Into::into)
}
pub async fn delete_records(
    record_ids: Vec<String>,
    collection_id: String,
) -> Result<(), BridgeError> {
    let record_ids = parse_records(&record_ids)?;
    core()
        .await?
        .delete_records(record_ids, parse_collection(&collection_id)?)
        .await
        .map_err(Into::into)
}
pub async fn set_records_field(
    record_ids: Vec<String>,
    collection_id: String,
    field_id: String,
    value: FieldValueDto,
) -> Result<(), BridgeError> {
    let record_ids = parse_records(&record_ids)?;
    core()
        .await?
        .set_records_field(
            record_ids,
            parse_collection(&collection_id)?,
            parse_field(&field_id)?,
            FieldValueDto::into_core(value)?,
        )
        .await
        .map_err(Into::into)
}
pub async fn list_records(collection_id: String) -> Result<Vec<RecordDto>, BridgeError> {
    core()
        .await?
        .records(parse_collection(&collection_id)?)
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(Into::into)
}
pub async fn get_record(id: String) -> Result<Option<RecordDto>, BridgeError> {
    core()
        .await?
        .record(parse_record(&id)?)
        .map(|item| item.map(Into::into))
        .map_err(Into::into)
}

fn parse_values(
    values: Vec<crate::api::models::RecordValueDto>,
) -> Result<BTreeMap<FieldId, app_core::FieldValue>, BridgeError> {
    values
        .into_iter()
        .map(|item| {
            Ok((
                parse_field(&item.field_id)?,
                FieldValueDto::into_core(item.value)?,
            ))
        })
        .collect()
}
fn parse_records(values: &[String]) -> Result<Vec<RecordId>, BridgeError> {
    values.iter().map(|value| parse_record(value)).collect()
}
fn parse_collection(value: &str) -> Result<CollectionSchemaId, BridgeError> {
    CollectionSchemaId::from_str(value).map_err(core_error)
}
fn parse_field(value: &str) -> Result<FieldId, BridgeError> {
    FieldId::from_str(value).map_err(core_error)
}
fn parse_record(value: &str) -> Result<RecordId, BridgeError> {
    RecordId::from_str(value)
        .map_err(|error| BridgeError::validation("record_id", error.to_string()))
}
fn core_error(error: app_core::DomainError) -> BridgeError {
    BridgeError::from(app_core::AppError::from(error))
}
