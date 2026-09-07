use std::str::FromStr;

use app_core::{
    CategoryId, CreateCategory, CreateTransaction, TransactionFilter, TransactionId,
    UpdateCategory, UpdateTransaction,
};

use crate::api::{
    lifecycle::core,
    models::{
        AggregateDto, BootstrapDto, BridgeError, CategoryDto, TransactionDto, TransactionFilterDto,
    },
};

pub async fn create_new_dataset() -> Result<BootstrapDto, BridgeError> {
    let app = core().await?;
    app.create_new_dataset().await.map_err(BridgeError::from)?;
    Ok(BootstrapDto::from_core(app.lifecycle_state()))
}

pub async fn create_category(name: String) -> Result<String, BridgeError> {
    core()
        .await?
        .create_category(CreateCategory { name })
        .await
        .map(|id| id.to_string())
        .map_err(BridgeError::from)
}

pub async fn update_category(id: String, name: String) -> Result<(), BridgeError> {
    core()
        .await?
        .update_category(UpdateCategory {
            id: parse_category_id(&id)?,
            name: Some(name),
        })
        .await
        .map_err(BridgeError::from)
}

pub async fn delete_category(id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .delete_category(parse_category_id(&id)?)
        .await
        .map_err(BridgeError::from)
}

pub async fn list_categories() -> Result<Vec<CategoryDto>, BridgeError> {
    core()
        .await?
        .categories()
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(BridgeError::from)
}

pub async fn create_transaction(
    occurred_at_ms: i64,
    category_id: String,
    amount_minor: i64,
    description: String,
) -> Result<String, BridgeError> {
    core()
        .await?
        .create_transaction(CreateTransaction {
            occurred_at_ms,
            category_id: parse_category_id(&category_id)?,
            amount_minor,
            description,
        })
        .await
        .map(|id| id.to_string())
        .map_err(BridgeError::from)
}

pub async fn update_transaction(
    id: String,
    occurred_at_ms: Option<i64>,
    category_id: Option<String>,
    amount_minor: Option<i64>,
    description: Option<String>,
) -> Result<(), BridgeError> {
    core()
        .await?
        .update_transaction(UpdateTransaction {
            id: parse_transaction_id(&id)?,
            occurred_at_ms,
            category_id: category_id.as_deref().map(parse_category_id).transpose()?,
            amount_minor,
            description,
        })
        .await
        .map_err(BridgeError::from)
}

pub async fn delete_transaction(id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .delete_transaction(parse_transaction_id(&id)?)
        .await
        .map_err(BridgeError::from)
}

pub async fn list_transactions(
    filter: TransactionFilterDto,
) -> Result<Vec<TransactionDto>, BridgeError> {
    let category_id = filter
        .category_id
        .as_deref()
        .map(parse_category_id)
        .transpose()?;
    core()
        .await?
        .transactions(&TransactionFilter {
            text: filter.text,
            category_id,
            from_ms: filter.from_ms,
            through_ms: filter.through_ms,
        })
        .map(|items| items.into_iter().map(Into::into).collect())
        .map_err(BridgeError::from)
}

pub async fn aggregates() -> Result<AggregateDto, BridgeError> {
    core()
        .await?
        .aggregates()
        .map(Into::into)
        .map_err(BridgeError::from)
}

fn parse_category_id(value: &str) -> Result<CategoryId, BridgeError> {
    CategoryId::from_str(value).map_err(|error| BridgeError::from(app_core::AppError::from(error)))
}

fn parse_transaction_id(value: &str) -> Result<TransactionId, BridgeError> {
    TransactionId::from_str(value)
        .map_err(|error| BridgeError::from(app_core::AppError::from(error)))
}
