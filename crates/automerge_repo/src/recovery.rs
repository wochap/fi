//! Recoverable-versus-fatal classification of inconsistent local bootstrap
//! state, and the observable record of a recovery in progress.
//!
//! A state is recoverable only when the recorded root ID is still known and an
//! external authority can re-supply that root's content. Everything else stays
//! fatal: picking a document, inferring a root, or discarding bytes on the
//! user's behalf can convert a recoverable bug into permanent data loss.
use std::path::PathBuf;

use crate::{BootstrapRecord, DocumentId};

/// Why a snapshot was set aside instead of deleted.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub enum QuarantineReason {
    /// The recorded root existed but could not be strictly loaded.
    CorruptRoot,
    /// Documents were present without any bootstrap record.
    Orphaned,
    /// The control store itself could not be opened.
    ControlStoreUnreadable,
}

impl QuarantineReason {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CorruptRoot => "corrupt-root",
            Self::Orphaned => "orphaned",
            Self::ControlStoreUnreadable => "control-store-unreadable",
        }
    }
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "corrupt-root" => Some(Self::CorruptRoot),
            "orphaned" => Some(Self::Orphaned),
            "control-store-unreadable" => Some(Self::ControlStoreUnreadable),
            _ => None,
        }
    }
}

impl std::fmt::Display for QuarantineReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One quarantined snapshot. `key` is adapter-specific and stable for the
/// entry's lifetime; the original document ID and reason are always
/// determinable from it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QuarantineEntry {
    pub key: String,
    pub document: DocumentId,
    pub reason: QuarantineReason,
    pub location: Option<PathBuf>,
}

/// Why recovery was entered.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryReason {
    RootSnapshotMissing,
    RootSnapshotCorrupt,
    OrphanedDocuments,
}

/// Where recovery currently stands. Never silent: every value is reportable
/// to a client and names the affected documents through [`RecoveryRecord`].
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RecoveryOutcome {
    /// Root-only synchronization from a trusted peer is in progress.
    Recovering,
    /// The root was re-supplied and the repository is `Ready` for the same root.
    Recovered,
    /// No peer able to supply the recorded root has been reachable; the
    /// repository stays `Joining` for that root.
    NoPeerAvailable,
    /// Orphaned documents were set aside and a bootstrap decision is required.
    Quarantined,
    /// A quarantined document matching an explicitly joined root was adopted.
    Adopted,
    /// Recovery cannot continue; the message names the root and the cause.
    Fatal { message: String },
}

/// Typed, queryable record of one recovery.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryRecord {
    pub reason: RecoveryReason,
    /// The recorded root for root recovery, or every orphaned document.
    pub documents: Vec<DocumentId>,
    /// Locations of quarantined bytes, when the adapter exposes them.
    pub quarantine: Vec<PathBuf>,
    pub outcome: RecoveryOutcome,
}

impl RecoveryRecord {
    #[must_use]
    pub fn root(&self) -> Option<DocumentId> {
        match self.reason {
            RecoveryReason::RootSnapshotMissing | RecoveryReason::RootSnapshotCorrupt => {
                self.documents.first().copied()
            }
            RecoveryReason::OrphanedDocuments => None,
        }
    }
    #[must_use]
    pub const fn is_active(&self) -> bool {
        matches!(
            self.outcome,
            RecoveryOutcome::Recovering | RecoveryOutcome::NoPeerAvailable
        )
    }
}

/// Every inconsistent local bootstrap state `Repo::open` can observe.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BootstrapCondition {
    /// Documents exist without a bootstrap record.
    OrphanedDocuments { documents: Vec<DocumentId> },
    /// A `Ready` record names a root whose snapshot is absent.
    ReadyRootMissing { root: DocumentId },
    /// A `Ready` record names a root whose snapshot cannot be strictly loaded.
    ReadyRootUnloadable { root: DocumentId },
    /// A `Joining` record names a root whose persisted snapshot cannot be strictly loaded.
    JoiningRootUnloadable { root: DocumentId },
    /// A `Creating` record names a root whose snapshot cannot be strictly loaded.
    CreatingRootUnloadable { root: DocumentId },
    /// A listed document that is not the recorded root cannot be strictly loaded.
    NonRootUnloadable {
        document: DocumentId,
        root: Option<DocumentId>,
    },
    /// A `Creating` or `Joining` record is accompanied by other documents.
    ConflictingDocuments { root: DocumentId },
    /// A `Creating` record's root snapshot has no history.
    CreatingRootEmptyHistory { root: DocumentId },
    /// The bootstrap record's version, state, or root is malformed.
    MalformedControlRecord,
    /// The control store cannot be opened at all.
    ControlStoreUnreadable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Classification {
    Recoverable(RecoveryReason),
    Fatal,
}

impl BootstrapCondition {
    /// Classifies a strict load failure for `document` under `record`.
    #[must_use]
    pub fn for_load_failure(record: Option<&BootstrapRecord>, document: DocumentId) -> Self {
        match record {
            Some(BootstrapRecord::Ready { root }) if *root == document => {
                Self::ReadyRootUnloadable { root: *root }
            }
            Some(BootstrapRecord::Joining { root }) if *root == document => {
                Self::JoiningRootUnloadable { root: *root }
            }
            Some(BootstrapRecord::Creating { root }) if *root == document => {
                Self::CreatingRootUnloadable { root: *root }
            }
            other => Self::NonRootUnloadable {
                document,
                root: other.map(BootstrapRecord::root),
            },
        }
    }

    #[must_use]
    pub const fn classify(&self) -> Classification {
        match self {
            Self::OrphanedDocuments { .. } => {
                Classification::Recoverable(RecoveryReason::OrphanedDocuments)
            }
            Self::ReadyRootMissing { .. } => {
                Classification::Recoverable(RecoveryReason::RootSnapshotMissing)
            }
            Self::ReadyRootUnloadable { .. } | Self::JoiningRootUnloadable { .. } => {
                Classification::Recoverable(RecoveryReason::RootSnapshotCorrupt)
            }
            Self::CreatingRootUnloadable { .. }
            | Self::NonRootUnloadable { .. }
            | Self::ConflictingDocuments { .. }
            | Self::CreatingRootEmptyHistory { .. }
            | Self::MalformedControlRecord
            | Self::ControlStoreUnreadable => Classification::Fatal,
        }
    }

    #[must_use]
    pub const fn is_recoverable(&self) -> bool {
        matches!(self.classify(), Classification::Recoverable(_))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_classification_table_row_is_typed() {
        let root = DocumentId::new();
        let other = DocumentId::new();
        let rows = [
            (
                BootstrapCondition::OrphanedDocuments {
                    documents: vec![other],
                },
                Classification::Recoverable(RecoveryReason::OrphanedDocuments),
            ),
            (
                BootstrapCondition::ReadyRootMissing { root },
                Classification::Recoverable(RecoveryReason::RootSnapshotMissing),
            ),
            (
                BootstrapCondition::ReadyRootUnloadable { root },
                Classification::Recoverable(RecoveryReason::RootSnapshotCorrupt),
            ),
            (
                BootstrapCondition::JoiningRootUnloadable { root },
                Classification::Recoverable(RecoveryReason::RootSnapshotCorrupt),
            ),
            (
                BootstrapCondition::CreatingRootUnloadable { root },
                Classification::Fatal,
            ),
            (
                BootstrapCondition::NonRootUnloadable {
                    document: other,
                    root: Some(root),
                },
                Classification::Fatal,
            ),
            (
                BootstrapCondition::ConflictingDocuments { root },
                Classification::Fatal,
            ),
            (
                BootstrapCondition::CreatingRootEmptyHistory { root },
                Classification::Fatal,
            ),
            (
                BootstrapCondition::MalformedControlRecord,
                Classification::Fatal,
            ),
            (
                BootstrapCondition::ControlStoreUnreadable,
                Classification::Fatal,
            ),
        ];
        for (condition, expected) in rows {
            assert_eq!(condition.classify(), expected, "{condition:?}");
        }
    }

    #[test]
    fn load_failures_are_recoverable_only_for_the_recorded_root_under_ready_or_joining() {
        let root = DocumentId::new();
        let other = DocumentId::new();
        assert!(
            BootstrapCondition::for_load_failure(Some(&BootstrapRecord::Ready { root }), root)
                .is_recoverable()
        );
        assert!(
            BootstrapCondition::for_load_failure(Some(&BootstrapRecord::Joining { root }), root)
                .is_recoverable()
        );
        assert!(
            !BootstrapCondition::for_load_failure(Some(&BootstrapRecord::Creating { root }), root)
                .is_recoverable()
        );
        assert!(
            !BootstrapCondition::for_load_failure(Some(&BootstrapRecord::Ready { root }), other)
                .is_recoverable()
        );
        assert_eq!(
            BootstrapCondition::for_load_failure(None, other),
            BootstrapCondition::NonRootUnloadable {
                document: other,
                root: None
            }
        );
    }

    #[test]
    fn quarantine_reason_round_trips_through_its_name() {
        for reason in [
            QuarantineReason::CorruptRoot,
            QuarantineReason::Orphaned,
            QuarantineReason::ControlStoreUnreadable,
        ] {
            assert_eq!(QuarantineReason::parse(reason.as_str()), Some(reason));
        }
        assert_eq!(QuarantineReason::parse("unknown"), None);
    }
}
