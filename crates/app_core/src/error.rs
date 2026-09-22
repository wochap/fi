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
    /// application schema, a bootstrap record without its root, snapshots
    /// without a record). Keystore, network, and I/O failures are transient
    /// and stay unclassified so a retry is offered instead of a destructive
    /// action.
    #[must_use]
    pub fn is_reset_resolvable(&self) -> bool {
        use automerge_repo::error::BootstrapError as RepoBootstrapError;
        matches!(
            self,
            Self::Domain(DomainError::UnsupportedSchema(_))
                | Self::RepositoryBootstrap(
                    RepoBootstrapError::Inconsistent { .. }
                        | RepoBootstrapError::OrphanedDocuments { .. }
                )
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
