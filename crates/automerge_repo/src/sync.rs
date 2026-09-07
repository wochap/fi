//! Retained synchronization observability derived from live Automerge sessions.

use crate::{DocumentId, PeerId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RelationshipSyncState {
    Syncing,
    Synced,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PeerSyncState {
    Connected,
    Syncing,
    Synced,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PeerSyncProgress {
    pub peer: PeerId,
    pub state: PeerSyncState,
    pub documents: usize,
    pub syncing_documents: Vec<DocumentId>,
}
