//! Secret-free pairing and local trusted-device bridge API.

use crate::{
    api::{
        lifecycle::core,
        models::{
            BridgeError, PairingCandidateDto, PairingStateDto, SyncStatusDto, TrustedDeviceDto,
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
    let mut receiver = core
        .subscribe_connections()
        .ok_or_else(|| BridgeError::lifecycle("Device networking is unavailable."))?;
    tokio::spawn(async move {
        loop {
            let connections = receiver.borrow_and_update().clone();
            let devices = match core.trusted_devices() {
                Ok(devices) => devices,
                Err(_) => break,
            };
            let values = devices
                .into_iter()
                .map(|record| {
                    let connection = connections.get(&record.device_id);
                    TrustedDeviceDto::from_core(record, connection)
                })
                .collect();
            if sink.add(values).is_err() || receiver.changed().await.is_err() {
                break;
            }
        }
    });
    Ok(())
}

pub async fn sync_status_stream(sink: StreamSink<SyncStatusDto>) -> Result<(), BridgeError> {
    let core = core().await?;
    let mut receiver = core
        .subscribe_connections()
        .ok_or_else(|| BridgeError::lifecycle("Device networking is unavailable."))?;
    tokio::spawn(async move {
        loop {
            let status = app_core::aggregate_sync_status(&receiver.borrow_and_update()).into();
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

pub async fn revoke_trusted_device(device_id: String, now_ms: u64) -> Result<bool, BridgeError> {
    let peer: DeviceId = device_id
        .parse()
        .map_err(|_| BridgeError::lifecycle("The device identifier is invalid."))?;
    core()
        .await?
        .revoke_trusted_device(peer, now_ms)
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
