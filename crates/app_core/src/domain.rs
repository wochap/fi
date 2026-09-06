use std::{fmt, str::FromStr};

use automerge::{
    Automerge, ObjId, ObjType, ROOT, ReadDoc,
    transaction::{Transactable, Transaction as AutomergeTransaction},
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::DomainError;

pub const FINANCE_SCHEMA_VERSION: i64 = 1;
pub const DEFAULT_CATEGORY_NAME: &str = "General";

macro_rules! entity_id {
    ($name:ident) => {
        #[derive(
            Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize,
        )]
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
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
        impl FromStr for $name {
            type Err = DomainError;
            fn from_str(value: &str) -> Result<Self, Self::Err> {
                let uuid = Uuid::parse_str(value).map_err(|_| DomainError::Invalid {
                    field: "id",
                    message: "must be a canonical UUIDv7".into(),
                })?;
                if uuid.get_version_num() != 7 || uuid.hyphenated().to_string() != value {
                    return Err(DomainError::Invalid {
                        field: "id",
                        message: "must be a canonical UUIDv7".into(),
                    });
                }
                Ok(Self(uuid))
            }
        }
    };
}

entity_id!(CategoryId);
entity_id!(TransactionId);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Category {
    pub id: CategoryId,
    pub name: String,
    pub deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct Transaction {
    pub id: TransactionId,
    pub occurred_at_ms: i64,
    pub category_id: CategoryId,
    pub amount_minor: i64,
    pub description: String,
    pub deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct FinanceSnapshot {
    pub schema_version: i64,
    pub categories: Vec<Category>,
    pub transactions: Vec<Transaction>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CategoryView {
    pub id: CategoryId,
    pub name: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct TransactionView {
    pub id: TransactionId,
    pub occurred_at_ms: i64,
    pub category_id: CategoryId,
    pub category_name: Option<String>,
    pub category_available: bool,
    pub amount_minor: i64,
    pub description: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct TransactionFilter {
    pub text: Option<String>,
    pub category_id: Option<CategoryId>,
    pub from_ms: Option<i64>,
    pub through_ms: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreateCategory {
    pub name: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UpdateCategory {
    pub id: CategoryId,
    pub name: Option<String>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreateTransaction {
    pub occurred_at_ms: i64,
    pub category_id: CategoryId,
    pub amount_minor: i64,
    pub description: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UpdateTransaction {
    pub id: TransactionId,
    pub occurred_at_ms: Option<i64>,
    pub category_id: Option<CategoryId>,
    pub amount_minor: Option<i64>,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FinanceCommand {
    CreateCategory(CreateCategory),
    UpdateCategory(UpdateCategory),
    DeleteCategory(CategoryId),
    CreateTransaction(CreateTransaction),
    UpdateTransaction(UpdateTransaction),
    DeleteTransaction(TransactionId),
}

impl FinanceCommand {
    pub fn validate(&self) -> Result<(), DomainError> {
        match self {
            Self::CreateCategory(value) => validate_name(&value.name),
            Self::UpdateCategory(value) => value.name.as_deref().map_or_else(
                || Err(invalid("update", "must change at least one field")),
                validate_name,
            ),
            Self::DeleteCategory(_) | Self::DeleteTransaction(_) => Ok(()),
            Self::CreateTransaction(value) => {
                validate_timestamp(value.occurred_at_ms)?;
                validate_amount(value.amount_minor)?;
                validate_description(&value.description)
            }
            Self::UpdateTransaction(value) => {
                if value.occurred_at_ms.is_none()
                    && value.category_id.is_none()
                    && value.amount_minor.is_none()
                    && value.description.is_none()
                {
                    return Err(invalid("update", "must change at least one field"));
                }
                if let Some(value) = value.occurred_at_ms {
                    validate_timestamp(value)?;
                }
                if let Some(value) = value.amount_minor {
                    validate_amount(value)?;
                }
                if let Some(value) = &value.description {
                    validate_description(value)?;
                }
                Ok(())
            }
        }
    }
}

fn invalid(field: &'static str, message: impl Into<String>) -> DomainError {
    DomainError::Invalid {
        field,
        message: message.into(),
    }
}
fn validate_name(value: &str) -> Result<(), DomainError> {
    let len = value.trim().chars().count();
    if len == 0 || len > 120 {
        Err(invalid(
            "name",
            "must contain 1 to 120 non-padding characters",
        ))
    } else {
        Ok(())
    }
}
fn validate_description(value: &str) -> Result<(), DomainError> {
    if value.chars().count() > 1000 {
        Err(invalid(
            "description",
            "must contain at most 1000 characters",
        ))
    } else {
        Ok(())
    }
}
fn validate_timestamp(value: i64) -> Result<(), DomainError> {
    if value < 0 {
        Err(invalid(
            "occurred_at_ms",
            "must be a non-negative UTC epoch millisecond",
        ))
    } else {
        Ok(())
    }
}
fn validate_amount(value: i64) -> Result<(), DomainError> {
    if value == 0 {
        Err(invalid("amount_minor", "must be non-zero"))
    } else {
        Ok(())
    }
}

fn repo_change(error: impl fmt::Display) -> automerge_repo::Error {
    automerge_repo::Error::Change(error.to_string())
}

pub fn initialize_finance(
    tx: &mut AutomergeTransaction<'_>,
    default_id: CategoryId,
) -> automerge_repo::Result<()> {
    let finance = tx
        .put_object(ROOT, "finance", ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&finance, "schema_version", FINANCE_SCHEMA_VERSION)
        .map_err(repo_change)?;
    let categories = tx
        .put_object(&finance, "categories", ObjType::Map)
        .map_err(repo_change)?;
    tx.put_object(&finance, "transactions", ObjType::Map)
        .map_err(repo_change)?;
    let category = tx
        .put_object(&categories, default_id.to_string(), ObjType::Map)
        .map_err(repo_change)?;
    tx.put(&category, "id", default_id.to_string())
        .map_err(repo_change)?;
    tx.put(&category, "name", DEFAULT_CATEGORY_NAME)
        .map_err(repo_change)?;
    tx.put(&category, "deleted", false).map_err(repo_change)?;
    Ok(())
}

pub fn apply_command(
    tx: &mut AutomergeTransaction<'_>,
    command: &FinanceCommand,
    generated_id: Option<String>,
) -> automerge_repo::Result<()> {
    let (_, finance) = tx
        .get(ROOT, "finance")
        .map_err(repo_change)?
        .ok_or_else(|| repo_change("finance root is absent"))?;
    let (_, categories) = tx
        .get(&finance, "categories")
        .map_err(repo_change)?
        .ok_or_else(|| repo_change("categories map is absent"))?;
    let (_, transactions) = tx
        .get(&finance, "transactions")
        .map_err(repo_change)?
        .ok_or_else(|| repo_change("transactions map is absent"))?;
    match command {
        FinanceCommand::CreateCategory(value) => {
            let id = generated_id
                .as_deref()
                .ok_or_else(|| repo_change("generated category id is absent"))?;
            let object = tx
                .put_object(&categories, id, ObjType::Map)
                .map_err(repo_change)?;
            tx.put(&object, "id", id).map_err(repo_change)?;
            tx.put(&object, "name", value.name.trim())
                .map_err(repo_change)?;
            tx.put(&object, "deleted", false).map_err(repo_change)?;
        }
        FinanceCommand::UpdateCategory(value) => {
            let (_, object) = tx
                .get(&categories, value.id.to_string())
                .map_err(repo_change)?
                .ok_or_else(|| repo_change("category not found"))?;
            if get_bool(tx, &object, "deleted").map_err(repo_change)? {
                return Err(repo_change("category is deleted"));
            }
            if let Some(name) = &value.name {
                tx.put(&object, "name", name.trim()).map_err(repo_change)?;
            }
        }
        FinanceCommand::DeleteCategory(id) => {
            let (_, object) = tx
                .get(&categories, id.to_string())
                .map_err(repo_change)?
                .ok_or_else(|| repo_change("category not found"))?;
            tx.put(&object, "deleted", true).map_err(repo_change)?;
        }
        FinanceCommand::CreateTransaction(value) => {
            ensure_category(tx, &categories, value.category_id).map_err(repo_change)?;
            let id = generated_id
                .as_deref()
                .ok_or_else(|| repo_change("generated transaction id is absent"))?;
            let object = tx
                .put_object(&transactions, id, ObjType::Map)
                .map_err(repo_change)?;
            tx.put(&object, "id", id).map_err(repo_change)?;
            tx.put(&object, "occurred_at_ms", value.occurred_at_ms)
                .map_err(repo_change)?;
            tx.put(&object, "category_id", value.category_id.to_string())
                .map_err(repo_change)?;
            tx.put(&object, "amount_minor", value.amount_minor)
                .map_err(repo_change)?;
            tx.put(&object, "description", value.description.as_str())
                .map_err(repo_change)?;
            tx.put(&object, "deleted", false).map_err(repo_change)?;
        }
        FinanceCommand::UpdateTransaction(value) => {
            if let Some(category) = value.category_id {
                ensure_category(tx, &categories, category).map_err(repo_change)?;
            }
            let (_, object) = tx
                .get(&transactions, value.id.to_string())
                .map_err(repo_change)?
                .ok_or_else(|| repo_change("transaction not found"))?;
            if get_bool(tx, &object, "deleted").map_err(repo_change)? {
                return Err(repo_change("transaction is deleted"));
            }
            if let Some(field) = value.occurred_at_ms {
                tx.put(&object, "occurred_at_ms", field)
                    .map_err(repo_change)?;
            }
            if let Some(field) = value.category_id {
                tx.put(&object, "category_id", field.to_string())
                    .map_err(repo_change)?;
            }
            if let Some(field) = value.amount_minor {
                tx.put(&object, "amount_minor", field)
                    .map_err(repo_change)?;
            }
            if let Some(field) = &value.description {
                tx.put(&object, "description", field.as_str())
                    .map_err(repo_change)?;
            }
        }
        FinanceCommand::DeleteTransaction(id) => {
            let (_, object) = tx
                .get(&transactions, id.to_string())
                .map_err(repo_change)?
                .ok_or_else(|| repo_change("transaction not found"))?;
            tx.put(&object, "deleted", true).map_err(repo_change)?;
        }
    }
    Ok(())
}

fn ensure_category(
    doc: &impl ReadDoc,
    categories: &ObjId,
    id: CategoryId,
) -> Result<(), DomainError> {
    let (_, object) = doc
        .get(categories, id.to_string())
        .map_err(|e| DomainError::Malformed(e.to_string()))?
        .ok_or_else(|| DomainError::CategoryUnavailable(id.to_string()))?;
    if get_bool(doc, &object, "deleted")? {
        Err(DomainError::CategoryUnavailable(id.to_string()))
    } else {
        Ok(())
    }
}

pub fn decode_finance(doc: &Automerge) -> Result<FinanceSnapshot, DomainError> {
    let finance = object(doc, &ROOT, "finance")?;
    let schema_version = get_i64(doc, &finance, "schema_version")?;
    if schema_version != FINANCE_SCHEMA_VERSION {
        return Err(DomainError::UnsupportedSchema(schema_version));
    }
    let categories_obj = object(doc, &finance, "categories")?;
    let transactions_obj = object(doc, &finance, "transactions")?;
    let mut categories = Vec::new();
    for key in doc.keys(&categories_obj) {
        let entry = object(doc, &categories_obj, &key)?;
        let id = CategoryId::from_str(&get_string(doc, &entry, "id")?)?;
        if id.to_string() != key {
            return Err(DomainError::Malformed("category key/id mismatch".into()));
        }
        categories.push(Category {
            id,
            name: get_string(doc, &entry, "name")?,
            deleted: get_bool(doc, &entry, "deleted")?,
        });
    }
    let mut transactions = Vec::new();
    for key in doc.keys(&transactions_obj) {
        let entry = object(doc, &transactions_obj, &key)?;
        let id = TransactionId::from_str(&get_string(doc, &entry, "id")?)?;
        if id.to_string() != key {
            return Err(DomainError::Malformed("transaction key/id mismatch".into()));
        }
        transactions.push(Transaction {
            id,
            occurred_at_ms: get_i64(doc, &entry, "occurred_at_ms")?,
            category_id: CategoryId::from_str(&get_string(doc, &entry, "category_id")?)?,
            amount_minor: get_i64(doc, &entry, "amount_minor")?,
            description: get_string(doc, &entry, "description")?,
            deleted: get_bool(doc, &entry, "deleted")?,
        });
    }
    categories.sort_by_key(|item| item.id);
    transactions.sort_by_key(|item| item.id);
    Ok(FinanceSnapshot {
        schema_version,
        categories,
        transactions,
    })
}

fn object(doc: &impl ReadDoc, parent: &ObjId, key: &str) -> Result<ObjId, DomainError> {
    let (value, object) = doc
        .get(parent, key)
        .map_err(|e| DomainError::Malformed(e.to_string()))?
        .ok_or_else(|| DomainError::Malformed(format!("missing {key}")))?;
    if !value.is_object() {
        return Err(DomainError::Malformed(format!("{key} is not an object")));
    }
    Ok(object)
}
fn get_string(doc: &impl ReadDoc, parent: &ObjId, key: &str) -> Result<String, DomainError> {
    doc.get(parent, key)
        .map_err(|e| DomainError::Malformed(e.to_string()))?
        .and_then(|(v, _)| v.to_str().map(ToOwned::to_owned))
        .ok_or_else(|| DomainError::Malformed(format!("missing or invalid {key}")))
}
fn get_i64(doc: &impl ReadDoc, parent: &ObjId, key: &str) -> Result<i64, DomainError> {
    doc.get(parent, key)
        .map_err(|e| DomainError::Malformed(e.to_string()))?
        .and_then(|(v, _)| v.to_i64())
        .ok_or_else(|| DomainError::Malformed(format!("missing or invalid {key}")))
}
fn get_bool(doc: &impl ReadDoc, parent: &ObjId, key: &str) -> Result<bool, DomainError> {
    doc.get(parent, key)
        .map_err(|e| DomainError::Malformed(e.to_string()))?
        .and_then(|(v, _)| v.to_bool())
        .ok_or_else(|| DomainError::Malformed(format!("missing or invalid {key}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn change(doc: &mut Automerge, command: &FinanceCommand, id: Option<String>) {
        let mut tx = doc.transaction();
        apply_command(&mut tx, command, id).unwrap();
        tx.commit();
    }

    fn initialized() -> (Automerge, CategoryId) {
        let mut doc = Automerge::new();
        let category = CategoryId::new();
        let mut tx = doc.transaction();
        initialize_finance(&mut tx, category).unwrap();
        tx.commit();
        (doc, category)
    }

    #[test]
    fn uuidv7_ids_are_unique_and_canonical() {
        let left = CategoryId::new();
        let right = CategoryId::new();
        assert_ne!(left, right);
        assert_eq!(left.to_string().parse::<CategoryId>().unwrap(), left);
    }

    #[test]
    fn invalid_commands_are_rejected_purely() {
        assert!(
            FinanceCommand::CreateCategory(CreateCategory { name: " ".into() })
                .validate()
                .is_err()
        );
        assert!(
            FinanceCommand::CreateTransaction(CreateTransaction {
                occurred_at_ms: -1,
                category_id: CategoryId::new(),
                amount_minor: 1,
                description: String::new()
            })
            .validate()
            .is_err()
        );
    }

    #[test]
    fn concurrent_independent_fields_converge() {
        let (mut base, category) = initialized();
        let id = TransactionId::new();
        change(
            &mut base,
            &FinanceCommand::CreateTransaction(CreateTransaction {
                occurred_at_ms: 1,
                category_id: category,
                amount_minor: -5,
                description: "before".into(),
            }),
            Some(id.to_string()),
        );
        let mut left = base.fork();
        let mut right = base.fork();
        change(
            &mut left,
            &FinanceCommand::UpdateTransaction(UpdateTransaction {
                id,
                occurred_at_ms: None,
                category_id: None,
                amount_minor: None,
                description: Some("after".into()),
            }),
            None,
        );
        change(
            &mut right,
            &FinanceCommand::UpdateTransaction(UpdateTransaction {
                id,
                occurred_at_ms: None,
                category_id: None,
                amount_minor: Some(-9),
                description: None,
            }),
            None,
        );
        left.merge(&mut right).unwrap();
        let item = decode_finance(&left).unwrap().transactions.pop().unwrap();
        assert_eq!(item.description, "after");
        assert_eq!(item.amount_minor, -9);
    }

    #[test]
    fn concurrent_edit_cannot_resurrect_a_tombstone() {
        let (mut base, category) = initialized();
        let id = TransactionId::new();
        change(
            &mut base,
            &FinanceCommand::CreateTransaction(CreateTransaction {
                occurred_at_ms: 1,
                category_id: category,
                amount_minor: -5,
                description: "before".into(),
            }),
            Some(id.to_string()),
        );
        let mut edit = base.fork();
        let mut deletion = base.fork();
        change(
            &mut edit,
            &FinanceCommand::UpdateTransaction(UpdateTransaction {
                id,
                occurred_at_ms: None,
                category_id: None,
                amount_minor: None,
                description: Some("edited".into()),
            }),
            None,
        );
        change(&mut deletion, &FinanceCommand::DeleteTransaction(id), None);
        edit.merge(&mut deletion).unwrap();
        let item = decode_finance(&edit).unwrap().transactions.pop().unwrap();
        assert_eq!(item.description, "edited");
        assert!(item.deleted);
    }
}
