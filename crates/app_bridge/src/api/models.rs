use app_core::{
    AggregateView, AppError, ApplicationState, CategoryView, DataChanged, DomainError, DomainKind,
    ErrorEvent, ProjectionState, TransactionView,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapKindDto {
    NeedsDecision,
    Creating,
    Joining,
    Ready,
    ShuttingDown,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapDto {
    pub kind: BootstrapKindDto,
    pub root_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionKindDto {
    Unavailable,
    Rebuilding,
    Projecting,
    Ready,
    Failed,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectionDto {
    pub kind: ProjectionKindDto,
    pub checkpoint: Option<String>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CategoryDto {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransactionDto {
    pub id: String,
    pub occurred_at_ms: i64,
    pub category_id: String,
    pub category_name: Option<String>,
    pub category_available: bool,
    pub amount_minor: i64,
    pub description: String,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct TransactionFilterDto {
    pub text: Option<String>,
    pub category_id: Option<String>,
    pub from_ms: Option<i64>,
    pub through_ms: Option<i64>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct AggregateDto {
    pub balance_minor: i64,
    pub income_minor: i64,
    pub expense_minor: i64,
    pub transaction_count: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DomainKindDto {
    Categories,
    Transactions,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataChangedDto {
    pub kinds: Vec<DomainKindDto>,
    pub checkpoint: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BridgeErrorKind {
    Initialization,
    Validation,
    Bootstrap,
    Persistence,
    Projection,
    Lifecycle,
    Internal,
}

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
#[error("{message}")]
pub struct BridgeError {
    pub kind: BridgeErrorKind,
    pub field: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BridgeErrorEventDto {
    pub kind: BridgeErrorKind,
    pub operation: String,
    pub message: String,
}

impl BootstrapDto {
    pub(crate) fn from_core(value: ApplicationState) -> Self {
        match value {
            ApplicationState::NeedsDecision => Self::new(BootstrapKindDto::NeedsDecision, None),
            ApplicationState::Creating => Self::new(BootstrapKindDto::Creating, None),
            ApplicationState::Joining { root } => {
                Self::new(BootstrapKindDto::Joining, Some(root.to_string()))
            }
            ApplicationState::Ready { root } => {
                Self::new(BootstrapKindDto::Ready, Some(root.to_string()))
            }
            ApplicationState::ShuttingDown => Self::new(BootstrapKindDto::ShuttingDown, None),
            ApplicationState::Closed => Self::new(BootstrapKindDto::Closed, None),
        }
    }

    fn new(kind: BootstrapKindDto, root_id: Option<String>) -> Self {
        Self { kind, root_id }
    }
}

impl ProjectionDto {
    pub(crate) fn from_core(value: ProjectionState) -> Self {
        match value {
            ProjectionState::Unavailable => Self::new(ProjectionKindDto::Unavailable, None, None),
            ProjectionState::Rebuilding => Self::new(ProjectionKindDto::Rebuilding, None, None),
            ProjectionState::Projecting => Self::new(ProjectionKindDto::Projecting, None, None),
            ProjectionState::Ready { checkpoint } => {
                Self::new(ProjectionKindDto::Ready, Some(checkpoint.heads), None)
            }
            ProjectionState::Failed { .. } => Self::new(
                ProjectionKindDto::Failed,
                None,
                Some("The local read model could not be refreshed.".into()),
            ),
            ProjectionState::Closed => Self::new(ProjectionKindDto::Closed, None, None),
        }
    }

    fn new(kind: ProjectionKindDto, checkpoint: Option<String>, message: Option<String>) -> Self {
        Self {
            kind,
            checkpoint,
            message,
        }
    }
}

impl From<CategoryView> for CategoryDto {
    fn from(value: CategoryView) -> Self {
        Self {
            id: value.id.to_string(),
            name: value.name,
        }
    }
}

impl From<TransactionView> for TransactionDto {
    fn from(value: TransactionView) -> Self {
        Self {
            id: value.id.to_string(),
            occurred_at_ms: value.occurred_at_ms,
            category_id: value.category_id.to_string(),
            category_name: value.category_name,
            category_available: value.category_available,
            amount_minor: value.amount_minor,
            description: value.description,
        }
    }
}

impl From<AggregateView> for AggregateDto {
    fn from(value: AggregateView) -> Self {
        Self {
            balance_minor: value.balance_minor,
            income_minor: value.income_minor,
            expense_minor: value.expense_minor,
            transaction_count: value.transaction_count,
        }
    }
}

impl From<DomainKind> for DomainKindDto {
    fn from(value: DomainKind) -> Self {
        match value {
            DomainKind::Categories => Self::Categories,
            DomainKind::Transactions => Self::Transactions,
        }
    }
}

impl From<DataChanged> for DataChangedDto {
    fn from(value: DataChanged) -> Self {
        Self {
            kinds: value.kinds.into_iter().map(Into::into).collect(),
            checkpoint: value.checkpoint.heads,
        }
    }
}

impl From<ErrorEvent> for BridgeErrorEventDto {
    fn from(value: ErrorEvent) -> Self {
        Self {
            kind: BridgeErrorKind::Projection,
            operation: value.operation.into(),
            message: "The local read model could not be refreshed.".into(),
        }
    }
}

impl From<AppError> for BridgeError {
    fn from(value: AppError) -> Self {
        match value {
            AppError::Domain(DomainError::Invalid { field, message }) => Self {
                kind: BridgeErrorKind::Validation,
                field: Some(field.into()),
                message,
            },
            AppError::Domain(DomainError::CategoryUnavailable(_)) => Self::safe(
                BridgeErrorKind::Validation,
                "The selected category is unavailable.",
            ),
            AppError::Domain(DomainError::NotFound { kind, .. }) => Self::safe(
                BridgeErrorKind::Validation,
                format!("The selected {kind} no longer exists."),
            ),
            AppError::Domain(_) => Self::safe(
                BridgeErrorKind::Internal,
                "The local finance data is not supported by this application version.",
            ),
            AppError::Bootstrap(error) => Self::safe(BridgeErrorKind::Bootstrap, error.to_string()),
            AppError::Projection(_) => Self::safe(
                BridgeErrorKind::Projection,
                "The local read model could not be refreshed.",
            ),
            AppError::Repository(_) | AppError::Storage(_) => Self::safe(
                BridgeErrorKind::Persistence,
                "Local data could not be saved or loaded.",
            ),
            AppError::OwnerStopped => Self::safe(
                BridgeErrorKind::Lifecycle,
                "The local finance service is not running.",
            ),
        }
    }
}

impl BridgeError {
    pub(crate) fn initialization(message: impl Into<String>) -> Self {
        Self::safe(BridgeErrorKind::Initialization, message)
    }

    pub(crate) fn lifecycle(message: impl Into<String>) -> Self {
        Self::safe(BridgeErrorKind::Lifecycle, message)
    }

    fn safe(kind: BridgeErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            field: None,
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use app_core::{AppError, DomainError};

    use super::{BridgeError, BridgeErrorKind};

    #[test]
    fn maps_validation_and_hides_infrastructure_failures() {
        let validation = BridgeError::from(AppError::Domain(DomainError::Invalid {
            field: "amount_minor",
            message: "must be non-zero".into(),
        }));
        assert_eq!(validation.kind, BridgeErrorKind::Validation);
        assert_eq!(validation.field.as_deref(), Some("amount_minor"));

        let storage = BridgeError::from(AppError::Storage(
            "/private/path/control.sqlite: disk failure".into(),
        ));
        assert_eq!(storage.kind, BridgeErrorKind::Persistence);
        assert!(!storage.message.contains("/private/path"));
        assert!(!storage.message.contains("sqlite"));
    }
}
