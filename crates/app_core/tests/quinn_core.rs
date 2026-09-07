use std::{net::SocketAddr, path::Path, sync::Arc, time::Duration};

use app_core::{
    AppCore, AppCoreConfig, ApplicationState, CreateTransaction, DeviceIdentity, EndpointSource,
    InMemorySecureKeyStore, NetworkEndpoint, PeerTrustRecord, QuinnTransportConfig, SecureKeyStore,
    TransactionFilter, TrustState, adapters::SqliteControlStore,
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
