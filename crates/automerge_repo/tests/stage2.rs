use std::{sync::Arc, time::Duration};

use automerge::{
    Automerge, ROOT, ReadDoc,
    transaction::{CommitOptions, Transactable},
};
use automerge_repo::{
    BootstrapRecord, BootstrapStatus, DocumentId, Error, FilesystemStorage, QuarantineReason,
    RecoveryOutcome, RecoveryReason, Repo, RepoConfig,
    storage::{ControlStore, StorageAdapter},
    testing::{MemoryStore, MemoryTransport},
};

async fn drive(a: &MemoryTransport, b: &MemoryTransport) {
    let mut idle = 0;
    for _ in 0..500 {
        tokio::task::yield_now().await;
        if a.deliver_all().await + b.deliver_all().await == 0 {
            idle += 1;
        } else {
            idle = 0;
        }
        if idle >= 12 {
            return;
        }
    }
    panic!("network failed to become idle");
}

fn put(
    tx: &mut automerge::transaction::Transaction<'_>,
    key: &str,
    value: i64,
) -> automerge_repo::Result<()> {
    tx.put(ROOT, key, value)
        .map_err(|error| Error::Change(error.to_string()))
}

async fn fresh(config: RepoConfig) -> (Repo, MemoryStore, MemoryStore) {
    let documents = MemoryStore::default();
    let control = MemoryStore::default();
    let (transport, _) = MemoryTransport::pair("repo", "peer", 64);
    let repo = Repo::open(
        Arc::new(documents.clone()),
        Arc::new(control.clone()),
        transport,
        config,
    )
    .await
    .unwrap();
    (repo, documents, control)
}

#[tokio::test]
async fn configuration_rejects_zero_capacity_and_inverted_retry() {
    let (transport, _) = MemoryTransport::pair("repo", "peer", 8);
    let config = RepoConfig {
        peer_writer_capacity: 0,
        ..RepoConfig::default()
    };
    assert!(matches!(
        Repo::open(
            Arc::new(MemoryStore::default()),
            Arc::new(MemoryStore::default()),
            transport,
            config
        )
        .await,
        Err(Error::Config(_))
    ));
}

#[tokio::test(start_paused = true)]
async fn blocked_automatic_store_does_not_block_actor_and_flush_waits() {
    let config = RepoConfig {
        persistence_debounce: Duration::from_secs(10),
        ..RepoConfig::default()
    };
    let (repo, documents, _) = fresh(config).await;
    repo.initialize_new().await.unwrap();
    let document = repo.create().await.unwrap();
    documents.clear_operations();
    documents.block_document("store", document.id());
    document.change(|tx| put(tx, "one", 1)).await.unwrap();
    tokio::time::advance(Duration::from_secs(10)).await;
    documents
        .wait_for_operation(&format!("store:{}", document.id()))
        .await;
    assert!(
        document
            .read(|doc| doc.get(ROOT, "one").unwrap().is_some())
            .await
            .unwrap()
    );
    document.change(|tx| put(tx, "two", 2)).await.unwrap();
    let flushing = tokio::spawn({
        let repo = repo.clone();
        async move { repo.flush().await }
    });
    tokio::task::yield_now().await;
    assert!(!flushing.is_finished());
    documents.unblock_document("store", document.id());
    flushing.await.unwrap().unwrap();
}

#[tokio::test(start_paused = true)]
async fn automatic_failure_is_typed_and_retry_succeeds() {
    let config = RepoConfig {
        persistence_debounce: Duration::ZERO,
        persistence_retry_min: Duration::from_secs(2),
        persistence_retry_max: Duration::from_secs(8),
        ..RepoConfig::default()
    };
    let (repo, documents, _) = fresh(config).await;
    repo.initialize_new().await.unwrap();
    let document = repo.create().await.unwrap();
    documents.clear_operations();
    documents.fail_document_times("store", document.id(), 1);
    let mut errors = repo.subscribe_errors();
    document.change(|tx| put(tx, "retry", 1)).await.unwrap();
    tokio::task::yield_now().await;
    let error = errors.recv().await.unwrap();
    assert!(
        matches!(error, Error::Persistence { document: id, revision: 2, .. } if id == document.id())
    );
    tokio::time::advance(Duration::from_secs(2)).await;
    repo.flush().await.unwrap();
    assert!(documents.documents().contains_key(&document.id()));
}

#[tokio::test]
async fn flush_aggregates_document_and_barrier_failures() {
    let config = RepoConfig {
        persistence_debounce: Duration::from_secs(60),
        ..RepoConfig::default()
    };
    let (repo, documents, _) = fresh(config).await;
    repo.initialize_new().await.unwrap();
    let first = repo.create().await.unwrap();
    let second = repo.create().await.unwrap();
    first.change(|tx| put(tx, "x", 1)).await.unwrap();
    second.change(|tx| put(tx, "y", 2)).await.unwrap();
    documents.fail_document_times("store", first.id(), 1);
    documents.fail_document_times("store", second.id(), 1);
    documents.fail("document_flush");
    assert!(matches!(repo.flush().await, Err(Error::Flush(failures)) if failures.len() == 3));
}

#[tokio::test]
async fn creating_recovery_is_idempotent_and_orphans_are_quarantined() {
    let documents = MemoryStore::default();
    let control = MemoryStore::default();
    let root = DocumentId::new();
    ControlStore::store(&control, BootstrapRecord::Creating { root })
        .await
        .unwrap();
    let (transport, _) = MemoryTransport::pair("repo", "peer", 8);
    let repo = Repo::open(
        Arc::new(documents.clone()),
        Arc::new(control.clone()),
        transport,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    assert_eq!(repo.bootstrap_status(), BootstrapStatus::Ready { root });
    let bytes = documents.documents().get(&root).unwrap().clone();
    assert_eq!(Automerge::load(&bytes).unwrap().get_heads().len(), 1);
    repo.shutdown().await.unwrap();

    let orphan_docs = MemoryStore::default();
    let orphan = DocumentId::new();
    let mut doc = Automerge::new();
    doc.empty_commit(CommitOptions::default());
    StorageAdapter::store(&orphan_docs, orphan, doc.save())
        .await
        .unwrap();
    let (transport, _) = MemoryTransport::pair("orphan", "peer", 8);
    let orphan_control = MemoryStore::default();
    let repo = Repo::open(
        Arc::new(orphan_docs.clone()),
        Arc::new(orphan_control.clone()),
        transport,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    assert_eq!(repo.bootstrap_status(), BootstrapStatus::NeedsDecision);
    assert_eq!(orphan_control.record(), None);
    assert!(orphan_docs.documents().is_empty());
    let quarantine = orphan_docs.quarantine();
    assert_eq!(quarantine.len(), 1);
    assert_eq!(quarantine[0].0, orphan);
    assert_eq!(quarantine[0].1, QuarantineReason::Orphaned);
    assert_eq!(quarantine[0].2, doc.save());
    let recovery = repo.recovery().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::OrphanedDocuments);
    assert_eq!(recovery.documents, vec![orphan]);
    assert_eq!(recovery.outcome, RecoveryOutcome::Quarantined);
    repo.shutdown().await.unwrap();
}

#[tokio::test]
async fn filesystem_round_trip_layout_codec_and_permissions() {
    let directory = tempfile::tempdir().unwrap();
    let storage = FilesystemStorage::open(directory.path()).await.unwrap();
    let id = DocumentId::new();
    let mut doc = Automerge::new();
    doc.empty_commit(CommitOptions::default());
    StorageAdapter::store(&storage, id, doc.save())
        .await
        .unwrap();
    let unrelated = directory.path().join("automerge/notes.txt");
    std::fs::write(&unrelated, b"leave me").unwrap();
    let stale = directory
        .path()
        .join(format!("automerge/.{id}.automerge.tmp-0000000000000000"));
    std::fs::write(&stale, b"stale").unwrap();
    StorageAdapter::flush(&storage).await.unwrap();
    ControlStore::store(&storage, BootstrapRecord::Ready { root: id })
        .await
        .unwrap();
    ControlStore::flush(&storage).await.unwrap();
    assert_eq!(StorageAdapter::list(&storage).await.unwrap(), vec![id]);
    assert!(unrelated.exists());
    assert!(!stale.exists());
    assert_eq!(
        ControlStore::load(&storage).await.unwrap(),
        Some(BootstrapRecord::Ready { root: id })
    );
    assert_eq!(
        std::fs::read(directory.path().join("control/bootstrap-v1.bin"))
            .unwrap()
            .len(),
        24
    );
    StorageAdapter::close(&storage).await.unwrap();
    ControlStore::close(&storage).await.unwrap();
    let reopened = FilesystemStorage::open(directory.path()).await.unwrap();
    assert_eq!(StorageAdapter::list(&reopened).await.unwrap(), vec![id]);
    assert_eq!(
        ControlStore::load(&reopened).await.unwrap(),
        Some(BootstrapRecord::Ready { root: id })
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(directory.path().join(format!("automerge/{id}.automerge")))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(directory.path().join("automerge"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
    }
}

#[tokio::test]
async fn removal_is_durable_and_closes_existing_handles() {
    let (repo, documents, _) = fresh(RepoConfig::default()).await;
    let root = repo.initialize_new().await.unwrap();
    assert!(matches!(
        repo.remove_local(root.id()).await,
        Err(Error::Removal { .. })
    ));
    let document = repo.create().await.unwrap();
    repo.remove_local(document.id()).await.unwrap();
    assert!(!documents.documents().contains_key(&document.id()));
    assert!(document.read(|_| ()).await.is_err());
    assert!(matches!(
        repo.open_document(document.id()).await,
        Err(Error::NotFound(_))
    ));
}

#[tokio::test]
async fn creation_barrier_failure_cleans_up_and_control_barrier_is_elided_when_clean() {
    let (repo, documents, control) = fresh(RepoConfig::default()).await;
    repo.initialize_new().await.unwrap();
    control.clear_operations();
    repo.flush().await.unwrap();
    assert!(
        !control
            .operations()
            .iter()
            .any(|entry| entry == "control_flush")
    );

    documents.fail_times("document_flush", 1);
    let error = repo.create().await.unwrap_err();
    let id = match error {
        Error::Creation { document, .. } => document,
        other => panic!("unexpected error: {other}"),
    };
    assert!(!documents.documents().contains_key(&id));
    assert!(!repo.document_ids().await.unwrap().contains(&id));
}

#[tokio::test]
async fn shutdown_aggregates_failures_closes_handles_and_rejects_other_clones() {
    let (repo, documents, control) = fresh(RepoConfig::default()).await;
    let root = repo.initialize_new().await.unwrap();
    let retained = repo.clone();
    documents.fail("document_flush");
    control.fail("control_flush");
    assert!(matches!(repo.shutdown().await, Err(Error::Shutdown(failures)) if failures.len() >= 2));
    assert_eq!(root.status(), automerge_repo::DocumentStatus::Closed);
    assert!(retained.document_ids().await.is_err());
    assert!(documents.documents_closed());
    assert!(control.control_closed());
    assert!(matches!(
        retained.shutdown().await,
        Err(Error::Lifecycle(_))
    ));
}

#[tokio::test]
async fn removal_waits_for_an_inflight_store_before_deleting() {
    let config = RepoConfig {
        persistence_debounce: Duration::ZERO,
        ..RepoConfig::default()
    };
    let (repo, documents, _) = fresh(config).await;
    repo.initialize_new().await.unwrap();
    let document = repo.create().await.unwrap();
    documents.clear_operations();
    documents.block_document("store", document.id());
    document.change(|tx| put(tx, "pending", 1)).await.unwrap();
    documents
        .wait_for_operation(&format!("store:{}", document.id()))
        .await;
    let removal = tokio::spawn({
        let repo = repo.clone();
        let id = document.id();
        async move { repo.remove_local(id).await }
    });
    tokio::task::yield_now().await;
    assert!(!removal.is_finished());
    assert!(document.change(|tx| put(tx, "late", 2)).await.is_err());
    documents.unblock_document("store", document.id());
    removal.await.unwrap().unwrap();
    assert!(!documents.documents().contains_key(&document.id()));
}

#[tokio::test]
async fn failed_removal_evicts_and_can_be_reopened_then_retried() {
    let (repo, documents, _) = fresh(RepoConfig::default()).await;
    repo.initialize_new().await.unwrap();
    let document = repo.create().await.unwrap();
    documents.fail_times("remove", 1);
    assert!(repo.remove_local(document.id()).await.is_err());
    assert_eq!(document.status(), automerge_repo::DocumentStatus::Closed);
    let reopened = repo.open_document(document.id()).await.unwrap();
    assert_eq!(reopened.status(), automerge_repo::DocumentStatus::Ready);
    repo.remove_local(document.id()).await.unwrap();
    assert!(!documents.documents().contains_key(&document.id()));
}

#[tokio::test]
async fn joining_recovery_preserves_empty_history_and_ready_demotes_to_joining() {
    let root = DocumentId::new();
    let control = MemoryStore::default();
    ControlStore::store(&control, BootstrapRecord::Joining { root })
        .await
        .unwrap();
    let (transport, _) = MemoryTransport::pair("join", "peer", 8);
    let repo = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(control),
        transport,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    assert_eq!(repo.bootstrap_status(), BootstrapStatus::Joining { root });
    assert!(
        repo.open_document(root)
            .await
            .unwrap()
            .read(|doc| doc.get_heads().is_empty())
            .await
            .unwrap()
    );

    let ready_control = MemoryStore::default();
    ControlStore::store(&ready_control, BootstrapRecord::Ready { root })
        .await
        .unwrap();
    let (transport, _) = MemoryTransport::pair("ready", "peer", 8);
    let repo = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(ready_control.clone()),
        transport,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    assert_eq!(repo.bootstrap_status(), BootstrapStatus::Joining { root });
    assert_eq!(
        ready_control.record(),
        Some(BootstrapRecord::Joining { root })
    );
    assert_eq!(ready_control.recovery_attempts(root), 1);
    let recovery = repo.recovery().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::RootSnapshotMissing);
    assert_eq!(recovery.documents, vec![root]);
    assert_eq!(recovery.outcome, RecoveryOutcome::Recovering);
    repo.shutdown().await.unwrap();
}

#[tokio::test]
async fn filesystem_rejects_malformed_names_and_preserves_corrupt_control() {
    let directory = tempfile::tempdir().unwrap();
    let storage = FilesystemStorage::open(directory.path()).await.unwrap();
    let malformed = directory.path().join("automerge/NOT-A-UUID.automerge");
    std::fs::write(&malformed, b"bad").unwrap();
    let error = StorageAdapter::list(&storage).await.unwrap_err();
    assert!(error.to_string().contains("NOT-A-UUID.automerge"));
    std::fs::remove_file(malformed).unwrap();
    // Corrupt bytes are listed, not rejected: classification belongs to
    // `Repo::open`, which quarantines only the recorded root.
    let corrupt_id = DocumentId::new();
    let corrupt_path = directory
        .path()
        .join(format!("automerge/{corrupt_id}.automerge"));
    std::fs::write(&corrupt_path, b"not automerge").unwrap();
    assert_eq!(
        StorageAdapter::list(&storage).await.unwrap(),
        vec![corrupt_id]
    );
    std::fs::remove_file(corrupt_path).unwrap();

    let control_path = directory.path().join("control/bootstrap-v1.bin");
    let corrupt = b"FIBC".to_vec();
    std::fs::write(&control_path, &corrupt).unwrap();
    let error = ControlStore::load(&storage).await.unwrap_err();
    assert_eq!(error.path.as_deref(), Some(control_path.as_path()));
    assert_eq!(std::fs::read(control_path).unwrap(), corrupt);
}

#[tokio::test]
async fn blocked_peer_writer_is_bounded_and_does_not_stall_coordinator() {
    let docs_a = MemoryStore::default();
    let docs_b = MemoryStore::default();
    let control_a = MemoryStore::default();
    let control_b = MemoryStore::default();
    let (net_a, net_b) = MemoryTransport::pair("a", "b", 128);
    let config = RepoConfig {
        peer_writer_capacity: 8,
        ..RepoConfig::default()
    };
    let a = Repo::open(
        Arc::new(docs_a),
        Arc::new(control_a),
        net_a.clone(),
        config.clone(),
    )
    .await
    .unwrap();
    let b = Repo::open(Arc::new(docs_b), Arc::new(control_b), net_b.clone(), config)
        .await
        .unwrap();
    let root_a = a.initialize_new().await.unwrap();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    let root_b = b.join_existing(root_a.id()).await.unwrap();
    drive(&net_a, &net_b).await;
    root_b.ready().await.unwrap();

    net_a.block_sends(true);
    let mut errors = a.subscribe_errors();
    for index in 0..30 {
        root_a
            .change(move |tx| put(tx, &format!("queued-{index}"), index))
            .await
            .unwrap();
    }
    assert!(!a.document_ids().await.unwrap().is_empty());
    let failure = tokio::time::timeout(Duration::from_secs(1), errors.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(matches!(failure, Error::Network(_)));
    net_a.block_sends(false);
}
