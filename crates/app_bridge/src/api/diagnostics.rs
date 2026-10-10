//! Retained log lines and the per-peer diagnostic block for the devices
//! screen. Everything here is built from already-redacted tracing output and
//! public connection state.

use std::sync::Mutex;

use app_core::{
    DeviceId, PeerConnectionState, TrustedDeviceRecord,
    diagnostics::{self, CAPACITY, DiagnosticInputs},
};

use crate::api::{
    lifecycle::core,
    models::{BridgeError, LogEventDto, PeerConnectionKindDto, TrustedDeviceDto},
};

/// Version text for the first line of the diagnostic block, set once by
/// Flutter at startup.
static BUILD_VERSION: Mutex<Option<String>> = Mutex::new(None);

/// Stores the version text the diagnostic block reports. Until called the
/// block reads `Version: unknown`.
pub fn set_build_info(version: String) {
    if let Ok(mut stored) = BUILD_VERSION.lock() {
        *stored = Some(version);
    }
}

/// The most recent retained events for one peer, in emission order.
pub fn recent_device_logs(device_id: String, limit: u32) -> Vec<LogEventDto> {
    diagnostics::recent_events_for(&device_id, limit as usize)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// The most recent retained events that name no peer, in emission order.
pub fn recent_local_logs(limit: u32) -> Vec<LogEventDto> {
    diagnostics::recent_local_events(limit as usize)
        .into_iter()
        .map(Into::into)
        .collect()
}

/// Plain-text diagnostic block for one trusted or revoked device.
pub async fn diagnostic_block(device_id: String) -> Result<String, BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    let core = core().await?;
    let record = core
        .trusted_devices()
        .map_err(BridgeError::from)?
        .into_iter()
        .find(|record| record.device_id == peer)
        .ok_or_else(|| BridgeError::lifecycle("The device is not paired."))?;
    let version = BUILD_VERSION.lock().ok().and_then(|stored| stored.clone());
    Ok(assemble_block(
        version,
        core.device_id(),
        record,
        core.connection_states().get(&peer),
        core.attempt_times().get(&peer).copied(),
        core.network_addr().map(|address| address.port()),
    ))
}

fn assemble_block(
    version: Option<String>,
    local: Option<DeviceId>,
    record: TrustedDeviceRecord,
    connection: Option<&PeerConnectionState>,
    last_attempt_ms: Option<u64>,
    sync_port: Option<u16>,
) -> String {
    let peer_device_id = record.device_id.to_string();
    let peer_name = record.display_name().to_owned();
    let row = TrustedDeviceDto::from_core(record, connection, last_attempt_ms, None, false);
    let connection_state = if row.revoked {
        "revoked".to_owned()
    } else {
        connection_label(row.connection).to_owned()
    };
    diagnostics::diagnostic_block(&DiagnosticInputs {
        version,
        local_device_id: local.map(|device| device.to_string()),
        peer_events: diagnostics::recent_events_for(&peer_device_id, CAPACITY),
        local_events: diagnostics::recent_local_events(CAPACITY),
        peer_device_id,
        peer_name: Some(peer_name),
        connection_state,
        endpoint: row.attempt_endpoint,
        last_attempt_ms: row.last_attempt_ms,
        failure: row.failure,
        sync_port,
    })
}

const fn connection_label(kind: PeerConnectionKindDto) -> &'static str {
    match kind {
        PeerConnectionKindDto::Offline => "offline",
        PeerConnectionKindDto::Searching => "searching",
        PeerConnectionKindDto::Connected => "connected",
        PeerConnectionKindDto::Syncing => "syncing",
        PeerConnectionKindDto::Synced => "synced",
        PeerConnectionKindDto::Error => "error",
        PeerConnectionKindDto::Paused => "paused",
    }
}

#[cfg(test)]
mod tests {
    use app_core::{
        ConnectionFailure, DeviceId, PeerConnectionState, PrivateDeviceKey, TrustState,
        TrustedDeviceRecord,
    };

    use super::assemble_block;

    fn record() -> TrustedDeviceRecord {
        let key = PrivateDeviceKey::from_seed(&[8; 32]).unwrap().public_key();
        TrustedDeviceRecord {
            device_id: DeviceId::from_public_key(key.as_bytes()),
            public_key: key,
            announced_name: "Fi peer".into(),
            nickname: None,
            paired_at_ms: 1,
            last_seen_ms: None,
            last_sync_ms: None,
            state: TrustState::Trusted,
        }
    }

    #[test]
    fn block_starts_with_the_version_and_names_the_failure() {
        let peer = record().device_id;
        let failed = PeerConnectionState::Failed {
            failure: ConnectionFailure::Tls("bad certificate".into()),
            endpoint: Some("192.168.1.20:47380".parse().unwrap()),
        };
        let block = assemble_block(
            Some("fi 1.2.3 (abc1234)".into()),
            Some(DeviceId::from_public_key(&[1; 32])),
            record(),
            Some(&failed),
            Some(0),
            Some(47380),
        );
        let lines = block.lines().collect::<Vec<_>>();
        assert_eq!(lines[0], "Version: fi 1.2.3 (abc1234)");
        assert!(block.contains(&format!("Peer device: {peer}")));
        assert!(block.contains("Connection state: error"));
        assert!(block.contains("Endpoint: 192.168.1.20:47380"));
        assert!(block.contains("Failure: TLS failed: bad certificate"));
        assert!(block.contains("Sync port: 47380"));
        let unknown = assemble_block(None, None, record(), None, None, None);
        assert!(unknown.starts_with("Version: unknown\n"));
    }
}
