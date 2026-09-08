use crate::projection::ProjectionCheckpoint;
use automerge_repo::DocumentId;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApplicationState {
    NeedsDecision,
    Creating,
    Joining { root: DocumentId },
    Ready { root: DocumentId },
    ShuttingDown,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProjectionState {
    Unavailable,
    Rebuilding,
    Projecting,
    Ready { checkpoint: ProjectionCheckpoint },
    Failed { message: String },
    Closed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum DomainKind {
    Collections,
    Schemas,
    Records,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataChanged {
    pub kinds: Vec<DomainKind>,
    pub collection_ids: Vec<crate::schema::CollectionSchemaId>,
    pub checkpoint: ProjectionCheckpoint,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ErrorEvent {
    pub operation: &'static str,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransientEvent {
    DataChanged(DataChanged),
    Error(ErrorEvent),
}
