use std::path::PathBuf;

use thiserror::Error;

pub type Result<T> = std::result::Result<T, AppError>;

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum DomainError {
    #[error("invalid {field}: {message}")]
    Invalid {
        field: &'static str,
        message: String,
    },
    #[error("{kind} {id} was not found")]
    NotFound { kind: &'static str, id: String },
    #[error("unsupported application schema version {0}; development data must be reset")]
    UnsupportedSchema(i64),
    #[error("malformed generic application document: {0}")]
    Malformed(String),
    /// Several validation issues found together, each naming the fields it
    /// concerns. Used where every problem is reported at once (records).
    #[error("{}", summarize_issues(.0))]
    InvalidMany(Vec<ValidationIssue>),
}

/// Stable machine-readable category of a validation issue.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum IssueCode {
    Required,
    TypeMismatch,
    Length,
    OutOfRange,
    InactiveOption,
    FieldUnavailable,
    Invalid,
}

impl IssueCode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::TypeMismatch => "type_mismatch",
            Self::Length => "length",
            Self::OutOfRange => "out_of_range",
            Self::InactiveOption => "inactive_option",
            Self::FieldUnavailable => "field_unavailable",
            Self::Invalid => "invalid",
        }
    }
}

/// One validation problem. `fields` holds field ids or form keys (zero, one,
/// or several); `message` is safe to show and never contains ids.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ValidationIssue {
    pub fields: Vec<String>,
    pub code: IssueCode,
    pub message: String,
}

impl ValidationIssue {
    #[must_use]
    pub fn new(code: IssueCode, message: impl Into<String>) -> Self {
        Self {
            fields: Vec::new(),
            code,
            message: message.into(),
        }
    }

    #[must_use]
    pub fn on(mut self, field: impl ToString) -> Self {
        self.fields = vec![field.to_string()];
        self
    }
}

/// One-line summary for banners: the only issue's message, or a count.
#[must_use]
pub fn summarize_issues(issues: &[ValidationIssue]) -> String {
    match issues {
        [only] => only.message.clone(),
        _ => format!("{} problems need attention", issues.len()),
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum BootstrapError {
    #[error("an application-root decision is required")]
    DecisionRequired,
    #[error("an application-root decision was already made")]
    DecisionAlreadyMade,
    #[error("joined root is still synchronizing")]
    Joining,
    #[error("application core is closed")]
    Closed,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum ProjectionError {
    #[error("projection database at {path:?} is unavailable: {message}")]
    Database { path: PathBuf, message: String },
    #[error("projection checkpoint is malformed: {0}")]
    Checkpoint(String),
    #[error("projection root does not match the application root")]
    RootMismatch,
}

#[derive(Clone, Debug, Error)]
pub enum AppError {
    #[error(transparent)]
    Bootstrap(#[from] BootstrapError),
    #[error(transparent)]
    Domain(#[from] DomainError),
    #[error(transparent)]
    Clock(#[from] crate::hlc::HlcError),
    #[error(transparent)]
    Projection(#[from] ProjectionError),
    #[error(transparent)]
    Identity(#[from] crate::identity::IdentityError),
    #[error(transparent)]
    Network(#[from] crate::quinn_transport::QuinnTransportError),
    #[error(transparent)]
    Pairing(#[from] crate::pairing::PairingError),
    /// Typed repository bootstrap failure, kept structured so open-time
    /// validation failures can be classified as reset-resolvable.
    #[error(transparent)]
    RepositoryBootstrap(automerge_repo::error::BootstrapError),
    #[error("repository operation failed: {0}")]
    Repository(String),
    #[error("storage operation failed: {0}")]
    Storage(String),
    #[error("application owner task stopped")]
    OwnerStopped,
}

impl AppError {
    /// Whether a deliberate dataset reset would resolve this error. True only
    /// for conditions that describe the local dataset itself (an unsupported
    /// application schema, a genuinely inconsistent bootstrap record, a root
    /// whose recovery has been exhausted). Keystore, network, and I/O failures
    /// are transient and stay unclassified so a retry is offered instead of a
    /// destructive action.
    #[must_use]
    pub fn is_reset_resolvable(&self) -> bool {
        use automerge_repo::error::BootstrapError as RepoBootstrapError;
        matches!(
            self,
            Self::Domain(DomainError::UnsupportedSchema(_))
                | Self::RepositoryBootstrap(
                    RepoBootstrapError::Inconsistent { .. }
                        | RepoBootstrapError::RecoveryExhausted { .. }
                )
        )
    }

    /// Whether this failure is the desktop secure key store being locked. The
    /// user-facing fix is to unlock the keyring and retry, so this stays
    /// recoverable through every layer instead of collapsing into a generic
    /// networking-initialization failure.
    #[must_use]
    pub fn is_secure_store_locked(&self) -> bool {
        use crate::identity::{IdentityError, SecureStoreError};
        use crate::pairing::PairingError;
        matches!(
            self,
            Self::Identity(IdentityError::SecureStore(SecureStoreError::Locked))
                | Self::Pairing(PairingError::SecureStoreLocked)
        )
    }
}

impl From<automerge_repo::Error> for AppError {
    fn from(value: automerge_repo::Error) -> Self {
        match value {
            automerge_repo::Error::Bootstrap(error) => Self::RepositoryBootstrap(error),
            other => Self::Repository(other.to_string()),
        }
    }
}

impl From<automerge_repo::error::StorageError> for AppError {
    fn from(value: automerge_repo::error::StorageError) -> Self {
        Self::Storage(value.to_string())
    }
}

impl From<rusqlite::Error> for AppError {
    fn from(value: rusqlite::Error) -> Self {
        Self::Storage(value.to_string())
    }
}
