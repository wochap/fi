//! A locked desktop keyring must not stop the application from opening, and the
//! locked condition must stay recoverable without a restart.

use std::sync::Arc;

use app_core::{
    AppCore, AppCoreConfig, FakeDiscoveryProvider, LockableSecureKeyStore, ManualClock,
    NetworkingDeferredReason, QuinnTransportConfig,
};

async fn open_with(store: Arc<LockableSecureKeyStore>, dir: &std::path::Path) -> AppCore {
    AppCore::open_networked_with_discovery(
        dir,
        store,
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .expect("a locked store must not fail the open")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_locked_discovery_secret_defers_networking_and_retry_resumes_it() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(LockableSecureKeyStore::locked([31; 32], false));
    let core = open_with(store.clone(), dir.path()).await;

    assert_eq!(
        core.networking_deferred(),
        Some(NetworkingDeferredReason::SecureStoreLocked)
    );
    assert!(!core.networking_requires_reopen());
    // The device key was readable, so the networked core exists; only discovery
    // is waiting. Local work is unaffected.
    assert!(core.device_id().is_some());
    core.create_new_dataset().await.unwrap();
    core.create_collection("Food".into(), String::new())
        .await
        .unwrap();

    store.unlock();
    assert!(core.retry_networking().await.unwrap());
    assert_eq!(core.networking_deferred(), None);
    // Idempotent: a second retry neither restarts discovery nor fails.
    assert!(core.retry_networking().await.unwrap());
    assert_eq!(core.networking_deferred(), None);

    core.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_locked_device_key_opens_locally_and_reports_the_locked_reason() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(LockableSecureKeyStore::locked([32; 32], true));
    let core = open_with(store.clone(), dir.path()).await;

    assert_eq!(
        core.networking_deferred(),
        Some(NetworkingDeferredReason::SecureStoreLocked)
    );
    // No device key means no QUIC endpoint at all, so the retry has to reopen.
    assert!(core.networking_requires_reopen());
    assert!(core.device_id().is_none());
    core.create_new_dataset().await.unwrap();

    let error = core.retry_networking().await.unwrap_err();
    assert!(error.is_secure_store_locked());

    core.shutdown().await.unwrap();
}
