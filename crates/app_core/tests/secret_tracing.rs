use std::{
    io,
    sync::{Arc, Mutex},
};

use app_core::{
    DiscoveryGroupSecret, DiscoverySecretUpdate, PairingSessionId, PrivateDeviceKey,
    ProvisioningEnvelope, SasCode,
    diagnostics::{DiagnosticInputs, RecentEvents, RecentEventsLayer, diagnostic_block},
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
