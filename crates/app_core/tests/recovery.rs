//! End-to-end acceptance for partial local-state recovery: root snapshot loss
//! recovered from a trusted peer over real Quinn, the honest no-peer outcome,
//! orphaned-document quarantine and adoption, and the fatal cases that must
//! stay fatal.
use std::{collections::BTreeMap, net::SocketAddr, path::Path, sync::Arc, time::Duration};

use app_core::{
    AppCore, AppCoreConfig, ApplicationState, BootstrapError, DeviceIdentity, DisplayMetadata,
    EndpointSource, FieldDefinition, FieldId, FieldType, FieldValue, InMemorySecureKeyStore,
    NetworkEndpoint, PeerTrustRecord, QuarantineReason, QuinnTransportConfig, RecoveryOutcome,
    RecoveryReason, SecureKeyStore, TrustState, ValidationMetadata, adapters::SqliteControlStore,
};
use automerge_repo::{BootstrapRecord, DocumentId, RepoConfig, storage::ControlStore};

async fn identity(seed: u8) -> DeviceIdentity {
    DeviceIdentity::load_or_create(&InMemorySecureKeyStore::seeded([seed; 32]))
        .await
        .unwrap()
}
fn seed_trust(directory: &Path, peer: &DeviceIdentity) {
    std::fs::create_dir_all(directory).unwrap();
    SqliteControlStore::open(directory.join("control.sqlite"))
        .unwrap()
        .upsert_peer_trust(&PeerTrustRecord {
            device_id: peer.id(),
            public_key: peer.public_key(),
            state: TrustState::Trusted,
            updated_at_ms: 1,
            last_seen_ms: None,
        })
        .unwrap();
}
fn config(no_peer_after: Duration) -> AppCoreConfig {
    AppCoreConfig {
        repo: RepoConfig {
            recovery_no_peer_after: no_peer_after,
            ..RepoConfig::default()
        },
        ..AppCoreConfig::default()
    }
}
async fn open(directory: &Path, seed: u8) -> AppCore {
    open_with(directory, seed, config(Duration::from_secs(30)))
        .await
        .unwrap()
}
async fn open_with(directory: &Path, seed: u8, config: AppCoreConfig) -> app_core::Result<AppCore> {
    AppCore::open_networked(
        directory,
        Arc::new(InMemorySecureKeyStore::seeded([seed; 32])) as Arc<dyn SecureKeyStore>,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        config,
        QuinnTransportConfig::default(),
    )
    .await
}
fn endpoint(address: SocketAddr) -> NetworkEndpoint {
    NetworkEndpoint {
        address,
        source: EndpointSource::Lan,
        observed_at_ms: 1,
        expires_at_ms: u64::MAX,
        interface_scope: None,
        last_success_ms: None,
        failures: 0,
        retry_after_ms: None,
    }
}
async fn connect(a: &AppCore, b: &AppCore) {
    let peer = b.device_id().unwrap();
    a.replace_endpoints(
        peer,
        EndpointSource::Lan,
        [endpoint(b.network_addr().unwrap())],
    );
    a.connect_peer(peer, 1).await.unwrap();
}
async fn wait_ready(app: &AppCore) {
    let mut state = app.subscribe_lifecycle();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if matches!(*state.borrow(), ApplicationState::Ready { .. }) {
                return;
            }
            state.changed().await.unwrap();
        }
    })
    .await
    .expect("application became Ready");
}
async fn wait_recovery_outcome(app: &AppCore, expected: RecoveryOutcome) {
    let mut recovery = app.subscribe_recovery();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if recovery
                .borrow_and_update()
                .as_ref()
                .is_some_and(|record| record.outcome == expected)
            {
                return;
            }
            recovery.changed().await.unwrap();
        }
    })
    .await
    .unwrap_or_else(|_| panic!("recovery outcome {expected:?}"));
}
async fn wait_converged(a: &AppCore, b: &AppCore, collection: app_core::CollectionSchemaId) {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let same_schema = a.collection_schema(collection).ok().flatten()
                == b.collection_schema(collection).ok().flatten();
            let same_records = a.records(collection).ok() == b.records(collection).ok();
            if same_schema
                && same_records
                && a.records(collection).is_ok_and(|rows| !rows.is_empty())
            {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("devices converged");
}
fn field(name: &str, order: i64) -> FieldDefinition {
    FieldDefinition {
        id: FieldId::new(),
        name: name.into(),
        field_type: FieldType::Text,
        required: false,
        default: None,
        validation: ValidationMetadata::default(),
        display: DisplayMetadata::default(),
        order,
        deleted: false,
        enum_options: vec![],
    }
}
fn root_path(directory: &Path, root: DocumentId) -> std::path::PathBuf {
    directory.join(format!("automerge/documents/{root}.automerge"))
}
fn quarantine_files(directory: &Path) -> Vec<String> {
    let mut names: Vec<String> = match std::fs::read_dir(directory.join("quarantine")) {
        Ok(entries) => entries
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect(),
        Err(_) => Vec::new(),
    };
    names.sort();
    names
}

struct Pair {
    _a_dir: tempfile::TempDir,
    b_dir: tempfile::TempDir,
    a: AppCore,
    root: DocumentId,
    collection: app_core::CollectionSchemaId,
    summary: FieldDefinition,
}

/// Two trusted devices synchronized on `a`'s dataset; `b` is shut down with
/// its complete authoritative state on disk.
async fn paired_and_stopped() -> Pair {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let a_identity = identity(20).await;
    let b_identity = identity(21).await;
    seed_trust(a_dir.path(), &b_identity);
    seed_trust(b_dir.path(), &a_identity);
    let a = open(a_dir.path(), 20).await;
    let b = open(b_dir.path(), 21).await;
    let root = a.create_new_dataset().await.unwrap();
    let collection = a
        .create_collection("Notes".into(), String::new())
        .await
        .unwrap();
    let summary = field("Summary", 0);
    a.add_field(collection, summary.clone()).await.unwrap();
    a.create_record(
        collection,
        BTreeMap::from([(summary.id, FieldValue::Text("initial".into()))]),
    )
    .await
    .unwrap();
    connect(&a, &b).await;
    b.join_existing(root).await.unwrap();
    wait_ready(&b).await;
    wait_converged(&a, &b, collection).await;
    a.disconnect_peer(b.device_id().unwrap()).await.unwrap();
    b.shutdown().await.unwrap();
    assert!(root_path(b_dir.path(), root).exists());
    Pair {
        _a_dir: a_dir,
        b_dir,
        a,
        root,
        collection,
        summary,
    }
}

async fn assert_recovers_over_quinn(pair: &Pair, b: AppCore, expected_reason: RecoveryReason) {
    let Pair {
        a,
        root,
        collection,
        summary,
        ..
    } = pair;
    let root = *root;
    assert_eq!(b.lifecycle_state(), ApplicationState::Joining { root });
    let recovery = b.recovery_state().expect("recovery is observable");
    assert_eq!(recovery.reason, expected_reason);
    assert_eq!(recovery.documents, vec![root]);
    assert_eq!(recovery.outcome, RecoveryOutcome::Recovering);
    // Authoritative writes stay gated with a typed error and commit nothing.
    assert!(matches!(
        b.create_collection("Blocked".into(), String::new()).await,
        Err(app_core::AppError::Bootstrap(BootstrapError::Joining))
    ));
    assert!(b.collections().is_err());
    let mut a_errors = a.subscribe_errors();

    connect(a, &b).await;
    wait_ready(&b).await;
    assert_eq!(b.lifecycle_state(), ApplicationState::Ready { root });
    wait_recovery_outcome(&b, RecoveryOutcome::Recovered).await;
    wait_converged(a, &b, *collection).await;
    assert_eq!(b.records(*collection).unwrap().len(), 1);
    while let Ok(event) = a_errors.try_recv() {
        assert!(
            !event.message.contains("incompatible root"),
            "{}",
            event.message
        );
    }
    // Commands resume on the recovered device and flow back to the peer.
    let record = b
        .create_record(
            *collection,
            BTreeMap::from([(summary.id, FieldValue::Text("after recovery".into()))]),
        )
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while a.record(record).ok().flatten().is_none() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("peer received the post-recovery record");
    b.shutdown().await.unwrap();
    let reopened = open(pair.b_dir.path(), 21).await;
    assert_eq!(reopened.lifecycle_state(), ApplicationState::Ready { root });
    assert_eq!(reopened.recovery_state(), None);
    assert_eq!(reopened.records(*collection).unwrap().len(), 2);
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn root_snapshot_loss_recovers_the_identical_root_from_a_trusted_peer() {
    let pair = paired_and_stopped().await;
    std::fs::remove_file(root_path(pair.b_dir.path(), pair.root)).unwrap();
    let b = open(pair.b_dir.path(), 21).await;
    assert!(quarantine_files(pair.b_dir.path()).is_empty());
    assert_recovers_over_quinn(&pair, b, RecoveryReason::RootSnapshotMissing).await;
    pair.a.shutdown().await.unwrap();
}

#[tokio::test]
async fn corrupt_root_snapshot_is_quarantined_and_recovered_for_the_same_root() {
    let pair = paired_and_stopped().await;
    std::fs::write(
        root_path(pair.b_dir.path(), pair.root),
        b"not an automerge document",
    )
    .unwrap();
    let b = open(pair.b_dir.path(), 21).await;
    let quarantined = quarantine_files(pair.b_dir.path());
    assert_eq!(
        quarantined,
        vec![format!(
            "{}.{}.automerge",
            pair.root,
            QuarantineReason::CorruptRoot
        )]
    );
    let recovery = b.recovery_state().unwrap();
    assert_eq!(recovery.quarantine.len(), 1);
    assert!(recovery.quarantine[0].starts_with(pair.b_dir.path().join("quarantine")));
    assert!(!root_path(pair.b_dir.path(), pair.root).exists());
    assert_recovers_over_quinn(&pair, b, RecoveryReason::RootSnapshotCorrupt).await;
    // Quarantined bytes are still there after recovery.
    assert_eq!(quarantine_files(pair.b_dir.path()), quarantined);
    pair.a.shutdown().await.unwrap();
}

#[tokio::test]
async fn sole_device_reports_no_peer_and_a_later_peer_completes_recovery() {
    // A single local device: no peer can ever supply the root.
    let dir = tempfile::tempdir().unwrap();
    let local = config(Duration::from_millis(50));
    let core = AppCore::open_with_config(dir.path(), local.clone())
        .await
        .unwrap();
    let root = core.create_new_dataset().await.unwrap();
    core.shutdown().await.unwrap();
    std::fs::remove_file(root_path(dir.path(), root)).unwrap();
    let core = AppCore::open_with_config(dir.path(), local).await.unwrap();
    assert_eq!(core.lifecycle_state(), ApplicationState::Joining { root });
    wait_recovery_outcome(&core, RecoveryOutcome::NoPeerAvailable).await;
    assert_eq!(core.lifecycle_state(), ApplicationState::Joining { root });
    assert!(matches!(
        core.create_new_dataset().await,
        Err(app_core::AppError::Bootstrap(
            BootstrapError::DecisionAlreadyMade
        ))
    ));
    core.shutdown().await.unwrap();
    let control = SqliteControlStore::open(dir.path().join("control.sqlite")).unwrap();
    assert_eq!(
        ControlStore::load(&control).await.unwrap(),
        Some(BootstrapRecord::Joining { root })
    );
    drop(control);

    // A trusted device whose peer is offline at first, then reachable.
    let pair = paired_and_stopped().await;
    std::fs::remove_file(root_path(pair.b_dir.path(), pair.root)).unwrap();
    let b = open_with(pair.b_dir.path(), 21, config(Duration::from_millis(50)))
        .await
        .unwrap();
    wait_recovery_outcome(&b, RecoveryOutcome::NoPeerAvailable).await;
    assert_eq!(
        b.lifecycle_state(),
        ApplicationState::Joining { root: pair.root }
    );
    connect(&pair.a, &b).await;
    wait_ready(&b).await;
    assert_eq!(
        b.lifecycle_state(),
        ApplicationState::Ready { root: pair.root }
    );
    wait_recovery_outcome(&b, RecoveryOutcome::Recovered).await;
    wait_converged(&pair.a, &b, pair.collection).await;
    b.shutdown().await.unwrap();
    pair.a.shutdown().await.unwrap();
}

#[tokio::test]
async fn orphaned_documents_are_quarantined_and_adopted_when_the_same_root_is_rejoined() {
    let pair = paired_and_stopped().await;
    let original = std::fs::read(root_path(pair.b_dir.path(), pair.root)).unwrap();
    // Lose only the bootstrap row; trust and identity remain.
    let connection = rusqlite::Connection::open(pair.b_dir.path().join("control.sqlite")).unwrap();
    connection.execute("DELETE FROM app_control", []).unwrap();
    drop(connection);

    let b = open(pair.b_dir.path(), 21).await;
    assert_eq!(b.lifecycle_state(), ApplicationState::NeedsDecision);
    let quarantined = quarantine_files(pair.b_dir.path());
    assert_eq!(
        quarantined,
        vec![format!(
            "{}.{}.automerge",
            pair.root,
            QuarantineReason::Orphaned
        )]
    );
    assert_eq!(
        std::fs::read(pair.b_dir.path().join("quarantine").join(&quarantined[0])).unwrap(),
        original
    );
    assert!(!root_path(pair.b_dir.path(), pair.root).exists());
    let recovery = b.recovery_state().unwrap();
    assert_eq!(recovery.reason, RecoveryReason::OrphanedDocuments);
    assert_eq!(recovery.outcome, RecoveryOutcome::Quarantined);
    assert_eq!(recovery.documents, vec![pair.root]);

    // Rejoining the matching root adopts the quarantined history offline.
    b.join_existing(pair.root).await.unwrap();
    wait_ready(&b).await;
    assert_eq!(
        b.lifecycle_state(),
        ApplicationState::Ready { root: pair.root }
    );
    assert_eq!(
        b.recovery_state().unwrap().outcome,
        RecoveryOutcome::Adopted
    );
    assert!(quarantine_files(pair.b_dir.path()).is_empty());
    assert!(root_path(pair.b_dir.path(), pair.root).exists());
    assert_eq!(b.records(pair.collection).unwrap().len(), 1);

    // Its history merges with the group rather than replacing it.
    let local = b
        .create_record(
            pair.collection,
            BTreeMap::from([(pair.summary.id, FieldValue::Text("from b".into()))]),
        )
        .await
        .unwrap();
    let remote = pair
        .a
        .create_record(
            pair.collection,
            BTreeMap::from([(pair.summary.id, FieldValue::Text("from a".into()))]),
        )
        .await
        .unwrap();
    connect(&pair.a, &b).await;
    wait_converged(&pair.a, &b, pair.collection).await;
    assert_eq!(b.records(pair.collection).unwrap().len(), 3);
    assert!(pair.a.record(local).unwrap().is_some());
    assert!(b.record(remote).unwrap().is_some());
    b.shutdown().await.unwrap();
    pair.a.shutdown().await.unwrap();
}

#[tokio::test]
async fn unreadable_control_store_fails_visibly_but_quarantines_documents() {
    let dir = tempfile::tempdir().unwrap();
    let core = AppCore::open(dir.path()).await.unwrap();
    let root = core.create_new_dataset().await.unwrap();
    core.shutdown().await.unwrap();
    let original = std::fs::read(root_path(dir.path(), root)).unwrap();
    std::fs::write(dir.path().join("control.sqlite"), b"this is not a database").unwrap();
    for name in ["control.sqlite-wal", "control.sqlite-shm"] {
        let _ = std::fs::remove_file(dir.path().join(name));
    }
    let error = AppCore::open(dir.path()).await.unwrap_err();
    assert!(!error.is_reset_resolvable(), "{error}");
    let quarantined = quarantine_files(dir.path());
    assert_eq!(
        quarantined,
        vec![format!(
            "{root}.{}.automerge",
            QuarantineReason::ControlStoreUnreadable
        )]
    );
    assert_eq!(
        std::fs::read(dir.path().join("quarantine").join(&quarantined[0])).unwrap(),
        original
    );
    assert!(!root_path(dir.path(), root).exists());
}

#[tokio::test]
async fn conflicting_documents_under_creating_or_joining_stay_fatal_without_mutation() {
    for joining in [false, true] {
        let dir = tempfile::tempdir().unwrap();
        let core = AppCore::open(dir.path()).await.unwrap();
        let root = core.create_new_dataset().await.unwrap();
        core.shutdown().await.unwrap();
        let bytes = std::fs::read(root_path(dir.path(), root)).unwrap();
        let foreign = DocumentId::new();
        std::fs::write(root_path(dir.path(), foreign), &bytes).unwrap();
        let record = if joining {
            BootstrapRecord::Joining { root }
        } else {
            BootstrapRecord::Creating { root }
        };
        let control = SqliteControlStore::open(dir.path().join("control.sqlite")).unwrap();
        ControlStore::store(&control, record.clone()).await.unwrap();
        drop(control);
        let mut before: Vec<_> = std::fs::read_dir(dir.path().join("automerge/documents"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        before.sort();

        let error = AppCore::open(dir.path()).await.unwrap_err();
        assert!(
            matches!(
                error,
                app_core::AppError::RepositoryBootstrap(
                    automerge_repo::error::BootstrapError::Inconsistent { root: named, .. }
                ) if named == root
            ),
            "{error}"
        );
        let mut after: Vec<_> = std::fs::read_dir(dir.path().join("automerge/documents"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        after.sort();
        assert_eq!(before, after);
        assert!(quarantine_files(dir.path()).is_empty());
        let control = SqliteControlStore::open(dir.path().join("control.sqlite")).unwrap();
        assert_eq!(ControlStore::load(&control).await.unwrap(), Some(record));
    }
}
