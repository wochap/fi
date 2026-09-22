//! Deliberate dataset reset: identity-preserving, root-scoped, and crash-safe
//! by write-ahead intent. Every interruption point must reopen cleanly, and
//! the errors reset can fix must be classified as such.

use std::{
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use app_core::{
    APP_SCHEMA_VERSION, AppCore, AppCoreConfig, ApplicationState, DiscoveryGroupSecret,
    FakeDiscoveryProvider, InMemorySecureKeyStore, ManualClock, PairingCandidate, PairingState,
    PrivateDeviceKey, QuinnTransportConfig, ResetIntent, SecureKeyStore, SecureStoreError,
    adapters::SqliteControlStore, reset_dataset,
};
use async_trait::async_trait;
use automerge::{Automerge, ROOT, ReadDoc, transaction::Transactable};
use automerge_repo::storage::ControlStore;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
        .try_into()
        .unwrap()
}

/// In-memory keystore whose secret removal can be made to report a locked
/// keyring, standing in for a desktop session whose Secret Service prompts.
struct LockableKeyStore {
    inner: InMemorySecureKeyStore,
    locked: AtomicBool,
}

impl LockableKeyStore {
    fn new(seed: [u8; 32]) -> Self {
        Self {
            inner: InMemorySecureKeyStore::seeded(seed),
            locked: AtomicBool::new(false),
        }
    }
    fn check(&self) -> Result<(), SecureStoreError> {
        if self.locked.load(Ordering::SeqCst) {
            Err(SecureStoreError::Locked)
        } else {
            Ok(())
        }
    }
}

#[async_trait]
impl SecureKeyStore for LockableKeyStore {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError> {
        self.check()?;
        self.inner.load_or_create_device_key().await
    }
    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError> {
        self.check()?;
        self.inner.load_discovery_group_secret().await
    }
    async fn store_discovery_group_secret(
        &self,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        self.check()?;
        self.inner.store_discovery_group_secret(secret).await
    }
    async fn remove_discovery_group_secret(&self) -> Result<(), SecureStoreError> {
        self.check()?;
        self.inner.remove_discovery_group_secret().await
    }
    async fn load_previous_discovery_group_secret(
        &self,
    ) -> Result<Option<(u64, DiscoveryGroupSecret)>, SecureStoreError> {
        self.check()?;
        self.inner.load_previous_discovery_group_secret().await
    }
    async fn store_previous_discovery_group_secret(
        &self,
        epoch: u64,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        self.check()?;
        self.inner
            .store_previous_discovery_group_secret(epoch, secret)
            .await
    }
    async fn remove_previous_discovery_group_secret(&self) -> Result<(), SecureStoreError> {
        self.check()?;
        self.inner.remove_previous_discovery_group_secret().await
    }
}

async fn open_networked(dir: &Path, keys: Arc<dyn SecureKeyStore>) -> app_core::Result<AppCore> {
    AppCore::open_networked_with_discovery(
        dir,
        keys,
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
}

async fn pair(existing: &AppCore, joining: &AppCore) {
    let window = 20_000;
    existing.start_pairing(window).await.unwrap();
    let joining_instance = joining.start_pairing(window).await.unwrap();
    let candidate = PairingCandidate {
        instance_id: joining_instance,
        endpoint: joining.pairing_addr().unwrap(),
        expires_at_ms: now_ms() + window,
    };
    let existing_session = existing
        .connect_pairing_candidate(candidate, window)
        .await
        .unwrap();
    let mut joining_state = joining.subscribe_pairing().unwrap();
    let joining_session = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let PairingState::AwaitingConfirmation { session_id, .. } =
                joining_state.borrow().clone()
            {
                break session_id;
            }
            joining_state.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    let (existing_result, joining_result) = tokio::join!(
        existing.confirm_pairing(existing_session),
        joining.confirm_pairing(joining_session),
    );
    existing_result.unwrap();
    joining_result.unwrap();
}

fn documents_dir(dir: &Path) -> std::path::PathBuf {
    dir.join("automerge/documents")
}

fn control(dir: &Path) -> SqliteControlStore {
    SqliteControlStore::open(dir.join("control.sqlite")).unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn reset_from_ready_keeps_identity_and_drops_root_scoped_state() {
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    let keys_a: Arc<dyn SecureKeyStore> = Arc::new(InMemorySecureKeyStore::seeded([41; 32]));
    let keys_b: Arc<dyn SecureKeyStore> = Arc::new(InMemorySecureKeyStore::seeded([42; 32]));
    let a = open_networked(dir_a.path(), keys_a.clone()).await.unwrap();
    let b = open_networked(dir_b.path(), keys_b.clone()).await.unwrap();
    a.create_new_dataset().await.unwrap();
    pair(&a, &b).await;
    let device_a = a.device_id().unwrap();
    let device_b = b.device_id().unwrap();
    assert_eq!(a.trusted_devices().unwrap().len(), 1);
    assert!(
        keys_a
            .load_discovery_group_secret()
            .await
            .unwrap()
            .is_some()
    );
    assert!(documents_dir(dir_a.path()).exists());
    assert!(dir_a.path().join("read-model.sqlite").exists());
    a.shutdown().await.unwrap();

    reset_dataset(dir_a.path(), Some(keys_a.as_ref()))
        .await
        .unwrap();

    assert!(
        keys_a
            .load_discovery_group_secret()
            .await
            .unwrap()
            .is_none()
    );
    assert!(!documents_dir(dir_a.path()).exists());
    assert!(!dir_a.path().join("read-model.sqlite").exists());
    assert_eq!(control(dir_a.path()).load_reset_intent().unwrap(), None);

    let reopened = open_networked(dir_a.path(), keys_a.clone()).await.unwrap();
    assert_eq!(reopened.lifecycle_state(), ApplicationState::NeedsDecision);
    assert_eq!(reopened.device_id(), Some(device_a));
    assert!(reopened.trusted_devices().unwrap().is_empty());
    assert!(
        keys_a
            .load_discovery_group_secret()
            .await
            .unwrap()
            .is_none()
    );

    // Peers are not told: B still records A.
    let record_b = b.trusted_devices().unwrap();
    assert_eq!(record_b.len(), 1);
    assert_eq!(record_b[0].device_id, device_a);
    assert_ne!(device_a, device_b);
    reopened.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

/// Which destructive steps completed before the simulated crash.
#[derive(Clone, Copy, Debug)]
#[allow(clippy::enum_variant_names)]
enum Interrupted {
    AfterIntent,
    AfterSecrets,
    AfterSnapshots,
    AfterReadModel,
}

async fn ready_dataset(dir: &Path, keys: Arc<dyn SecureKeyStore>) {
    let core = open_networked(dir, keys.clone()).await.unwrap();
    core.create_new_dataset().await.unwrap();
    keys.store_discovery_group_secret(&DiscoveryGroupSecret::from_bytes([3; 32]))
        .await
        .unwrap();
    core.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn interrupted_reset_resumes_on_next_open_at_every_stage() {
    for stage in [
        Interrupted::AfterIntent,
        Interrupted::AfterSecrets,
        Interrupted::AfterSnapshots,
        Interrupted::AfterReadModel,
    ] {
        let dir = tempfile::tempdir().unwrap();
        let keys: Arc<dyn SecureKeyStore> = Arc::new(InMemorySecureKeyStore::seeded([50; 32]));
        ready_dataset(dir.path(), keys.clone()).await;
        let device = control(dir.path())
            .load_local_identity()
            .unwrap()
            .unwrap()
            .device_id;

        // Replay D3 up to the interruption point by hand.
        control(dir.path())
            .store_reset_intent(ResetIntent {
                requested_at_ms: now_ms(),
            })
            .unwrap();
        let progress = stage as u8;
        if progress >= Interrupted::AfterSecrets as u8 {
            keys.remove_discovery_group_secret().await.unwrap();
        }
        if progress >= Interrupted::AfterSnapshots as u8 {
            std::fs::remove_dir_all(documents_dir(dir.path())).unwrap();
        }
        if progress >= Interrupted::AfterReadModel as u8 {
            std::fs::remove_file(dir.path().join("read-model.sqlite")).unwrap();
        }

        let reopened = open_networked(dir.path(), keys.clone())
            .await
            .unwrap_or_else(|error| panic!("{stage:?}: open failed: {error}"));
        assert_eq!(
            reopened.lifecycle_state(),
            ApplicationState::NeedsDecision,
            "{stage:?}"
        );
        assert_eq!(reopened.device_id(), Some(device), "{stage:?}");
        assert!(
            keys.load_discovery_group_secret().await.unwrap().is_none(),
            "{stage:?}"
        );
        assert_eq!(
            control(dir.path()).load_reset_intent().unwrap(),
            None,
            "{stage:?}"
        );
        reopened.shutdown().await.unwrap();

        // The local opener honors the marker too.
        control(dir.path())
            .store_reset_intent(ResetIntent {
                requested_at_ms: now_ms(),
            })
            .unwrap();
        let local = AppCore::open(dir.path()).await.unwrap();
        assert_eq!(local.lifecycle_state(), ApplicationState::NeedsDecision);
        assert_eq!(control(dir.path()).load_reset_intent().unwrap(), None);
        local.shutdown().await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn locked_keystore_aborts_with_intent_set_and_completes_once_unlocked() {
    let dir = tempfile::tempdir().unwrap();
    let keys = Arc::new(LockableKeyStore::new([60; 32]));
    ready_dataset(dir.path(), keys.clone()).await;

    keys.locked.store(true, Ordering::SeqCst);
    let error = reset_dataset(dir.path(), Some(keys.as_ref() as &dyn SecureKeyStore))
        .await
        .unwrap_err();
    assert!(
        matches!(
            error,
            app_core::AppError::Identity(app_core::IdentityError::SecureStore(
                SecureStoreError::Locked
            ))
        ),
        "{error}"
    );
    assert!(!error.is_reset_resolvable());
    assert!(control(dir.path()).load_reset_intent().unwrap().is_some());
    assert!(documents_dir(dir.path()).exists());
    assert!(dir.path().join("read-model.sqlite").exists());
    assert!(control(dir.path()).load_local_identity().unwrap().is_some());

    // Still locked: open re-attempts the reset, fails the same way, touches nothing.
    let error = open_networked(dir.path(), keys.clone()).await.unwrap_err();
    assert!(!error.is_reset_resolvable());
    assert!(control(dir.path()).load_reset_intent().unwrap().is_some());
    assert!(documents_dir(dir.path()).exists());

    keys.locked.store(false, Ordering::SeqCst);
    let reopened = open_networked(dir.path(), keys.clone()).await.unwrap();
    assert_eq!(reopened.lifecycle_state(), ApplicationState::NeedsDecision);
    assert_eq!(control(dir.path()).load_reset_intent().unwrap(), None);
    assert!(keys.load_discovery_group_secret().await.unwrap().is_none());
    // The opener recreates the (empty) snapshot directory.
    assert_eq!(
        std::fs::read_dir(documents_dir(dir.path()))
            .unwrap()
            .count(),
        0
    );
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn schema_cliff_is_reset_resolvable_and_reset_lands_in_needs_decision() {
    let dir = tempfile::tempdir().unwrap();
    let core = AppCore::open(dir.path()).await.unwrap();
    let root = core.create_new_dataset().await.unwrap();
    core.shutdown().await.unwrap();

    // Rewrite the root snapshot with a schema version this binary cannot decode.
    let path = documents_dir(dir.path()).join(format!("{root}.automerge"));
    let mut document = Automerge::load(&std::fs::read(&path).unwrap()).unwrap();
    let (_, app) = document.get(ROOT, "application").unwrap().unwrap();
    document
        .transact::<_, _, automerge::AutomergeError>(|tx| {
            tx.put(&app, "schema_version", APP_SCHEMA_VERSION + 1)?;
            Ok(())
        })
        .unwrap();
    std::fs::write(&path, document.save()).unwrap();

    let error = AppCore::open(dir.path()).await.unwrap_err();
    assert!(error.is_reset_resolvable(), "{error}");

    reset_dataset(dir.path(), None).await.unwrap();
    let reopened = AppCore::open(dir.path()).await.unwrap();
    assert_eq!(reopened.lifecycle_state(), ApplicationState::NeedsDecision);
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn inconsistent_and_exhausted_stores_are_reset_resolvable_but_io_is_not() {
    // Ready record with its snapshot gone, no intent: recovered as Joining for
    // the same root rather than failing; reset still lands in NeedsDecision.
    let dir = tempfile::tempdir().unwrap();
    let core = AppCore::open(dir.path()).await.unwrap();
    let root = core.create_new_dataset().await.unwrap();
    core.shutdown().await.unwrap();
    std::fs::remove_dir_all(documents_dir(dir.path())).unwrap();
    let recovering = AppCore::open(dir.path()).await.unwrap();
    assert_eq!(
        recovering.lifecycle_state(),
        ApplicationState::Joining { root }
    );
    recovering.shutdown().await.unwrap();
    reset_dataset(dir.path(), None).await.unwrap();
    assert_eq!(
        AppCore::open(dir.path()).await.unwrap().lifecycle_state(),
        ApplicationState::NeedsDecision
    );

    // Genuinely inconsistent: a Creating record with a foreign document.
    let dir = tempfile::tempdir().unwrap();
    let core = AppCore::open(dir.path()).await.unwrap();
    let root = core.create_new_dataset().await.unwrap();
    core.shutdown().await.unwrap();
    let path = documents_dir(dir.path()).join(format!("{root}.automerge"));
    let bytes = std::fs::read(&path).unwrap();
    std::fs::write(
        documents_dir(dir.path()).join(format!("{}.automerge", automerge_repo::DocumentId::new())),
        bytes,
    )
    .unwrap();
    ControlStore::store(
        &control(dir.path()),
        automerge_repo::BootstrapRecord::Creating { root },
    )
    .await
    .unwrap();
    let error = AppCore::open(dir.path()).await.unwrap_err();
    assert!(error.is_reset_resolvable(), "{error}");

    // Recovery exhausted for a root that keeps losing its snapshot.
    let dir = tempfile::tempdir().unwrap();
    let config = AppCoreConfig {
        repo: automerge_repo::RepoConfig {
            recovery_attempt_limit: 1,
            ..automerge_repo::RepoConfig::default()
        },
        ..AppCoreConfig::default()
    };
    let core = AppCore::open_with_config(dir.path(), config.clone())
        .await
        .unwrap();
    let root = core.create_new_dataset().await.unwrap();
    core.shutdown().await.unwrap();
    std::fs::remove_dir_all(documents_dir(dir.path())).unwrap();
    let recovering = AppCore::open_with_config(dir.path(), config.clone())
        .await
        .unwrap();
    recovering.shutdown().await.unwrap();
    ControlStore::store(
        &control(dir.path()),
        automerge_repo::BootstrapRecord::Ready { root },
    )
    .await
    .unwrap();
    let error = AppCore::open_with_config(dir.path(), config)
        .await
        .unwrap_err();
    assert!(error.is_reset_resolvable(), "{error}");
    reset_dataset(dir.path(), None).await.unwrap();
    assert_eq!(
        AppCore::open(dir.path()).await.unwrap().lifecycle_state(),
        ApplicationState::NeedsDecision
    );

    // Keystore unavailable: the open degrades to local-only rather than
    // failing, and the reason it reports is not reset-resolvable either.
    let dir = tempfile::tempdir().unwrap();
    let core = open_networked(
        dir.path(),
        Arc::new(app_core::UnavailableSecureKeyStore(
            SecureStoreError::Unavailable("no session bus".into()),
        )),
    )
    .await
    .unwrap();
    let deferred = core
        .networking_deferred()
        .expect("an unavailable store defers networking");
    assert!(matches!(
        deferred,
        app_core::NetworkingDeferredReason::SecureStoreUnavailable(_)
    ));
    let error = deferred.to_app_error();
    assert!(!error.is_reset_resolvable(), "{error}");
    core.shutdown().await.unwrap();
}
