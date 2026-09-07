use std::{
    io,
    sync::{Arc, Mutex},
};

use app_core::{
    DiscoveryGroupSecret, DiscoverySecretUpdate, PairingSessionId, PrivateDeviceKey,
    ProvisioningEnvelope, SasCode,
};

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
    let subscriber = tracing_subscriber::fmt()
        .without_time()
        .with_max_level(tracing::Level::TRACE)
        .with_writer({
            let output = output.clone();
            move || Captured(output.clone())
        })
        .finish();
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
    });

    let captured = String::from_utf8(output.lock().unwrap().clone()).unwrap();
    assert!(captured.contains("REDACTED"));
    for forbidden in [
        "IDENTITY_SENTINEL",
        "918273",
        "PROVISIONING_SENTINEL",
        "abababab",
        "171, 171",
    ] {
        assert!(!captured.contains(forbidden), "trace leaked {forbidden}");
    }
}
