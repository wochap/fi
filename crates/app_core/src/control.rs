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

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TrustedDeviceRecord {
    pub device_id: DeviceId,
    pub public_key: PublicDeviceKey,
    pub friendly_name: String,
    pub paired_at_ms: u64,
    pub last_seen_ms: Option<u64>,
    pub last_sync_ms: Option<u64>,
    pub state: TrustState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingJournalStage {
    Confirmed,
    ProvisioningStored,
    RootJoining,
    TrustStored,
    AwaitingAcknowledgement,
    Complete,
}

impl PairingJournalStage {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Confirmed => "confirmed",
            Self::ProvisioningStored => "provisioning_stored",
            Self::RootJoining => "root_joining",
            Self::TrustStored => "trust_stored",
            Self::AwaitingAcknowledgement => "awaiting_acknowledgement",
            Self::Complete => "complete",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "confirmed" => Self::Confirmed,
            "provisioning_stored" => Self::ProvisioningStored,
            "root_joining" => Self::RootJoining,
            "trust_stored" => Self::TrustStored,
            "awaiting_acknowledgement" => Self::AwaitingAcknowledgement,
            "complete" => Self::Complete,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingJournalRecord {
    pub session_id: [u8; 16],
    pub peer_device_id: DeviceId,
    pub stage: PairingJournalStage,
    pub joining_root: Option<String>,
    /// Set when the commit for this session failed. The stage stays at the
    /// last step that succeeded, so a non-`Complete` stage with a reason is an
    /// incomplete session that a later authenticated connection can resume.
    pub failure_reason: Option<String>,
    pub updated_at_ms: u64,
}

/// Durable write-ahead marker for a dataset reset. Written in its own
/// transaction before any destructive step and cleared in the same transaction
/// that removes the root-scoped control rows.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ResetIntent {
    pub requested_at_ms: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscoveryGroupMetadata {
    pub epoch: u64,
    pub updated_at_ms: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiscoveryRotationStage {
    Prepared,
    Active,
}

impl DiscoveryRotationStage {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Prepared => "prepared",
            Self::Active => "active",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "prepared" => Some(Self::Prepared),
            "active" => Some(Self::Active),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DiscoveryRotationJournal {
    pub previous_epoch: u64,
    pub target_epoch: u64,
    pub retain_until_ms: u64,
    pub stage: DiscoveryRotationStage,
    pub updated_at_ms: u64,
}
