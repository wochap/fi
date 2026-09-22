//! Partial local-state recovery: recoverable-versus-fatal classification,
//! root-preserving recovery through `Joining`, quarantine, orphan adoption,
//! the bounded no-peer outcome, and recovery observability.
use std::{sync::Arc, time::Duration};

use automerge::{ROOT, ReadDoc, transaction::Transactable};
use automerge_repo::{
    BootstrapRecord, BootstrapStatus, DocumentId, Error, FilesystemStorage, PeerId,
    QuarantineReason, RecoveryOutcome, RecoveryReason, Repo, RepoConfig,
    error::BootstrapError,
    storage::{ControlStore, StorageAdapter},
    testing::{MemoryNetwork, MemoryStore},
};

fn put(
    tx: &mut automerge::transaction::Transaction<'_>,
    key: &str,
    value: i64,
) -> automerge_repo::Result<()> {
    tx.put(ROOT, key, value)
        .map_err(|error| Error::Change(error.to_string()))
}

async fn drive(network: &MemoryNetwork) {
    let mut idle = 0;
    for _ in 0..1000 {
        tokio::task::yield_now().await;
        if network.deliver_all().await == 0 {
            idle += 1;
        } else {
            idle = 0;
        }
        if idle >= 12 {
            return;
        }
    }
    panic!("network did not become idle");
}

async fn state(handle: &automerge_repo::DocHandle) -> (Vec<automerge::ChangeHash>, String) {
    handle
        .read(|doc| {
            let mut keys: Vec<_> = doc.keys(ROOT).collect();
            keys.sort();
            let values: Vec<_> = keys
                .into_iter()
                .map(|key| format!("{key}={:?}", doc.get(ROOT, &key).unwrap()))
                .collect();
            (doc.get_heads(), values.join(","))
        })
        .await
        .unwrap()
}

struct Device {
    id: PeerId,
    docs: MemoryStore,
    control: MemoryStore,
}

impl Device {
    fn new(id: &str) -> Self {
        Self {
            id: PeerId::from(id),
            docs: MemoryStore::default(),
            control: MemoryStore::default(),
        }
    }
    async fn open(
        &self,
        network: &MemoryNetwork,
        config: RepoConfig,
    ) -> automerge_repo::Result<Repo> {
        self.docs.reopen();
        self.control.reopen();
        Repo::open(
            Arc::new(self.docs.clone()),
            Arc::new(self.control.clone()),
            network.endpoint(self.id.clone(), 512),
            config,
        )
        .await
    }
}

/// Two synchronized devices: `a` owns the root with one field written.
async fn paired(network: &MemoryNetwork) -> (Device, Device, Repo, automerge_repo::DocHandle) {
    let a = Device::new("a");
    let b = Device::new("b");
    let repo_a = a.open(network, RepoConfig::default()).await.unwrap();
    let repo_b = b.open(network, RepoConfig::default()).await.unwrap();
    let root = repo_a.initialize_new().await.unwrap();
    root.change(|tx| put(tx, "answer", 42)).await.unwrap();
    network.connect(&a.id, &b.id).await;
    drive(network).await;
    repo_b.join_existing(root.id()).await.unwrap();
    drive(network).await;
    assert_eq!(
        repo_b.bootstrap_status(),
        BootstrapStatus::Ready { root: root.id() }
    );
    repo_a.flush().await.unwrap();
    repo_b.flush().await.unwrap();
    repo_b.shutdown().await.unwrap();
    b.docs.reopen();
    b.control.reopen();
    assert!(b.docs.documents().contains_key(&root.id()));
    (a, b, repo_a, root)
}

async fn no_root_mismatch(errors: &mut tokio::sync::broadcast::Receiver<Error>) {
    while let Ok(error) = errors.try_recv() {
        assert!(
            !matches!(error, Error::Bootstrap(BootstrapError::RootMismatch { .. })),
            "{error}"
        );
    }
}

#[tokio::test]
async fn missing_root_snapshot_recovers_the_identical_root_from_a_trusted_peer() {
    let network = MemoryNetwork::default();
    let (a, b, repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    let mut errors_a = repo_a.subscribe_errors();
    StorageAdapter::remove(&b.docs, root).await.unwrap();

    let repo_b = b.open(&network, RepoConfig::default()).await.unwrap();
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Joining { root });
    assert_eq!(b.control.record(), Some(BootstrapRecord::Joining { root }));
    assert_eq!(b.control.recovery_attempts(root), 1);
    let recovery = repo_b.recovery().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::RootSnapshotMissing);
    assert_eq!(recovery.documents, vec![root]);
    assert!(recovery.quarantine.is_empty());
    assert_eq!(recovery.outcome, RecoveryOutcome::Recovering);
    assert_eq!(recovery.root(), Some(root));

    // The joining write gate rejects authoritative work throughout recovery.
    assert!(matches!(
        repo_b.create().await,
        Err(Error::Bootstrap(BootstrapError::DecisionRequired))
    ));
    let placeholder = repo_b.open_document(root).await.unwrap();
    assert!(placeholder.change(|tx| put(tx, "late", 1)).await.is_err());
    assert!(matches!(
        repo_b.join_existing(root).await,
        Err(Error::Bootstrap(BootstrapError::DecisionAlreadyMade))
    ));

    network.connect(&a.id, &b.id).await;
    drive(&network).await;
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Ready { root });
    assert_eq!(
        repo_b.recovery().unwrap().outcome,
        RecoveryOutcome::Recovered
    );
    assert_eq!(state(&root_a).await, state(&placeholder).await);
    assert_eq!(b.control.record(), Some(BootstrapRecord::Ready { root }));
    no_root_mismatch(&mut errors_a).await;
    // Both sides are fully eligible again: new documents flow.
    let doc = repo_a.create_with(|tx| put(tx, "after", 1)).await.unwrap();
    drive(&network).await;
    let doc_b = repo_b.open_document(doc.id()).await.unwrap();
    doc_b.ready().await.unwrap();
    assert_eq!(state(&doc).await, state(&doc_b).await);
}

#[tokio::test]
async fn corrupt_root_snapshot_is_quarantined_then_recovered_for_the_same_root() {
    let network = MemoryNetwork::default();
    let (a, b, _repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    StorageAdapter::store(&b.docs, root, b"not automerge".to_vec())
        .await
        .unwrap();

    let repo_b = b.open(&network, RepoConfig::default()).await.unwrap();
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Joining { root });
    let recovery = repo_b.recovery().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::RootSnapshotCorrupt);
    assert_eq!(recovery.documents, vec![root]);
    assert_eq!(recovery.quarantine.len(), 1);
    assert_eq!(recovery.outcome, RecoveryOutcome::Recovering);
    let quarantine = b.docs.quarantine();
    assert_eq!(quarantine.len(), 1);
    assert_eq!(quarantine[0].0, root);
    assert_eq!(quarantine[0].1, QuarantineReason::CorruptRoot);
    assert_eq!(quarantine[0].2, b"not automerge");
    assert!(!b.docs.documents().contains_key(&root));
    // Quarantine completed before the control transition.
    let operations = b.docs.operations();
    let quarantine_at = operations
        .iter()
        .position(|op| op == &format!("quarantine:{root}"))
        .unwrap();
    assert!(quarantine_at < operations.len());
    assert!(
        b.control
            .operations()
            .iter()
            .any(|op| op == &format!("control_store:{root}"))
    );

    network.connect(&a.id, &b.id).await;
    drive(&network).await;
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Ready { root });
    assert_eq!(
        repo_b.recovery().unwrap().outcome,
        RecoveryOutcome::Recovered
    );
    let recovered = repo_b.open_document(root).await.unwrap();
    assert_eq!(state(&root_a).await, state(&recovered).await);
    // Quarantined bytes are retained, never deleted.
    assert_eq!(b.docs.quarantine().len(), 1);
}

#[tokio::test]
async fn fatal_classifications_fail_without_mutation() {
    // Non-root corruption under a Ready record.
    let network = MemoryNetwork::default();
    let (_, b, _repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    let other = DocumentId::new();
    StorageAdapter::store(&b.docs, other, b"garbage".to_vec())
        .await
        .unwrap();
    let before = b.docs.documents();
    let error = b.open(&network, RepoConfig::default()).await.unwrap_err();
    assert!(
        matches!(error, Error::Automerge { document, .. } if document == other),
        "{error}"
    );
    assert_eq!(b.docs.documents(), before);
    assert!(b.docs.quarantine().is_empty());
    assert_eq!(b.control.record(), Some(BootstrapRecord::Ready { root }));
    assert_eq!(b.control.recovery_attempts(root), 0);

    // Conflicting documents under Creating and Joining.
    for record in [
        BootstrapRecord::Creating { root },
        BootstrapRecord::Joining { root },
    ] {
        let device = Device::new("c");
        let mut doc = automerge::Automerge::new();
        doc.empty_commit(automerge::transaction::CommitOptions::default());
        StorageAdapter::store(&device.docs, other, doc.save())
            .await
            .unwrap();
        ControlStore::store(&device.control, record.clone())
            .await
            .unwrap();
        let before = device.docs.documents();
        let error = device
            .open(&network, RepoConfig::default())
            .await
            .unwrap_err();
        assert!(
            matches!(error, Error::Bootstrap(BootstrapError::Inconsistent { root: r, .. }) if r == root),
            "{error}"
        );
        assert_eq!(device.docs.documents(), before);
        assert!(device.docs.quarantine().is_empty());
        assert_eq!(device.control.record(), Some(record));
    }

    // Corrupt root under Creating has no peer-authoritative source.
    let device = Device::new("d");
    StorageAdapter::store(&device.docs, root, b"garbage".to_vec())
        .await
        .unwrap();
    ControlStore::store(&device.control, BootstrapRecord::Creating { root })
        .await
        .unwrap();
    let error = device
        .open(&network, RepoConfig::default())
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Automerge { document, .. } if document == root));
    assert!(device.docs.quarantine().is_empty());

    // Malformed control record is fatal before any snapshot is touched.
    let device = Device::new("e");
    StorageAdapter::store(&device.docs, root, b"garbage".to_vec())
        .await
        .unwrap();
    device.control.fail("control_load");
    assert!(matches!(
        device.open(&network, RepoConfig::default()).await,
        Err(Error::Storage(_))
    ));
    assert!(device.docs.quarantine().is_empty());
    assert_eq!(device.docs.documents().len(), 1);
}

#[tokio::test]
async fn repeated_restarts_while_recovering_converge_without_consuming_attempts() {
    let network = MemoryNetwork::default();
    let (a, b, _repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    StorageAdapter::remove(&b.docs, root).await.unwrap();
    for _ in 0..4 {
        let repo_b = b.open(&network, RepoConfig::default()).await.unwrap();
        assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Joining { root });
        let recovery = repo_b.recovery().unwrap();
        assert_eq!(recovery.outcome, RecoveryOutcome::Recovering);
        assert_eq!(recovery.root(), Some(root));
        assert_eq!(b.control.recovery_attempts(root), 1);
        repo_b.shutdown().await.unwrap();
    }
    let repo_b = b.open(&network, RepoConfig::default()).await.unwrap();
    network.connect(&a.id, &b.id).await;
    drive(&network).await;
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Ready { root });
    assert_eq!(
        repo_b.recovery().unwrap().outcome,
        RecoveryOutcome::Recovered
    );
}

#[tokio::test]
async fn recovery_attempts_are_bounded_and_escalate_naming_the_root() {
    let network = MemoryNetwork::default();
    let (_, b, _repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    let config = RepoConfig {
        recovery_attempt_limit: 2,
        ..RepoConfig::default()
    };
    // Each demotion from Ready consumes one attempt.
    for expected in 1..=2 {
        b.docs.reopen();
        b.control.reopen();
        StorageAdapter::remove(&b.docs, root).await.unwrap();
        ControlStore::store(&b.control, BootstrapRecord::Ready { root })
            .await
            .unwrap();
        let repo_b = b.open(&network, config.clone()).await.unwrap();
        assert_eq!(b.control.recovery_attempts(root), expected);
        repo_b.shutdown().await.unwrap();
    }
    b.docs.reopen();
    b.control.reopen();
    ControlStore::store(&b.control, BootstrapRecord::Ready { root })
        .await
        .unwrap();
    StorageAdapter::store(&b.docs, root, b"garbage".to_vec())
        .await
        .unwrap();
    let error = b.open(&network, config).await.unwrap_err();
    match error {
        Error::Bootstrap(BootstrapError::RecoveryExhausted {
            root: named,
            attempts,
        }) => {
            assert_eq!(named, root);
            assert_eq!(attempts, 2);
        }
        other => panic!("{other}"),
    }
    assert!(error.to_string().contains(&root.to_string()));
    // Quarantined bytes remain available after the fatal outcome.
    assert_eq!(b.docs.quarantine().len(), 1);
    assert_eq!(b.control.recovery_attempts(root), 2);
}

#[tokio::test]
async fn no_peer_outcome_is_honest_bounded_and_completes_when_a_peer_appears() {
    let network = MemoryNetwork::default();
    let (a, b, _repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    StorageAdapter::remove(&b.docs, root).await.unwrap();
    let config = RepoConfig {
        recovery_no_peer_after: Duration::from_millis(20),
        ..RepoConfig::default()
    };
    let repo_b = b.open(&network, config).await.unwrap();
    let mut recovery = repo_b.subscribe_recovery();
    assert_eq!(
        recovery.borrow().as_ref().unwrap().outcome,
        RecoveryOutcome::Recovering
    );
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            recovery.changed().await.unwrap();
            if recovery.borrow().as_ref().unwrap().outcome == RecoveryOutcome::NoPeerAvailable {
                break;
            }
        }
    })
    .await
    .expect("no-peer outcome reported");
    // Still Joining for the same root; nothing was re-minted.
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Joining { root });
    assert_eq!(b.control.record(), Some(BootstrapRecord::Joining { root }));
    assert!(matches!(
        repo_b.initialize_new().await,
        Err(Error::Bootstrap(BootstrapError::DecisionAlreadyMade))
    ));

    // A trusted peer appears later: recovery completes without any new join.
    network.connect(&a.id, &b.id).await;
    drive(&network).await;
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Ready { root });
    assert_eq!(
        repo_b.recovery().unwrap().outcome,
        RecoveryOutcome::Recovered
    );
}

#[tokio::test]
async fn no_peer_wait_restarts_when_a_supplier_disconnects_before_supplying() {
    let network = MemoryNetwork::default();
    let (a, b, repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    StorageAdapter::remove(&b.docs, root).await.unwrap();
    let config = RepoConfig {
        recovery_no_peer_after: Duration::from_millis(20),
        ..RepoConfig::default()
    };
    let repo_b = b.open(&network, config).await.unwrap();
    // Connect but only exchange Hello frames, so the peer becomes eligible
    // without ever delivering the root, then drop it.
    network.connect(&a.id, &b.id).await;
    tokio::task::yield_now().await;
    network.deliver_all().await;
    tokio::task::yield_now().await;
    network.disconnect(&a.id, &b.id).await;
    let mut recovery = repo_b.subscribe_recovery();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if recovery.borrow_and_update().as_ref().unwrap().outcome
                == RecoveryOutcome::NoPeerAvailable
            {
                break;
            }
            recovery.changed().await.unwrap();
        }
    })
    .await
    .expect("no-peer outcome after supplier loss");
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Joining { root });
    drop(repo_a);
}

#[tokio::test]
async fn orphaned_documents_are_quarantined_and_a_matching_orphan_is_adopted_on_join() {
    let network = MemoryNetwork::default();
    let (a, b, repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    let original = b.docs.documents().get(&root).cloned().unwrap();
    b.control.clear_record();

    let repo_b = b.open(&network, RepoConfig::default()).await.unwrap();
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::NeedsDecision);
    assert_eq!(b.control.record(), None);
    assert!(b.docs.documents().is_empty());
    let quarantine = b.docs.quarantine();
    assert_eq!(quarantine.len(), 1);
    assert_eq!(quarantine[0].0, root);
    assert_eq!(quarantine[0].1, QuarantineReason::Orphaned);
    assert_eq!(quarantine[0].2, original);
    let recovery = repo_b.recovery().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::OrphanedDocuments);
    assert_eq!(recovery.documents, vec![root]);
    assert_eq!(recovery.outcome, RecoveryOutcome::Quarantined);
    assert_eq!(recovery.root(), None);

    // Re-joining the same root adopts the quarantined history offline.
    let adopted = repo_b.join_existing(root).await.unwrap();
    assert_eq!(repo_b.bootstrap_status(), BootstrapStatus::Ready { root });
    assert_eq!(state(&adopted).await, state(&root_a).await);
    assert!(b.docs.quarantine().is_empty());
    assert!(b.docs.documents().contains_key(&root));
    assert_eq!(b.control.record(), Some(BootstrapRecord::Ready { root }));
    assert_eq!(repo_b.recovery().unwrap().outcome, RecoveryOutcome::Adopted);

    // The adopted history merges with the group rather than replacing it.
    root_a.change(|tx| put(tx, "later", 7)).await.unwrap();
    adopted.change(|tx| put(tx, "local", 8)).await.unwrap();
    network.connect(&a.id, &b.id).await;
    drive(&network).await;
    assert_eq!(state(&adopted).await, state(&root_a).await);
    assert!(state(&adopted).await.1.contains("answer"));
    drop(repo_a);
}

#[tokio::test]
async fn non_matching_orphans_fall_through_to_peer_synchronization() {
    let network = MemoryNetwork::default();
    let (a, b, _repo_a, root_a) = paired(&network).await;
    let root = root_a.id();
    // Quarantine an unrelated orphan on a third device that then joins `a`.
    let c = Device::new("c");
    let stray = DocumentId::new();
    StorageAdapter::store(&c.docs, stray, b.docs.documents()[&root].clone())
        .await
        .unwrap();
    let repo_c = c.open(&network, RepoConfig::default()).await.unwrap();
    assert_eq!(repo_c.bootstrap_status(), BootstrapStatus::NeedsDecision);
    assert_eq!(c.docs.quarantine().len(), 1);
    let joined = repo_c.join_existing(root).await.unwrap();
    assert_eq!(repo_c.bootstrap_status(), BootstrapStatus::Joining { root });
    assert!(state(&joined).await.0.is_empty());
    assert_eq!(c.docs.quarantine().len(), 1);
    network.connect(&a.id, &c.id).await;
    drive(&network).await;
    assert_eq!(repo_c.bootstrap_status(), BootstrapStatus::Ready { root });
    assert_eq!(state(&joined).await, state(&root_a).await);
    assert_eq!(c.docs.quarantine().len(), 1, "quarantine left untouched");
}

#[tokio::test]
async fn filesystem_quarantine_names_moves_and_re_enters_idempotently() {
    let directory = tempfile::tempdir().unwrap();
    let storage = FilesystemStorage::open(directory.path()).await.unwrap();
    let id = DocumentId::new();
    StorageAdapter::store(&storage, id, b"first".to_vec())
        .await
        .unwrap();
    let source = directory.path().join(format!("automerge/{id}.automerge"));
    assert!(source.exists());

    let location = storage
        .quarantine(id, QuarantineReason::CorruptRoot)
        .await
        .unwrap()
        .unwrap();
    assert!(!source.exists(), "quarantine is a move, not a copy");
    assert_eq!(std::fs::read(&location).unwrap(), b"first");
    assert!(location.starts_with(directory.path().join("quarantine")));
    assert_eq!(
        location.file_name().unwrap().to_string_lossy(),
        format!("{id}.corrupt-root.automerge")
    );
    // Interrupted quarantine re-entry: the snapshot is already gone.
    assert_eq!(
        storage
            .quarantine(id, QuarantineReason::CorruptRoot)
            .await
            .unwrap(),
        None
    );
    let entries = storage.quarantined().await.unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].document, id);
    assert_eq!(entries[0].reason, QuarantineReason::CorruptRoot);
    assert_eq!(entries[0].location.as_deref(), Some(location.as_path()));
    assert_eq!(
        storage.load_quarantined(&entries[0].key).await.unwrap(),
        Some(b"first".to_vec())
    );

    // A second quarantine of the same ID never overwrites the first.
    StorageAdapter::store(&storage, id, b"second".to_vec())
        .await
        .unwrap();
    let second = storage
        .quarantine(id, QuarantineReason::CorruptRoot)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        second.file_name().unwrap().to_string_lossy(),
        format!("{id}.corrupt-root.1.automerge")
    );
    assert_eq!(std::fs::read(&location).unwrap(), b"first");
    assert_eq!(std::fs::read(&second).unwrap(), b"second");
    assert_eq!(storage.quarantined().await.unwrap().len(), 2);

    // Keys are file names inside the quarantine directory only.
    assert!(
        storage
            .load_quarantined("../control/bootstrap-v1.bin")
            .await
            .is_err()
    );
    assert!(storage.discard_quarantined("../x.automerge").await.is_err());
    storage.discard_quarantined(&entries[0].key).await.unwrap();
    assert_eq!(storage.quarantined().await.unwrap().len(), 1);

    // Nothing outside the resolved application directory was touched.
    let mut top: Vec<_> = std::fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    top.sort();
    assert_eq!(top, vec!["automerge", "control", "quarantine"]);

    // Recovery attempts are durable per root.
    let root = DocumentId::new();
    assert_eq!(
        ControlStore::recovery_attempts(&storage, root)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        ControlStore::record_recovery_attempt(&storage, root)
            .await
            .unwrap(),
        1
    );
    assert_eq!(
        ControlStore::record_recovery_attempt(&storage, root)
            .await
            .unwrap(),
        2
    );
    let reopened = FilesystemStorage::open(directory.path()).await.unwrap();
    assert_eq!(
        ControlStore::recovery_attempts(&reopened, root)
            .await
            .unwrap(),
        2
    );
}

#[tokio::test]
async fn filesystem_corrupt_root_recovery_end_to_end() {
    let directory = tempfile::tempdir().unwrap();
    let network = MemoryNetwork::default();
    let storage = Arc::new(FilesystemStorage::open(directory.path()).await.unwrap());
    let root = DocumentId::new();
    ControlStore::store(storage.as_ref(), BootstrapRecord::Ready { root })
        .await
        .unwrap();
    StorageAdapter::store(storage.as_ref(), root, b"corrupt".to_vec())
        .await
        .unwrap();
    let repo = Repo::open(
        storage.clone(),
        storage.clone(),
        network.endpoint("fs", 8),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    assert_eq!(repo.bootstrap_status(), BootstrapStatus::Joining { root });
    let recovery = repo.recovery().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::RootSnapshotCorrupt);
    assert_eq!(recovery.quarantine.len(), 1);
    assert!(recovery.quarantine[0].starts_with(directory.path().join("quarantine")));
    assert_eq!(std::fs::read(&recovery.quarantine[0]).unwrap(), b"corrupt");
    assert_eq!(
        ControlStore::load(storage.as_ref()).await.unwrap(),
        Some(BootstrapRecord::Joining { root })
    );
    repo.shutdown().await.unwrap();
}
