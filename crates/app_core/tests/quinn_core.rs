use std::{
    net::SocketAddr,
    path::Path,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use app_core::{
    AppCore, AppCoreConfig, ApplicationState, CreateTransaction, DeviceIdentity,
    DiscoveryGroupMetadata, DiscoveryGroupSecret, EndpointSource, FakeDiscoveryProvider,
    InMemorySecureKeyStore, ManualClock, NetworkEndpoint, PeerTrustRecord, QuinnTransportConfig,
    SecureKeyStore, TransactionFilter, TrustState, TrustedDeviceRecord,
    adapters::SqliteControlStore,
};

async fn identity(seed: u8) -> DeviceIdentity {
    let store = InMemorySecureKeyStore::seeded([seed; 32]);
    DeviceIdentity::load_or_create(&store).await.unwrap()
}

fn seed_trust(directory: &Path, peer: &DeviceIdentity, state: TrustState) {
    std::fs::create_dir_all(directory).unwrap();
    let store = SqliteControlStore::open(directory.join("control.sqlite")).unwrap();
    store
        .upsert_peer_trust(&PeerTrustRecord {
            device_id: peer.id(),
            public_key: peer.public_key(),
            state,
            updated_at_ms: 1,
            last_seen_ms: None,
        })
        .unwrap();
}

async fn open(directory: &Path, seed: u8) -> AppCore {
    AppCore::open_networked(
        directory,
        Arc::new(InMemorySecureKeyStore::seeded([seed; 32])) as Arc<dyn SecureKeyStore>,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
    )
    .await
    .unwrap()
}

async fn open_store(directory: &Path, store: Arc<InMemorySecureKeyStore>) -> AppCore {
    AppCore::open_networked_with_discovery(
        directory,
        store,
        SocketAddr::from(([127, 0, 0, 1], 0)),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
    .unwrap()
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

async fn wait_ready(app: &AppCore) {
    let mut state = app.subscribe_lifecycle();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(*state.borrow(), ApplicationState::Ready { .. }) {
                return;
            }
            state.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}

async fn wait_transactions(app: &AppCore, count: usize) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if app
                .transactions(&TransactionFilter::default())
                .is_ok_and(|rows| rows.len() == count)
            {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}

async fn trusted_pair(
    seed_a: u8,
    seed_b: u8,
) -> (tempfile::TempDir, tempfile::TempDir, AppCore, AppCore) {
    let directory_a = tempfile::tempdir().unwrap();
    let directory_b = tempfile::tempdir().unwrap();
    let identity_a = identity(seed_a).await;
    let identity_b = identity(seed_b).await;
    seed_trust(directory_a.path(), &identity_b, TrustState::Trusted);
    seed_trust(directory_b.path(), &identity_a, TrustState::Trusted);
    let a = open(directory_a.path(), seed_a).await;
    let b = open(directory_b.path(), seed_b).await;
    (directory_a, directory_b, a, b)
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

#[tokio::test]
async fn two_manually_trusted_cores_sync_and_project_over_quinn() {
    let (_directory_a, _directory_b, a, b) = trusted_pair(10, 11).await;
    let root = a.create_new_dataset().await.unwrap();
    connect(&a, &b).await;
    b.join_existing(root).await.unwrap();
    wait_ready(&b).await;
    let category = a.categories().unwrap()[0].id;
    a.create_transaction(CreateTransaction {
        occurred_at_ms: 1,
        category_id: category,
        amount_minor: -50,
        description: "quinn loopback".into(),
    })
    .await
    .unwrap();
    wait_transactions(&b, 1).await;
    assert_eq!(b.aggregates().unwrap().balance_minor, -50);
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn concurrent_offline_transactions_converge_after_reconnection() {
    let (_directory_a, _directory_b, a, b) = trusted_pair(12, 13).await;
    let root = a.create_new_dataset().await.unwrap();
    connect(&a, &b).await;
    b.join_existing(root).await.unwrap();
    wait_ready(&b).await;
    let category = a.categories().unwrap()[0].id;
    a.disconnect_peer(b.device_id().unwrap()).await.unwrap();
    a.create_transaction(CreateTransaction {
        occurred_at_ms: 2,
        category_id: category,
        amount_minor: 100,
        description: "offline-a".into(),
    })
    .await
    .unwrap();
    b.create_transaction(CreateTransaction {
        occurred_at_ms: 3,
        category_id: category,
        amount_minor: 200,
        description: "offline-b".into(),
    })
    .await
    .unwrap();
    connect(&a, &b).await;
    wait_transactions(&a, 2).await;
    wait_transactions(&b, 2).await;
    assert_eq!(a.aggregates().unwrap().balance_minor, 300);
    assert_eq!(b.aggregates().unwrap().balance_minor, 300);
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test]
async fn trusted_device_reconnects_after_socket_address_change() {
    let (directory_a, directory_b, a, b) = trusted_pair(14, 15).await;
    let root = a.create_new_dataset().await.unwrap();
    connect(&a, &b).await;
    b.join_existing(root).await.unwrap();
    wait_ready(&b).await;
    let original_id = b.device_id().unwrap();
    let original_address = b.network_addr().unwrap();
    b.shutdown().await.unwrap();
    let replacement = open(directory_b.path(), 15).await;
    assert_eq!(replacement.device_id(), Some(original_id));
    assert_ne!(replacement.network_addr().unwrap(), original_address);
    connect(&a, &replacement).await;
    let category = a.categories().unwrap()[0].id;
    a.create_transaction(CreateTransaction {
        occurred_at_ms: 4,
        category_id: category,
        amount_minor: 7,
        description: "new route".into(),
    })
    .await
    .unwrap();
    wait_transactions(&replacement, 1).await;
    a.shutdown().await.unwrap();
    replacement.shutdown().await.unwrap();
    drop(directory_a);
}

#[tokio::test]
async fn unknown_and_revoked_peers_are_rejected_before_repo_sync() {
    for (seed, state) in [(16, None), (18, Some(TrustState::Revoked))] {
        let directory_a = tempfile::tempdir().unwrap();
        let directory_b = tempfile::tempdir().unwrap();
        let identity_a = identity(seed).await;
        let identity_b = identity(seed + 1).await;
        seed_trust(directory_a.path(), &identity_b, TrustState::Trusted);
        if let Some(state) = state {
            seed_trust(directory_b.path(), &identity_a, state);
        }
        let a = open(directory_a.path(), seed).await;
        let b = open(directory_b.path(), seed + 1).await;
        let peer = b.device_id().unwrap();
        a.replace_endpoints(
            peer,
            EndpointSource::Lan,
            [endpoint(b.network_addr().unwrap())],
        );
        assert!(a.connect_peer(peer, 1).await.is_err());
        assert!(a.subscribe_peer_sync().borrow().is_empty());
        assert!(b.subscribe_peer_sync().borrow().is_empty());
        a.shutdown().await.unwrap();
        b.shutdown().await.unwrap();
    }
}

#[tokio::test]
async fn complete_restart_preserves_data_identity_trust_revocation_and_epoch() {
    let directory_a = tempfile::tempdir().unwrap();
    let directory_b = tempfile::tempdir().unwrap();
    let store_a = Arc::new(InMemorySecureKeyStore::seeded([70; 32]));
    let store_b = Arc::new(InMemorySecureKeyStore::seeded([71; 32]));
    let identity_a = DeviceIdentity::load_or_create(store_a.as_ref())
        .await
        .unwrap();
    let identity_b = DeviceIdentity::load_or_create(store_b.as_ref())
        .await
        .unwrap();
    let revoked = identity(72).await;
    let secret = DiscoveryGroupSecret::from_bytes([73; 32]);
    store_a.store_discovery_group_secret(&secret).await.unwrap();
    store_b.store_discovery_group_secret(&secret).await.unwrap();

    for (directory, trusted, extra) in [
        (directory_a.path(), &identity_b, Some(&revoked)),
        (directory_b.path(), &identity_a, None),
    ] {
        let control = SqliteControlStore::open(directory.join("control.sqlite")).unwrap();
        for device in std::iter::once(trusted).chain(extra) {
            control
                .upsert_peer_trust(&PeerTrustRecord {
                    device_id: device.id(),
                    public_key: device.public_key(),
                    state: TrustState::Trusted,
                    updated_at_ms: 1,
                    last_seen_ms: Some(1),
                })
                .unwrap();
            control
                .upsert_trusted_device(&TrustedDeviceRecord {
                    device_id: device.id(),
                    public_key: device.public_key(),
                    friendly_name: format!("Device {}", &device.id().to_string()[..8]),
                    paired_at_ms: 1,
                    last_seen_ms: Some(1),
                    last_sync_ms: None,
                    state: TrustState::Trusted,
                })
                .unwrap();
        }
        control
            .store_discovery_metadata(DiscoveryGroupMetadata {
                epoch: 1,
                updated_at_ms: 1,
            })
            .unwrap();
    }

    let a = open_store(directory_a.path(), store_a.clone()).await;
    let b = open_store(directory_b.path(), store_b.clone()).await;
    let root = a.create_new_dataset().await.unwrap();
    connect(&a, &b).await;
    b.join_existing(root).await.unwrap();
    wait_ready(&b).await;
    let category = a.categories().unwrap()[0].id;
    a.create_transaction(CreateTransaction {
        occurred_at_ms: 8,
        category_id: category,
        amount_minor: 123,
        description: "restart acceptance".into(),
    })
    .await
    .unwrap();
    wait_transactions(&b, 1).await;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
        .try_into()
        .unwrap();
    a.revoke_trusted_device(revoked.id(), now).await.unwrap();
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();

    let reopened_a = open_store(directory_a.path(), store_a).await;
    let reopened_b = open_store(directory_b.path(), store_b).await;
    assert_eq!(reopened_a.device_id(), Some(identity_a.id()));
    assert_eq!(reopened_b.device_id(), Some(identity_b.id()));
    assert_eq!(
        reopened_a.lifecycle_state(),
        ApplicationState::Ready { root }
    );
    assert_eq!(
        reopened_a
            .transactions(&TransactionFilter::default())
            .unwrap()
            .len(),
        1
    );
    assert!(
        reopened_a.trusted_devices().unwrap().iter().any(|device| {
            device.device_id == revoked.id() && device.state == TrustState::Revoked
        })
    );
    for directory in [directory_a.path(), directory_b.path()] {
        assert_eq!(
            SqliteControlStore::open(directory.join("control.sqlite"))
                .unwrap()
                .discovery_metadata()
                .unwrap()
                .unwrap()
                .epoch,
            2
        );
    }
    reopened_a.shutdown().await.unwrap();
    reopened_b.shutdown().await.unwrap();
}
