use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use app_core::{
    AppCore, AppCoreConfig, CreateCategory, FakeDiscoveryProvider, InMemorySecureKeyStore,
    ManualClock, PairingCandidate, PairingState, QuinnTransportConfig,
};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
        .try_into()
        .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fresh_device_is_provisioned_and_synced_before_pairing_completes() {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let existing = AppCore::open_networked_with_discovery(
        existing_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([21; 32])),
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap();
    let joining = AppCore::open_networked_with_discovery(
        joining_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([22; 32])),
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap();

    let root = existing.create_new_dataset().await.unwrap();
    existing
        .create_category(CreateCategory {
            name: "Food".into(),
        })
        .await
        .unwrap();
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
    let existing_sas = match existing.pairing_state() {
        PairingState::AwaitingConfirmation { sas, .. } => sas,
        state => panic!("{state:?}"),
    };
    let joining_sas = match joining.pairing_state() {
        PairingState::AwaitingConfirmation { sas, .. } => sas,
        state => panic!("{state:?}"),
    };
    assert_eq!(existing_sas, joining_sas);

    let (existing_result, joining_result) = tokio::join!(
        existing.confirm_pairing(existing_session),
        joining.confirm_pairing(joining_session),
    );
    existing_result.unwrap();
    joining_result.unwrap();
    assert_eq!(
        joining.lifecycle_state(),
        app_core::ApplicationState::Ready { root }
    );
    assert!(matches!(
        joining.projection_state(),
        app_core::ProjectionState::Ready { .. }
    ));
    assert_eq!(joining.categories().unwrap()[0].name, "Food");
    assert_eq!(existing.trusted_devices().unwrap().len(), 1);
    assert_eq!(joining.trusted_devices().unwrap().len(), 1);
    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rejection_leaves_fresh_device_rootless_and_both_devices_untrusted() {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let existing = AppCore::open_networked_with_discovery(
        existing_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([51; 32])),
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap();
    let joining = AppCore::open_networked_with_discovery(
        joining_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([52; 32])),
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap();
    existing.create_new_dataset().await.unwrap();
    let window = 10_000;
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
    joining.reject_pairing(Some(joining_session)).await.unwrap();
    assert!(existing.confirm_pairing(existing_session).await.is_err());
    assert_eq!(
        joining.lifecycle_state(),
        app_core::ApplicationState::NeedsDecision
    );
    assert!(existing.trusted_devices().unwrap().is_empty());
    assert!(joining.trusted_devices().unwrap().is_empty());
    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}
