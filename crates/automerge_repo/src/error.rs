//! Structured errors retain the document or authenticated peer context needed
//! by callers to recover one read model, peer, or subsystem independently.
use std::path::PathBuf;

use crate::{DocumentId, PeerId};

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum LifecycleError {
    #[error("repository is closing")]
    RepositoryClosing,
    #[error("repository is closed")]
    RepositoryClosed,
    #[error("document {document} is closed")]
    DocumentClosed { document: DocumentId },
    #[error("document {document} is not ready")]
    DocumentNotReady { document: DocumentId },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum FailurePhase {
    DocumentStore,
    DocumentFlush,
    DocumentClose,
    TransportClose,
    ControlStore,
    ControlFlush,
    ControlClose,
    CleanupRemove,
}

impl std::fmt::Display for FailurePhase {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Failure {
    pub phase: FailurePhase,
    pub document: Option<DocumentId>,
    pub revision: Option<u64>,
    pub message: String,
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum BootstrapError {
    #[error("bootstrap decision is required")]
    DecisionRequired,
    #[error("bootstrap decision has already been made")]
    DecisionAlreadyMade,
    #[error("invalid bootstrap transition: {from} -> {to}")]
    InvalidTransition {
        from: &'static str,
        to: &'static str,
    },
    #[error("peer {peer} offered incompatible root {remote}; local root is {local}")]
    RootMismatch {
        peer: PeerId,
        local: DocumentId,
        remote: DocumentId,
    },
    #[error("bootstrap record for root {root} is inconsistent: {message}")]
    Inconsistent { root: DocumentId, message: String },
    #[error(
        "recovery of root {root} failed {attempts} time(s) and will not be retried; quarantined snapshots are retained"
    )]
    RecoveryExhausted { root: DocumentId, attempts: u32 },
    #[error("bootstrap {operation} failed for root {root}: {message}")]
    Operation {
        operation: &'static str,
        root: DocumentId,
        message: String,
    },
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum ProtocolError {
    #[error("frame body is too large: {actual} > {maximum}")]
    FrameTooLarge { actual: usize, maximum: usize },
    #[error("invalid frame length")]
    InvalidLength,
    #[error("invalid protocol magic")]
    BadMagic,
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u8),
    #[error("unknown message kind {0}")]
    UnknownKind(u8),
    #[error("reserved flags must be zero, got {0}")]
    ReservedFlags(u16),
    #[error("unknown bootstrap mode {0}")]
    UnknownBootstrapMode(u8),
    #[error("invalid inventory count")]
    InvalidInventoryCount,
    #[error("invalid Automerge sync payload")]
    InvalidSyncPayload,
    #[error("Hello must be the first peer message")]
    HelloRequired,
    #[error("peer sent Hello more than once")]
    DuplicateHello,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StorageError {
    pub operation: &'static str,
    pub document: Option<DocumentId>,
    pub message: String,
    pub revision: Option<u64>,
    pub path: Option<PathBuf>,
}

impl std::fmt::Display for StorageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "storage {} failed", self.operation)?;
        if let Some(document) = self.document {
            write!(f, " for document {document}")?;
        }
        if let Some(revision) = self.revision {
            write!(f, " at revision {revision}")?;
        }
        if let Some(path) = &self.path {
            write!(f, " at {}", path.display())?;
        }
        write!(f, ": {}", self.message)
    }
}

impl std::error::Error for StorageError {}

impl StorageError {
    #[must_use]
    pub fn new(
        operation: &'static str,
        document: Option<DocumentId>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            operation,
            document,
            message: message.into(),
            revision: None,
            path: None,
        }
    }

    #[must_use]
    pub fn with_revision(mut self, revision: u64) -> Self {
        self.revision = Some(revision);
        self
    }

    #[must_use]
    pub fn with_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.path = Some(path.into());
        self
    }
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum NetworkError {
    #[error("transport event receiver was already taken")]
    EventsAlreadyTaken,
    #[error("transport operation failed for peer {peer}: {message}")]
    Transport { peer: PeerId, message: String },
    #[error("transport is closed")]
    Closed,
}

#[derive(Clone, Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid repository configuration: {0}")]
    Config(String),
    #[error(transparent)]
    Lifecycle(#[from] LifecycleError),
    #[error(transparent)]
    Bootstrap(#[from] BootstrapError),
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error(transparent)]
    Network(#[from] NetworkError),
    #[error("document {0} was not found")]
    NotFound(DocumentId),
    #[error("document actor failed for {document}: {message}")]
    Actor {
        document: DocumentId,
        message: String,
    },
    #[error("Automerge failure for document {document}: {message}")]
    Automerge {
        document: DocumentId,
        message: String,
    },
    #[error("user transaction failed: {0}")]
    Change(String),
    #[error("automatic persistence failed for document {document} revision {revision}: {source}")]
    Persistence {
        document: DocumentId,
        revision: u64,
        source: Box<StorageError>,
    },
    #[error("repository flush failed in {} component(s)", .0.len())]
    Flush(Vec<Failure>),
    #[error("repository shutdown failed in {} phase(s)", .0.len())]
    Shutdown(Vec<Failure>),
    #[error("creation failed for document {document}: {primary}; cleanup failures: {cleanup:?}")]
    Creation {
        document: DocumentId,
        primary: Box<Error>,
        cleanup: Vec<Failure>,
    },
    #[error("cannot remove document {document}: {reason}")]
    Removal {
        document: DocumentId,
        reason: String,
    },
}

pub type Result<T, E = Error> = std::result::Result<T, E>;
