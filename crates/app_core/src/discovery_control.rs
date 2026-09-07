//! Versioned, authenticated discovery-secret rotation control frames.

use hmac::{Hmac, Mac};
use sha2::Sha256;
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{
    adapters::SqliteControlStore, control::TrustState, discovery::DiscoveryGroupSecret,
    identity::DeviceId,
};

pub const DISCOVERY_CONTROL_VERSION: u16 = 1;
pub const DISCOVERY_UPDATE_SIZE: usize = 74;
pub const DISCOVERY_ACK_SIZE: usize = 42;
const UPDATE_DOMAIN: &[u8] = b"fi-discovery-update-v1";
const ACK_DOMAIN: &[u8] = b"fi-discovery-ack-v1";
type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Eq, PartialEq, Zeroize, ZeroizeOnDrop)]
pub struct DiscoverySecretUpdate {
    pub epoch: u64,
    secret: [u8; 32],
}

impl std::fmt::Debug for DiscoverySecretUpdate {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DiscoverySecretUpdate")
            .field("epoch", &self.epoch)
            .field("secret", &"[REDACTED]")
            .finish()
    }
}

impl DiscoverySecretUpdate {
    #[must_use]
    pub fn new(epoch: u64, secret: &DiscoveryGroupSecret) -> Self {
        Self {
            epoch,
            secret: *secret.expose(),
        }
    }

    #[must_use]
    pub fn secret(&self) -> DiscoveryGroupSecret {
        DiscoveryGroupSecret::from_bytes(self.secret)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscoverySecretAck {
    pub epoch: u64,
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum DiscoveryControlError {
    #[error("discovery control frame has an invalid size or version")]
    Malformed,
    #[error("discovery control authentication failed")]
    Authentication,
    #[error("discovery control peer is not trusted")]
    Unauthorized,
}

#[must_use]
pub fn encode_update(
    update: &DiscoverySecretUpdate,
    current_secret: &DiscoveryGroupSecret,
) -> [u8; DISCOVERY_UPDATE_SIZE] {
    let mut frame = [0; DISCOVERY_UPDATE_SIZE];
    frame[..2].copy_from_slice(&DISCOVERY_CONTROL_VERSION.to_be_bytes());
    frame[2..10].copy_from_slice(&update.epoch.to_be_bytes());
    frame[10..42].copy_from_slice(&update.secret);
    let authentication = mac(current_secret, UPDATE_DOMAIN, &frame[..42]);
    frame[42..].copy_from_slice(&authentication);
    frame
}

pub fn decode_update(
    frame: &[u8],
    current_secret: &DiscoveryGroupSecret,
) -> Result<DiscoverySecretUpdate, DiscoveryControlError> {
    if frame.len() != DISCOVERY_UPDATE_SIZE
        || u16::from_be_bytes(frame[..2].try_into().expect("checked size"))
            != DISCOVERY_CONTROL_VERSION
    {
        return Err(DiscoveryControlError::Malformed);
    }
    let expected = mac(current_secret, UPDATE_DOMAIN, &frame[..42]);
    if !bool::from(expected.ct_eq(&frame[42..])) {
        return Err(DiscoveryControlError::Authentication);
    }
    Ok(DiscoverySecretUpdate {
        epoch: u64::from_be_bytes(frame[2..10].try_into().expect("checked size")),
        secret: frame[10..42].try_into().expect("checked size"),
    })
}

#[must_use]
pub fn encode_ack(
    ack: DiscoverySecretAck,
    adopted_secret: &DiscoveryGroupSecret,
) -> [u8; DISCOVERY_ACK_SIZE] {
    let mut frame = [0; DISCOVERY_ACK_SIZE];
    frame[..2].copy_from_slice(&DISCOVERY_CONTROL_VERSION.to_be_bytes());
    frame[2..10].copy_from_slice(&ack.epoch.to_be_bytes());
    let authentication = mac(adopted_secret, ACK_DOMAIN, &frame[..10]);
    frame[10..].copy_from_slice(&authentication);
    frame
}

pub fn decode_ack(
    frame: &[u8],
    adopted_secret: &DiscoveryGroupSecret,
) -> Result<DiscoverySecretAck, DiscoveryControlError> {
    if frame.len() != DISCOVERY_ACK_SIZE
        || u16::from_be_bytes(frame[..2].try_into().expect("checked size"))
            != DISCOVERY_CONTROL_VERSION
    {
        return Err(DiscoveryControlError::Malformed);
    }
    let expected = mac(adopted_secret, ACK_DOMAIN, &frame[..10]);
    if !bool::from(expected.ct_eq(&frame[10..])) {
        return Err(DiscoveryControlError::Authentication);
    }
    Ok(DiscoverySecretAck {
        epoch: u64::from_be_bytes(frame[2..10].try_into().expect("checked size")),
    })
}

pub fn authorize_peer(
    control: &SqliteControlStore,
    peer: DeviceId,
) -> Result<(), DiscoveryControlError> {
    if control
        .peer_trust(peer)
        .ok()
        .flatten()
        .is_some_and(|record| record.state == TrustState::Trusted)
    {
        Ok(())
    } else {
        Err(DiscoveryControlError::Unauthorized)
    }
}

fn mac(secret: &DiscoveryGroupSecret, domain: &[u8], payload: &[u8]) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(secret.expose()).expect("HMAC accepts 32-byte keys");
    mac.update(domain);
    mac.update(payload);
    mac.finalize().into_bytes().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_authenticated_update_and_ack_round_trip() {
        let old = DiscoveryGroupSecret::from_bytes([7; 32]);
        let new = DiscoveryGroupSecret::from_bytes([8; 32]);
        let update = DiscoverySecretUpdate::new(4, &new);
        let frame = encode_update(&update, &old);
        assert_eq!(decode_update(&frame, &old).unwrap(), update);
        let ack = encode_ack(DiscoverySecretAck { epoch: 4 }, &new);
        assert_eq!(decode_ack(&ack, &new).unwrap().epoch, 4);

        let mut tampered = frame;
        tampered[20] ^= 1;
        assert_eq!(
            decode_update(&tampered, &old),
            Err(DiscoveryControlError::Authentication)
        );
        assert_eq!(
            decode_update(&frame[..frame.len() - 1], &old),
            Err(DiscoveryControlError::Malformed)
        );
    }

    #[test]
    fn update_debug_never_reveals_secret() {
        let secret = DiscoveryGroupSecret::from_bytes([0xab; 32]);
        let output = format!("{:?}", DiscoverySecretUpdate::new(2, &secret));
        assert!(output.contains("REDACTED"));
        assert!(!output.contains("171"));
        assert!(!output.contains("abab"));
    }
}
