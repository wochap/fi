use std::{
    io,
    sync::{Arc, Mutex},
};

use app_core::{
    DiscoveryGroupSecret, DiscoverySecretUpdate, InMemorySecureKeyStore, PairingSessionId,
    PlatformSecretPersistence, PlatformSecretWrite, PrivateDeviceKey, ProvisioningEnvelope,
    SasCode, SecureKeyStore, SecureStoreError, WriteThroughSecureKeyStore,
    diagnostics::{DiagnosticInputs, RecentEvents, RecentEventsLayer, diagnostic_block},
    discovery_secret_fingerprint,
};
use tracing_subscriber::layer::SubscriberExt;

#[derive(Clone)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl io::Write for Captured {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn captured_all_level_traces_do_not_expose_sentinel_secrets() {
    let output = Arc::new(Mutex::new(Vec::new()));
    let retained = Arc::new(RecentEvents::new(1000));
    let subscriber = tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .without_time()
                .with_writer({
                    let output = output.clone();
                    move || Captured(output.clone())
                }),
        )
        .with(RecentEventsLayer::with_buffer(retained.clone()));
    let dispatch = tracing::Dispatch::new(subscriber);

    let identity = PrivateDeviceKey::from_seed(b"IDENTITY_SENTINEL_12345678901234").unwrap();
    let discovery = DiscoveryGroupSecret::from_bytes([0xab; 32]);
    let sas = SasCode::new("918273".into()).unwrap();
    let update = DiscoverySecretUpdate::new(9, &discovery);
    let envelope = ProvisioningEnvelope {
        session_id: PairingSessionId([3; 16]),
        payload: b"PROVISIONING_SENTINEL".to_vec(),
        mac: [4; 32],
    };

    tracing::dispatcher::with_default(&dispatch, || {
        tracing::trace!(identity = ?identity, "identity operation");
        tracing::debug!(discovery = ?discovery, "discovery operation");
        tracing::info!(sas = ?sas, "pairing operation");
        tracing::warn!(update = ?update, "rotation operation");
        tracing::error!(envelope = ?envelope, "provisioning operation");
        tracing::info!(device_id = %"peer", sas = ?sas, "peer pairing operation");
    });

    let captured = String::from_utf8(output.lock().unwrap().clone()).unwrap();
    assert!(captured.contains("REDACTED"));
    let events = retained.all();
    assert_eq!(events.len(), 6, "every level is retained");
    let buffer = events
        .iter()
        .map(|event| format!("{event:?}"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(buffer.contains("REDACTED"));
    let block = diagnostic_block(&DiagnosticInputs {
        peer_device_id: "peer".into(),
        peer_events: retained.for_device("peer", 1000),
        local_events: retained.local(1000),
        ..DiagnosticInputs::default()
    });
    assert!(block.contains("peer pairing operation"));
    assert!(block.contains("provisioning operation"));
    for (name, text) in [("sink", &captured), ("buffer", &buffer), ("block", &block)] {
        assert_secret_free(name, text);
    }
}

struct AcceptingPlatform;

#[async_trait::async_trait]
impl PlatformSecretPersistence for AcceptingPlatform {
    async fn persist(&self, _write: PlatformSecretWrite<'_>) -> Result<(), SecureStoreError> {
        Ok(())
    }
}

#[tokio::test(flavor = "current_thread")]
async fn fingerprint_and_persistence_events_do_not_expose_the_secret() {
    let output = Arc::new(Mutex::new(Vec::new()));
    let retained = Arc::new(RecentEvents::new(1000));
    let subscriber = tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .without_time()
                .with_writer({
                    let output = output.clone();
                    move || Captured(output.clone())
                }),
        )
        .with(RecentEventsLayer::with_buffer(retained.clone()));
    let _guard = tracing::subscriber::set_default(subscriber);

    let sentinel = DiscoveryGroupSecret::from_bytes([0xab; 32]);
    let fingerprint = discovery_secret_fingerprint(&sentinel);
    tracing::info!(
        event = "discovery_advertise",
        scope = "Group",
        port = 41000,
        fingerprint = Some(fingerprint.as_str()),
        device_id = %"peer",
        "advertising peer-routable addresses"
    );
    let store = WriteThroughSecureKeyStore::new(
        InMemorySecureKeyStore::empty(),
        Arc::new(AcceptingPlatform),
    );
    store.store_discovery_group_secret(&sentinel).await.unwrap();
    store
        .store_previous_discovery_group_secret(1, &sentinel)
        .await
        .unwrap();

    let captured = String::from_utf8(output.lock().unwrap().clone()).unwrap();
    let buffer = retained
        .all()
        .iter()
        .map(|event| format!("{event:?}"))
        .collect::<Vec<_>>()
        .join("\n");
    let block = diagnostic_block(&DiagnosticInputs {
        peer_device_id: "peer".into(),
        peer_events: retained.for_device("peer", 1000),
        local_events: retained.local(1000),
        ..DiagnosticInputs::default()
    });
    assert!(buffer.contains("platform_secret_persisted"));
    for (name, text) in [("sink", &captured), ("buffer", &buffer), ("block", &block)] {
        assert!(text.contains(&fingerprint), "{name} lacks the fingerprint");
        assert_secret_free(name, text);
        assert!(!text.contains("[171"), "{name} leaked a byte rendering");
        let base32 = data_encoding::BASE32_NOPAD.encode(sentinel.expose());
        assert!(
            !text.contains(&base32) && !text.contains(&base32.to_ascii_lowercase()),
            "{name} leaked base32"
        );
    }
}

fn assert_secret_free(name: &str, captured: &str) {
    for forbidden in [
        "IDENTITY_SENTINEL",
        "918273",
        "PROVISIONING_SENTINEL",
        "abababab",
        "171, 171",
    ] {
        assert!(!captured.contains(forbidden), "{name} leaked {forbidden}");
    }
}
