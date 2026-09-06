//! Structured errors retain the document or authenticated peer context needed
//! by callers to recover one read model, peer, or subsystem independently.
use crate::{DocumentId, PeerId};

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum LifecycleError {
    #[error("repository is closed")]
    RepositoryClosed,
    #[error("document {document} is closed")]
    DocumentClosed { document: DocumentId },
    #[error("document {document} is not ready")]
    DocumentNotReady { document: DocumentId },
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

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
#[error("storage {operation} failed{document_suffix}: {message}")]
pub struct StorageError {
    pub operation: &'static str,
    pub document: Option<DocumentId>,
    pub message: String,
    #[doc(hidden)]
    pub document_suffix: String,
}

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
            document_suffix: document
                .map(|id| format!(" for document {id}"))
                .unwrap_or_default(),
        }
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
}

pub type Result<T, E = Error> = std::result::Result<T, E>;
