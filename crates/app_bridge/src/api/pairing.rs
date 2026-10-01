//! Secret-free pairing and local trusted-device bridge API.

use crate::{
    api::{
        lifecycle::core,
        models::{
            BridgeError, LocalDeviceDto, ManualConnectOutcomeDto, NetworkPreferencesDto,
            PairingCandidateDto, PairingStateDto, RevocationOutcomeDto, SyncStatusDto,
            TrustedDeviceDto,
        },
    },
    frb_generated::StreamSink,
};
use app_core::{DeviceId, PairingCandidate, PairingInstanceId, PairingSessionId};

pub async fn start_pairing(duration_ms: u64) -> Result<String, BridgeError> {
    Ok(core()
        .await?
        .start_pairing(duration_ms)
        .await
        .map_err(BridgeError::from)?
        .to_string())
}

pub async fn stop_pairing() -> Result<(), BridgeError> {
    core()
        .await?
        .stop_pairing()
        .await
        .map_err(BridgeError::from)
}

pub async fn pairing_state() -> Result<PairingStateDto, BridgeError> {
    Ok(core().await?.pairing_state().into())
}

pub async fn pairing_candidates() -> Result<Vec<PairingCandidateDto>, BridgeError> {
    let app = core().await?;
    let trusted = app.trusted_device_addresses().into_iter().collect();
    Ok(app
        .pairing_candidates()
        .into_iter()
        .map(|candidate| PairingCandidateDto::from_core(candidate, &trusted))
        .collect())
}

pub async fn connect_pairing_candidate(
    instance_id: String,
    endpoint: String,
    expires_at_ms: u64,
    timeout_ms: u64,
) -> Result<String, BridgeError> {
    let bytes = decode_16(&instance_id)?;
    let endpoint = endpoint
        .parse()
        .map_err(|_| BridgeError::lifecycle("The pairing endpoint is invalid."))?;
    let session = core()
        .await?
        .connect_pairing_candidate(
            PairingCandidate {
                instance_id: PairingInstanceId::from_bytes(bytes),
                endpoint,
                expires_at_ms,
            },
            timeout_ms,
        )
        .await
        .map_err(BridgeError::from)?;
    Ok(encode_16(session.0))
}

pub async fn confirm_pairing(session_id: String) -> Result<(), BridgeError> {
    core()
        .await?
        .confirm_pairing(PairingSessionId(decode_16(&session_id)?))
        .await
        .map_err(BridgeError::from)
}

pub async fn reject_pairing(session_id: Option<String>) -> Result<(), BridgeError> {
    let session = session_id
        .as_deref()
        .map(decode_16)
        .transpose()?
        .map(PairingSessionId);
    core()
        .await?
        .reject_pairing(session)
        .await
        .map_err(BridgeError::from)
}

pub async fn trusted_devices() -> Result<Vec<TrustedDeviceDto>, BridgeError> {
    let core = core().await?;
    let connections = core.connection_states();
    let attempts = core.attempt_times();
    let paused = !core.network_preferences().sync_enabled;
    let last_known = core.last_known_endpoints();
    Ok(core
        .trusted_devices()
        .map_err(BridgeError::from)?
        .into_iter()
        .map(|record| {
            let connection = connections.get(&record.device_id);
            let attempt = attempts.get(&record.device_id).copied();
            let known = last_known.get(&record.device_id).copied();
            TrustedDeviceDto::from_core(record, connection, attempt, known, paused)
        })
        .collect())
}

/// This device's DeviceId and the name it presents in the pairing hello;
/// `None` when no identity exists yet (local-only mode).
pub async fn local_device() -> Result<Option<LocalDeviceDto>, BridgeError> {
    let core = core().await?;
    Ok(core.device_id().map(|device_id| LocalDeviceDto {
        device_id: device_id.to_string(),
        pairing_name: core.local_device_name(),
    }))
}

/// Dials a trusted, non-revoked peer now, bypassing backoff and initiator
/// preference. An attempt already in flight is not doubled, and a live
/// session is kept.
pub async fn connect_device_now(device_id: String) -> Result<(), BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    let core = core().await?;
    reconnect_allowed(&core.trusted_devices().map_err(BridgeError::from)?, peer)?;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| {
            elapsed.as_millis().try_into().unwrap_or(u64::MAX)
        });
    match core.connect_peer(peer, now_ms).await {
        Ok(_) => Ok(()),
        Err(app_core::AppError::Connection(failure))
            if failure != app_core::ConnectionFailure::Paused =>
        {
            Err(BridgeError::lifecycle(format!(
                "The device could not be reached: {failure}"
            )))
        }
        Err(error) => Err(error.into()),
    }
}

/// Dials a trusted, non-revoked peer at a user-typed address. Address and
/// connection problems are outcomes; paused and unknown/revoked devices are
/// errors.
pub async fn connect_device_at_address(
    device_id: String,
    address: String,
) -> Result<ManualConnectOutcomeDto, BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    let core = core().await?;
    reconnect_allowed(&core.trusted_devices().map_err(BridgeError::from)?, peer)?;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| {
            elapsed.as_millis().try_into().unwrap_or(u64::MAX)
        });
    core.connect_peer_at_address(peer, &address, now_ms)
        .await
        .map(Into::into)
        .map_err(BridgeError::from)
}

/// Addresses at which a paired device on the same LAN can reach this one, as
/// `ip:port`; empty when networking has no bound sync port.
pub async fn local_sync_addresses() -> Result<Vec<String>, BridgeError> {
    Ok(core()
        .await?
        .local_sync_addresses()
        .into_iter()
        .map(|address| address.to_string())
        .collect())
}

/// Refuses a reconnect for an unknown or revoked record before any dial.
fn reconnect_allowed(
    records: &[app_core::TrustedDeviceRecord],
    peer: DeviceId,
) -> Result<(), BridgeError> {
    match records.iter().find(|record| record.device_id == peer) {
        Some(record) if record.state == app_core::TrustState::Trusted => Ok(()),
        Some(_) => Err(BridgeError::lifecycle(
            "A revoked device cannot be reconnected.",
        )),
        None => Err(BridgeError::lifecycle("The device is not paired.")),
    }
}

pub async fn network_preferences() -> Result<NetworkPreferencesDto, BridgeError> {
    Ok(core().await?.network_preferences().into())
}

/// Returns the stored preferences so Flutter renders what Rust holds.
pub async fn set_discoverable(discoverable: bool) -> Result<NetworkPreferencesDto, BridgeError> {
    Ok(core()
        .await?
        .set_discoverable(discoverable)
        .await
        .map_err(BridgeError::from)?
        .into())
}

/// Returns the stored preferences so Flutter renders what Rust holds.
pub async fn set_sync_enabled(sync_enabled: bool) -> Result<NetworkPreferencesDto, BridgeError> {
    Ok(core()
        .await?
        .set_sync_enabled(sync_enabled)
        .await
        .map_err(BridgeError::from)?
        .into())
}

pub async fn sync_status() -> Result<SyncStatusDto, BridgeError> {
    Ok(core().await?.sync_status().into())
}

pub async fn connection_state_stream(
    sink: StreamSink<Vec<TrustedDeviceDto>>,
) -> Result<(), BridgeError> {
    let core = core().await?;
    let receiver = core
        .subscribe_connections()
        .ok_or_else(|| BridgeError::lifecycle("Device networking is unavailable."))?;
    tokio::spawn(forward_connection_states(
        receiver,
        move || {
            Ok(DeviceRows {
                devices: core.trusted_devices().map_err(BridgeError::from)?,
                attempts: core.attempt_times(),
                last_known: core.last_known_endpoints(),
                paused: !core.network_preferences().sync_enabled,
            })
        },
        move |values| sink.add(values).is_ok(),
    ));
    Ok(())
}

/// What one connection-state emission joins with the live states.
struct DeviceRows {
    devices: Vec<app_core::TrustedDeviceRecord>,
    attempts: std::collections::HashMap<DeviceId, u64>,
    last_known: std::collections::HashMap<DeviceId, std::net::SocketAddr>,
    paused: bool,
}

/// Emits the trusted-device list joined with connection state on every
/// connection change. A transient query failure skips that emission and keeps
/// waiting; the stream ends only when the subscriber goes away or the
/// connection source closes. The loop is driven by connection changes, not a
/// timer, so a persistent failure cannot spin. The query also reports whether
/// sync is paused, read at emission time so a toggle's disconnect carries it.
async fn forward_connection_states<Q, E>(
    mut receiver: tokio::sync::watch::Receiver<
        std::collections::HashMap<DeviceId, app_core::PeerConnectionState>,
    >,
    mut query: Q,
    mut emit: E,
) where
    Q: FnMut() -> Result<DeviceRows, BridgeError>,
    E: FnMut(Vec<TrustedDeviceDto>) -> bool,
{
    loop {
        let connections = receiver.borrow_and_update().clone();
        match query() {
            Ok(rows) => {
                let values = rows
                    .devices
                    .into_iter()
                    .map(|record| {
                        let connection = connections.get(&record.device_id);
                        let attempt = rows.attempts.get(&record.device_id).copied();
                        let known = rows.last_known.get(&record.device_id).copied();
                        TrustedDeviceDto::from_core(record, connection, attempt, known, rows.paused)
                    })
                    .collect();
                if !emit(values) {
                    return;
                }
            }
            Err(error) => {
                tracing::warn!(
                    event = "connection_state_stream_query_failed",
                    error = %error,
                    "skipping connection-state emission"
                );
            }
        }
        if receiver.changed().await.is_err() {
            return;
        }
    }
}

pub async fn sync_status_stream(sink: StreamSink<SyncStatusDto>) -> Result<(), BridgeError> {
    let core = core().await?;
    let mut receiver = core
        .subscribe_connections()
        .ok_or_else(|| BridgeError::lifecycle("Device networking is unavailable."))?;
    tokio::spawn(async move {
        loop {
            // Same source as the one-shot `sync_status`, so the stream carries the
            // Offline -> Searching upgrade for a foregrounded device with no peer.
            receiver.mark_unchanged();
            let status = core.sync_status().into();
            if sink.add(status).is_err() || receiver.changed().await.is_err() {
                break;
            }
        }
    });
    Ok(())
}

pub async fn rename_trusted_device(device_id: String, name: String) -> Result<bool, BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    core()
        .await?
        .rename_trusted_device(peer, &name)
        .map_err(BridgeError::from)
}

/// Permanently deletes a revoked device record. Returns `false` when the
/// record is unknown or still trusted.
pub async fn delete_revoked_device(device_id: String) -> Result<bool, BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    core()
        .await?
        .delete_revoked_device(peer)
        .map_err(BridgeError::from)
}

pub async fn revoke_trusted_device(
    device_id: String,
    now_ms: u64,
) -> Result<RevocationOutcomeDto, BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    let outcome = core()
        .await?
        .revoke_trusted_device(peer, now_ms)
        .await
        .map_err(BridgeError::from)?;
    Ok(RevocationOutcomeDto {
        revoked: outcome.revoked,
        rotation_error: outcome.rotation_error,
    })
}

/// Retries discovery-secret rotation after a revocation whose rotation stage
/// failed. Returns the new epoch.
pub async fn rotate_discovery_secret(now_ms: u64) -> Result<u64, BridgeError> {
    core()
        .await?
        .rotate_discovery_secret(now_ms)
        .await
        .map_err(BridgeError::from)
}

pub async fn pairing_state_stream(sink: StreamSink<PairingStateDto>) -> Result<(), BridgeError> {
    let mut receiver = core()
        .await?
        .subscribe_pairing()
        .ok_or_else(|| BridgeError::lifecycle("Pairing is unavailable."))?;
    tokio::spawn(async move {
        if sink.add(receiver.borrow().clone().into()).is_err() {
            return;
        }
        while receiver.changed().await.is_ok() {
            if sink
                .add(receiver.borrow_and_update().clone().into())
                .is_err()
            {
                break;
            }
        }
    });
    Ok(())
}

pub async fn pairing_candidates_stream(
    sink: StreamSink<Vec<PairingCandidateDto>>,
) -> Result<(), BridgeError> {
    let mut receiver = core()
        .await?
        .subscribe_pairing_candidates()
        .ok_or_else(|| BridgeError::lifecycle("Pairing is unavailable."))?;
    let app = core().await?;
    tokio::spawn(async move {
        // Recomputed per emission: revoking a device must stop suppressing it.
        let map = |values: Vec<PairingCandidate>, app: &app_core::AppCore| {
            let trusted = app.trusted_device_addresses().into_iter().collect();
            values
                .into_iter()
                .map(|candidate| PairingCandidateDto::from_core(candidate, &trusted))
                .collect::<Vec<_>>()
        };
        if sink.add(map(receiver.borrow().clone(), &app)).is_err() {
            return;
        }
        while receiver.changed().await.is_ok() {
            if sink
                .add(map(receiver.borrow_and_update().clone(), &app))
                .is_err()
            {
                break;
            }
        }
    });
    Ok(())
}

fn decode_16(value: &str) -> Result<[u8; 16], BridgeError> {
    if value.len() != 32 {
        return Err(BridgeError::lifecycle("The pairing identifier is invalid."));
    }
    let mut output = [0; 16];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        output[index] = (nibble(pair[0])? << 4) | nibble(pair[1])?;
    }
    Ok(output)
}

fn nibble(value: u8) -> Result<u8, BridgeError> {
    match value {
        b'0'..=b'9' => Ok(value - b'0'),
        b'a'..=b'f' => Ok(value - b'a' + 10),
        _ => Err(BridgeError::lifecycle("The pairing identifier is invalid.")),
    }
}

fn encode_16(value: [u8; 16]) -> String {
    value.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn manual_connect_outcome_maps_every_variant() {
        use app_core::{ConnectionFailure, ManualConnectOutcome};

        use crate::api::models::{
            ConnectionFailureKindDto, ManualConnectKindDto, ManualConnectOutcomeDto,
        };

        for (outcome, kind) in [
            (
                ManualConnectOutcome::Connected,
                ManualConnectKindDto::Connected,
            ),
            (
                ManualConnectOutcome::InvalidAddress,
                ManualConnectKindDto::InvalidAddress,
            ),
            (
                ManualConnectOutcome::NotLocalNetwork,
                ManualConnectKindDto::NotLocalNetwork,
            ),
        ] {
            assert_eq!(
                ManualConnectOutcomeDto::from(outcome),
                ManualConnectOutcomeDto {
                    kind,
                    failure_kind: None,
                    message: None,
                }
            );
        }
        assert_eq!(
            ManualConnectOutcomeDto::from(ManualConnectOutcome::Failed(ConnectionFailure::Trust(
                "key mismatch".into()
            ))),
            ManualConnectOutcomeDto {
                kind: ManualConnectKindDto::Failed,
                failure_kind: Some(ConnectionFailureKindDto::Trust),
                message: Some("trust failed: key mismatch".into()),
            }
        );
    }

    use std::{
        collections::HashMap,
        sync::{Arc, Mutex},
    };

    use app_core::{
        DeviceId, PeerConnectionState, PrivateDeviceKey, TrustState, TrustedDeviceRecord,
    };

    use super::{DeviceRows, forward_connection_states, reconnect_allowed};
    use crate::api::models::BridgeError;

    fn record() -> TrustedDeviceRecord {
        let key = PrivateDeviceKey::from_seed(&[7; 32]).unwrap().public_key();
        TrustedDeviceRecord {
            device_id: DeviceId::from_public_key(key.as_bytes()),
            public_key: key,
            friendly_name: "peer".into(),
            paired_at_ms: 1,
            last_seen_ms: None,
            last_sync_ms: None,
            state: TrustState::Trusted,
        }
    }

    #[tokio::test]
    async fn transient_query_failure_keeps_the_stream_open() {
        let (tx, rx) = tokio::sync::watch::channel(HashMap::<DeviceId, PeerConnectionState>::new());
        let emitted = Arc::new(Mutex::new(Vec::new()));
        let calls = Arc::new(Mutex::new(0_u32));
        let query = {
            let calls = calls.clone();
            move || {
                let mut calls = calls.lock().unwrap();
                *calls += 1;
                if *calls == 1 {
                    Err(BridgeError::lifecycle("database is busy"))
                } else {
                    Ok(DeviceRows {
                        devices: vec![record()],
                        attempts: HashMap::new(),
                        last_known: HashMap::new(),
                        paused: false,
                    })
                }
            }
        };
        let emit = {
            let emitted = emitted.clone();
            move |values: Vec<super::TrustedDeviceDto>| {
                emitted.lock().unwrap().push(values.len());
                true
            }
        };
        let task = tokio::spawn(forward_connection_states(rx, query, emit));
        tokio::task::yield_now().await;
        assert!(
            emitted.lock().unwrap().is_empty(),
            "the failed emission is skipped, not synthesised"
        );
        assert!(
            !task.is_finished(),
            "a transient failure does not end the stream"
        );
        // The next connection change drives a normal emission.
        tx.send_replace(HashMap::new());
        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while emitted.lock().unwrap().is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(*emitted.lock().unwrap(), vec![1]);
        assert!(!task.is_finished());
        // The stream ends only when its source does.
        drop(tx);
        tokio::time::timeout(std::time::Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
    }

    #[test]
    fn reconnect_is_refused_for_revoked_and_unknown_devices() {
        let trusted = record();
        let mut revoked = record();
        revoked.state = TrustState::Revoked;
        assert!(reconnect_allowed(std::slice::from_ref(&trusted), trusted.device_id).is_ok());
        let refused =
            reconnect_allowed(std::slice::from_ref(&revoked), revoked.device_id).unwrap_err();
        assert_eq!(refused.kind, crate::api::models::BridgeErrorKind::Lifecycle);
        assert!(refused.message.contains("revoked"));
        assert!(reconnect_allowed(&[], trusted.device_id).is_err());
    }

    #[tokio::test]
    async fn forwarded_rows_carry_the_last_attempt_time() {
        let (_tx, rx) =
            tokio::sync::watch::channel(HashMap::<DeviceId, PeerConnectionState>::new());
        let emitted = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let emitted = emitted.clone();
            move |values: Vec<super::TrustedDeviceDto>| {
                emitted
                    .lock()
                    .unwrap()
                    .extend(values.into_iter().map(|value| value.last_attempt_ms));
                false
            }
        };
        let peer = record().device_id;
        forward_connection_states(
            rx,
            || {
                Ok(DeviceRows {
                    devices: vec![record()],
                    attempts: HashMap::from([(peer, 42)]),
                    last_known: HashMap::new(),
                    paused: false,
                })
            },
            emit,
        )
        .await;
        assert_eq!(*emitted.lock().unwrap(), vec![Some(42)]);
    }

    // Pins that the aggregate status and the per-row values are derived from
    // the same preference and agree while sync is paused.
    #[tokio::test]
    async fn paused_aggregate_and_rows_agree() {
        use app_core::{
            AppCore, AppCoreConfig, FakeDiscoveryProvider, InMemorySecureKeyStore, ManualClock,
            QuinnTransportConfig,
        };

        use crate::api::models::{PeerConnectionKindDto, SyncStatusDto, TrustedDeviceDto};

        let directory = tempfile::tempdir().unwrap();
        let core = AppCore::open_networked_with_discovery(
            directory.path(),
            Arc::new(InMemorySecureKeyStore::seeded([5; 32])),
            "127.0.0.1:0".parse().unwrap(),
            AppCoreConfig::default(),
            QuinnTransportConfig::default(),
            Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
        )
        .await
        .unwrap();
        let mut revoked = record();
        revoked.state = TrustState::Revoked;
        let rows = |core: &AppCore| {
            let paused = !core.network_preferences().sync_enabled;
            [record(), revoked.clone()].map(|record| {
                TrustedDeviceDto::from_core(
                    record,
                    Some(&PeerConnectionState::Synced),
                    None,
                    None,
                    paused,
                )
                .connection
            })
        };

        core.set_sync_enabled(false).await.unwrap();
        assert_eq!(
            SyncStatusDto::from(core.sync_status()),
            SyncStatusDto::Paused
        );
        assert_eq!(
            rows(&core),
            [PeerConnectionKindDto::Paused, PeerConnectionKindDto::Synced]
        );

        core.set_sync_enabled(true).await.unwrap();
        assert_ne!(
            SyncStatusDto::from(core.sync_status()),
            SyncStatusDto::Paused
        );
        assert_eq!(rows(&core), [PeerConnectionKindDto::Synced; 2]);
        core.shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn forwarded_rows_read_paused_while_sync_is_off() {
        let (_tx, rx) =
            tokio::sync::watch::channel(HashMap::<DeviceId, PeerConnectionState>::new());
        let emitted = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let emitted = emitted.clone();
            move |values: Vec<super::TrustedDeviceDto>| {
                emitted
                    .lock()
                    .unwrap()
                    .extend(values.into_iter().map(|value| value.connection));
                false
            }
        };
        forward_connection_states(
            rx,
            || {
                Ok(DeviceRows {
                    devices: vec![record()],
                    attempts: HashMap::new(),
                    last_known: HashMap::new(),
                    paused: true,
                })
            },
            emit,
        )
        .await;
        assert_eq!(
            *emitted.lock().unwrap(),
            vec![crate::api::models::PeerConnectionKindDto::Paused]
        );
    }
}
