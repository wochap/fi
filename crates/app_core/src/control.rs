//! Public identity, trust, and non-authoritative connection metadata.

use std::net::SocketAddr;

use crate::{
    identity::{DeviceId, PublicDeviceKey},
    routing::PeerConnectionState,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrustState {
    Trusted,
    Revoked,
}

impl TrustState {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Trusted => "trusted",
            Self::Revoked => "revoked",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "trusted" => Some(Self::Trusted),
            "revoked" => Some(Self::Revoked),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalIdentityRecord {
    pub device_id: DeviceId,
    pub public_key: PublicDeviceKey,
    pub created_at_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PeerTrustRecord {
    pub device_id: DeviceId,
    pub public_key: PublicDeviceKey,
    pub state: TrustState,
    pub updated_at_ms: u64,
    pub last_seen_ms: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PeerConnectionMetadata {
    pub device_id: DeviceId,
    pub state: PeerConnectionState,
    pub endpoint: Option<SocketAddr>,
    pub updated_at_ms: u64,
}
