use crate::{DocumentId, PeerId};

/// Durable bootstrap transition records.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BootstrapRecord {
    Creating { root: DocumentId },
    Joining { root: DocumentId },
    Ready { root: DocumentId },
}

impl BootstrapRecord {
    #[must_use]
    pub const fn root(&self) -> DocumentId {
        match self {
            Self::Creating { root } | Self::Joining { root } | Self::Ready { root } => *root,
        }
    }
}

/// Live repository bootstrap state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BootstrapStatus {
    NeedsDecision,
    Creating { root: DocumentId },
    Joining { root: DocumentId },
    Ready { root: DocumentId },
    Closed,
}

impl BootstrapStatus {
    #[must_use]
    pub const fn root(&self) -> Option<DocumentId> {
        match self {
            Self::Creating { root } | Self::Joining { root } | Self::Ready { root } => Some(*root),
            Self::NeedsDecision | Self::Closed => None,
        }
    }
    #[must_use]
    pub const fn is_ready(&self) -> bool {
        matches!(self, Self::Ready { .. })
    }
}

impl From<BootstrapRecord> for BootstrapStatus {
    fn from(record: BootstrapRecord) -> Self {
        match record {
            BootstrapRecord::Creating { root } => Self::Creating { root },
            BootstrapRecord::Joining { root } => Self::Joining { root },
            BootstrapRecord::Ready { root } => Self::Ready { root },
        }
    }
}

/// A retained root offered by an authenticated ready peer.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapOffer {
    pub peer: PeerId,
    pub root: DocumentId,
}
