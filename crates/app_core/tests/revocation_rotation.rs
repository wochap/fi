//! Revocation must commit and report truthfully even when discovery-secret
//! rotation cannot retain the previous epoch, and rotation must complete on the
//! shipping desktop keystore path.

use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use app_core::{
    AppCore, AppCoreConfig, DiscoveryGroupSecret, FakeDiscoveryProvider, InMemorySecureKeyStore,
    LinuxSecretServiceKeyStore, ManualClock, PairingCandidate, PairingState, PeerConnectionState,
    PrivateDeviceKey, QuinnTransportConfig, SecureKeyStore, SecureStoreError, TrustState,
};
use async_trait::async_trait;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
        .try_into()
        .unwrap()
}

/// In-memory keystore whose previous-epoch retention can be switched off, so a
/// test can stand in for a desktop session whose Secret Service is unavailable.
struct RetentionSwitchKeyStore {
    inner: InMemorySecureKeyStore,
    retention_available: AtomicBool,
}

#[async_trait]
impl SecureKeyStore for RetentionSwitchKeyStore {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError> {
        self.inner.load_or_create_device_key().await
    }
    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError> {
        self.inner.load_discovery_group_secret().await
    }
    async fn store_discovery_group_secret(
        &self,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        self.inner.store_discovery_group_secret(secret).await
    }
    async fn load_previous_discovery_group_secret(
        &self,
    ) -> Result<Option<(u64, DiscoveryGroupSecret)>, SecureStoreError> {
        self.inner.load_previous_discovery_group_secret().await
    }
    async fn store_previous_discovery_group_secret(
        &self,
        epoch: u64,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        if !self.retention_available.load(Ordering::SeqCst) {
            return Err(SecureStoreError::Unavailable(
                "no Secret Service provider is available in this desktop session".into(),
            ));
        }
        self.inner
            .store_previous_discovery_group_secret(epoch, secret)
            .await
    }
    async fn remove_previous_discovery_group_secret(&self) -> Result<(), SecureStoreError> {
        self.inner.remove_previous_discovery_group_secret().await
    }
}

async fn open(dir: &std::path::Path, keys: Arc<dyn SecureKeyStore>) -> AppCore {
    AppCore::open_networked_with_discovery(
        dir,
        keys,
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap()
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn revocation_commits_and_reports_rotation_failure_separately() {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let keys = Arc::new(RetentionSwitchKeyStore {
        inner: InMemorySecureKeyStore::seeded([31; 32]),
        retention_available: AtomicBool::new(false),
    });
    let existing = open(existing_dir.path(), keys.clone()).await;
    let joining = open(
        joining_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([32; 32])),
    )
    .await;
    existing.create_new_dataset().await.unwrap();
    pair(&existing, &joining).await;
    let peer = joining.device_id().unwrap();
    let before = existing.discovery_secret_for_platform().await.unwrap();

    // Retention unavailable: revocation must still commit and say so.
    let outcome = existing
        .revoke_trusted_device(peer, now_ms())
        .await
        .unwrap();
    assert!(outcome.revoked);
    let rotation_error = outcome
        .rotation_error
        .expect("rotation failure is reported");
    assert!(
        rotation_error.contains("Secret Service"),
        "{rotation_error}"
    );
    let record = existing
        .trusted_devices()
        .unwrap()
        .into_iter()
        .find(|record| record.device_id == peer)
        .unwrap();
    assert_eq!(record.state, TrustState::Revoked);
    assert_eq!(
        existing.connection_states().get(&peer),
        Some(&PeerConnectionState::Disconnected)
    );
    assert_eq!(
        existing.discovery_secret_for_platform().await.unwrap(),
        before,
        "a failed rotation must not advance the secret"
    );
    assert!(
        keys.load_previous_discovery_group_secret()
            .await
            .unwrap()
            .is_none()
    );

    // A second revocation is a no-op on the record and does not rotate again.
    let repeat = existing
        .revoke_trusted_device(peer, now_ms())
        .await
        .unwrap();
    assert_eq!(
        repeat,
        app_core::RevocationOutcome {
            revoked: false,
            rotation_error: None
        }
    );

    // Retry once the keystore recovers: the epoch advances and the previous
    // secret is retained for the migration window.
    keys.retention_available.store(true, Ordering::SeqCst);
    let epoch = existing.rotate_discovery_secret(now_ms()).await.unwrap();
    assert!(epoch >= 1);
    let after = existing.discovery_secret_for_platform().await.unwrap();
    assert_ne!(after, before);
    let (retained_epoch, retained) = keys
        .load_previous_discovery_group_secret()
        .await
        .unwrap()
        .expect("previous secret is retained");
    assert_eq!(retained_epoch + 1, epoch);
    assert_eq!(Some(retained), before);

    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}

/// Round-trips previous-epoch retention through the real Secret Service.
/// Skips when the desktop session has no usable provider, since that is the
/// exact condition the retention path is required to report rather than hide.
#[tokio::test]
async fn linux_keystore_retains_and_removes_previous_epoch() {
    let store = LinuxSecretServiceKeyStore::new(format!("com.gean.fi.test.{}", std::process::id()));
    let probe = store.load_previous_discovery_group_secret().await;
    match probe {
        Ok(None) => {}
        Ok(Some(_)) => panic!("unexpected retained secret under a fresh application id"),
        Err(SecureStoreError::Unavailable(_) | SecureStoreError::Locked) => {
            eprintln!("skipping: Secret Service is unavailable in this session");
            return;
        }
        Err(error) => panic!("{error}"),
    }
    let first = DiscoveryGroupSecret::from_bytes([1; 32]);
    let second = DiscoveryGroupSecret::from_bytes([2; 32]);
    store
        .store_previous_discovery_group_secret(3, &first)
        .await
        .unwrap();
    assert_eq!(
        store.load_previous_discovery_group_secret().await.unwrap(),
        Some((3, first))
    );
    store
        .store_previous_discovery_group_secret(4, &second)
        .await
        .unwrap();
    assert_eq!(
        store.load_previous_discovery_group_secret().await.unwrap(),
        Some((4, second)),
        "a newer retention replaces the older epoch"
    );
    store
        .remove_previous_discovery_group_secret()
        .await
        .unwrap();
    assert_eq!(
        store.load_previous_discovery_group_secret().await.unwrap(),
        None
    );
}
