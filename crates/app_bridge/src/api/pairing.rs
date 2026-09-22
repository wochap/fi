//! Secret-free pairing and local trusted-device bridge API.

use crate::{
    api::{
        lifecycle::core,
        models::{
            BridgeError, PairingCandidateDto, PairingStateDto, RevocationOutcomeDto, SyncStatusDto,
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
    Ok(core()
        .await?
        .pairing_candidates()
        .into_iter()
        .map(Into::into)
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
    Ok(core
        .trusted_devices()
        .map_err(BridgeError::from)?
        .into_iter()
        .map(|record| {
            let connection = connections.get(&record.device_id);
            TrustedDeviceDto::from_core(record, connection)
        })
        .collect())
}

pub async fn sync_status() -> Result<SyncStatusDto, BridgeError> {
    Ok(core().await?.sync_status().into())
}

pub async fn discovery_secret_for_platform() -> Result<Option<Vec<u8>>, BridgeError> {
    Ok(core()
        .await?
        .discovery_secret_for_platform()
        .await
        .map_err(BridgeError::from)?
        .map(|secret| secret.expose().to_vec()))
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
        move || core.trusted_devices().map_err(BridgeError::from),
        move |values| sink.add(values).is_ok(),
    ));
    Ok(())
}

/// Emits the trusted-device list joined with connection state on every
/// connection change. A transient query failure skips that emission and keeps
/// waiting; the stream ends only when the subscriber goes away or the
/// connection source closes. The loop is driven by connection changes, not a
/// timer, so a persistent failure cannot spin.
async fn forward_connection_states<Q, E>(
    mut receiver: tokio::sync::watch::Receiver<
        std::collections::HashMap<DeviceId, app_core::PeerConnectionState>,
    >,
    mut query: Q,
    mut emit: E,
) where
    Q: FnMut() -> Result<Vec<app_core::TrustedDeviceRecord>, BridgeError>,
    E: FnMut(Vec<TrustedDeviceDto>) -> bool,
{
    loop {
        let connections = receiver.borrow_and_update().clone();
        match query() {
            Ok(devices) => {
                let values = devices
                    .into_iter()
                    .map(|record| {
                        let connection = connections.get(&record.device_id);
                        TrustedDeviceDto::from_core(record, connection)
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
    tokio::spawn(async move {
        let map = |values: Vec<PairingCandidate>| values.into_iter().map(Into::into).collect();
        if sink.add(map(receiver.borrow().clone())).is_err() {
            return;
        }
        while receiver.changed().await.is_ok() {
            if sink.add(map(receiver.borrow_and_update().clone())).is_err() {
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
    use std::{
        collections::HashMap,
        sync::{Arc, Mutex},
    };

    use app_core::{
        DeviceId, PeerConnectionState, PrivateDeviceKey, TrustState, TrustedDeviceRecord,
    };

    use super::forward_connection_states;
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
                    Ok(vec![record()])
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
}
