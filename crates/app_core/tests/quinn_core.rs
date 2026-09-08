use std::{collections::BTreeMap, net::SocketAddr, path::Path, sync::Arc, time::Duration};

use app_core::{
    AppCore, AppCoreConfig, ApplicationState, DeviceIdentity, DisplayMetadata, EndpointSource,
    FieldDefinition, FieldId, FieldType, FieldValue, InMemorySecureKeyStore, NetworkEndpoint,
    PeerTrustRecord, QuinnTransportConfig, SecureKeyStore, TrustState, ValidationMetadata,
    adapters::SqliteControlStore,
};

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
async fn wait_collections(app: &AppCore, count: usize) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if app.collections().is_ok_and(|rows| rows.len() == count) {
                return;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
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
    .unwrap();
}

#[tokio::test]
async fn real_quinn_syncs_join_hydration_records_concurrent_fields_and_restart() {
    let a_dir = tempfile::tempdir().unwrap();
    let b_dir = tempfile::tempdir().unwrap();
    let a_identity = identity(10).await;
    let b_identity = identity(11).await;
    seed_trust(a_dir.path(), &b_identity);
    seed_trust(b_dir.path(), &a_identity);
    let a = open(a_dir.path(), 10).await;
    let b = open(b_dir.path(), 11).await;
    let root = a.create_new_dataset().await.unwrap();
    let collection = a
        .create_collection("Headaches".into(), String::new())
        .await
        .unwrap();
    let summary = field("Summary", 0);
    a.add_field(collection, summary.clone()).await.unwrap();
    let record = a
        .create_record(
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
    let left = field("Left note", 1);
    let right = field("Right note", 2);
    a.add_field(collection, left).await.unwrap();
    b.add_field(collection, right).await.unwrap();
    a.update_record_field(
        record,
        collection,
        summary.id,
        FieldValue::Text("left".into()),
    )
    .await
    .unwrap();
    b.update_record_field(
        record,
        collection,
        summary.id,
        FieldValue::Text("right".into()),
    )
    .await
    .unwrap();
    connect(&a, &b).await;
    wait_collections(&a, 1).await;
    wait_collections(&b, 1).await;
    wait_converged(&a, &b, collection).await;
    assert_eq!(
        a.collection_schema(collection)
            .unwrap()
            .unwrap()
            .fields
            .len(),
        3
    );
    assert!(matches!(
        a.record(record).unwrap().unwrap().record.values[&summary.id],
        FieldValue::Text(_)
    ));
    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();

    let reopened = open(a_dir.path(), 10).await;
    assert_eq!(reopened.collections().unwrap().len(), 1);
    assert_eq!(reopened.records(collection).unwrap().len(), 1);
    reopened.shutdown().await.unwrap();
}
