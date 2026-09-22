//! A commit-stage failure must fail the pairing session with its own reason,
//! immediately, and must never be reported as an expiry.

use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use app_core::{
    AppCore, AppCoreConfig, FakeDiscoveryProvider, InMemorySecureKeyStore, LockableSecureKeyStore,
    ManualClock, PairingCandidate, PairingError, PairingState, QuinnTransportConfig,
    SecureKeyStore,
};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
        .try_into()
        .unwrap()
}

async fn open(dir: &std::path::Path, store: Arc<dyn SecureKeyStore>) -> AppCore {
    AppCore::open_networked_with_discovery(
        dir,
        store,
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap()
}

async fn await_confirmation(core: &AppCore) -> app_core::PairingSessionId {
    let mut state = core.subscribe_pairing().unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let PairingState::AwaitingConfirmation { session_id, .. } = state.borrow().clone() {
                break session_id;
            }
            state.changed().await.unwrap();
        }
    })
    .await
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_locked_keystore_fails_the_commit_with_its_own_reason() {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let store = Arc::new(LockableSecureKeyStore::unlocked([61; 32], false));
    let existing = open(existing_dir.path(), store.clone()).await;
    let joining = open(
        joining_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([62; 32])),
    )
    .await;

    existing.create_new_dataset().await.unwrap();
    let window = 20_000;
    existing.start_pairing(window).await.unwrap();
    let joining_instance = joining.start_pairing(window).await.unwrap();
    let existing_session = existing
        .connect_pairing_candidate(
            PairingCandidate {
                instance_id: joining_instance,
                endpoint: joining.pairing_addr().unwrap(),
                expires_at_ms: now_ms() + window,
            },
            window,
        )
        .await
        .unwrap();
    let joining_session = await_confirmation(&joining).await;

    // The keyring locks between the SAS confirmation and the commit.
    store.lock();
    let (existing_result, _joining_result) = tokio::join!(
        existing.confirm_pairing(existing_session),
        joining.confirm_pairing(joining_session),
    );

    let error = existing_result.expect_err("a locked store must fail the commit");
    assert!(error.is_secure_store_locked(), "{error}");
    // Immediately, not by lapsing into the deadline.
    match existing.pairing_state() {
        PairingState::Failed { error } => {
            assert_eq!(error, PairingError::SecureStoreLocked);
            assert_ne!(error, PairingError::Expired);
        }
        state => panic!("expected a failed session, got {state:?}"),
    }
    // Trust is not rolled back on failure, and no half-written record appears.
    assert!(existing.trusted_devices().unwrap().is_empty());

    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_deadline_still_expires_a_stalled_session() {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let existing = open(
        existing_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([63; 32])),
    )
    .await;
    let joining = open(
        joining_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([64; 32])),
    )
    .await;

    existing.create_new_dataset().await.unwrap();
    let window = 4_000;
    existing.start_pairing(window).await.unwrap();
    let joining_instance = joining.start_pairing(window).await.unwrap();
    let existing_session = existing
        .connect_pairing_candidate(
            PairingCandidate {
                instance_id: joining_instance,
                endpoint: joining.pairing_addr().unwrap(),
                expires_at_ms: now_ms() + window,
            },
            window,
        )
        .await
        .unwrap();
    let _joining_session = await_confirmation(&joining).await;

    // Nobody confirms on the joining side, so the deadline is the only thing
    // that can end this session — and it still reports an expiry.
    let error = existing
        .confirm_pairing(existing_session)
        .await
        .expect_err("a stalled session expires");
    assert!(
        matches!(error, app_core::AppError::Pairing(PairingError::Expired)),
        "{error}"
    );

    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}
