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
    #[error("category {0} was not found or is deleted")]
    CategoryUnavailable(String),
    #[error("{kind} {id} was not found")]
    NotFound { kind: &'static str, id: String },
    #[error("unsupported finance schema version {0}")]
    UnsupportedSchema(i64),
    #[error("malformed finance document: {0}")]
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
    Projection(#[from] ProjectionError),
    #[error(transparent)]
    Identity(#[from] crate::identity::IdentityError),
    #[error(transparent)]
    Network(#[from] crate::quinn_transport::QuinnTransportError),
    #[error("repository operation failed: {0}")]
    Repository(String),
    #[error("storage operation failed: {0}")]
    Storage(String),
    #[error("application owner task stopped")]
    OwnerStopped,
}

impl From<automerge_repo::Error> for AppError {
    fn from(value: automerge_repo::Error) -> Self {
        Self::Repository(value.to_string())
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
