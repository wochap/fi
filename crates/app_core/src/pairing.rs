//! Canonical, channel-bound SAS pairing protocol and state reducer.

use std::{fmt, time::Duration};

use automerge_repo::DocumentId;
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{
    discovery::{DiscoveryGroupSecret, PairingInstanceId},
    identity::{DeviceId, PublicDeviceKey},
};

pub const PAIRING_ALPN: &[u8] = b"fi-pair/1";
pub const PAIRING_PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_PAIRING_WINDOW: Duration = Duration::from_secs(120);
const TRANSCRIPT_DOMAIN: &[u8] = b"fi-pair-transcript-v1";
const EXPORTER_DOMAIN: &[u8] = b"EXPORTER-fi-pair-v1";
const MAX_MESSAGE_SIZE: usize = 1024;
const MAX_FRIENDLY_NAME: usize = 64;

type HmacSha256 = Hmac<Sha256>;

/// A user-comparable code whose formatting is deliberately non-revealing.
#[derive(Clone, Eq, PartialEq, Zeroize, ZeroizeOnDrop)]
pub struct SasCode(String);

impl SasCode {
    pub fn new(value: String) -> Result<Self, PairingError> {
        if valid_sas(&value) {
            Ok(Self(value))
        } else {
            Err(PairingError::Malformed("SAS must contain six digits"))
        }
    }

    #[must_use]
    pub fn expose(&self) -> &str {
        &self.0
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.0.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for SasCode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SasCode([REDACTED])")
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct PairingSessionId(pub [u8; 16]);

#[must_use]
pub fn pairing_session_id(
    initiator: PairingInstanceId,
    responder: PairingInstanceId,
) -> PairingSessionId {
    let mut digest = Sha256::new();
    digest.update(b"fi-pair-session-v1");
    digest.update(initiator.as_bytes());
    digest.update(responder.as_bytes());
    let digest = digest.finalize();
    PairingSessionId(digest[..16].try_into().expect("SHA-256 prefix is 16 bytes"))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingRole {
    Initiator,
    Responder,
}

impl PairingRole {
    const fn tag(self) -> u8 {
        match self {
            Self::Initiator => 1,
            Self::Responder => 2,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RootState {
    NeedsDecision,
    Ready(DocumentId),
}

#[derive(Clone, Eq, PartialEq)]
pub struct PairingHello {
    pub version: u16,
    pub role: PairingRole,
    pub instance_id: PairingInstanceId,
    pub public_key: PublicDeviceKey,
    pub nonce: [u8; 32],
    pub friendly_name: String,
    pub root_state: RootState,
}

impl fmt::Debug for PairingHello {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PairingHello")
            .field("version", &self.version)
            .field("role", &self.role)
            .field("instance_id", &self.instance_id)
            .field("public_key", &self.public_key)
            .field("nonce", &"[REDACTED]")
            .field("friendly_name", &self.friendly_name)
            .field("root_state", &self.root_state)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingDecisionKind {
    Confirm,
    Reject,
}

#[derive(Clone, Eq, PartialEq)]
pub struct PairingDecision {
    pub session_id: PairingSessionId,
    pub kind: PairingDecisionKind,
    pub mac: [u8; 32],
}

impl fmt::Debug for PairingDecision {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PairingDecision")
            .field("session_id", &self.session_id)
            .field("kind", &self.kind)
            .field("mac", &"[REDACTED]")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProvisioningData {
    pub root: DocumentId,
    pub discovery_secret: DiscoveryGroupSecret,
    pub epoch: u64,
    pub existing_device_id: DeviceId,
    pub existing_public_key: PublicDeviceKey,
    pub existing_name: String,
    pub sync_port: u16,
}

#[derive(Clone, Eq, PartialEq)]
pub struct ProvisioningEnvelope {
    pub session_id: PairingSessionId,
    pub payload: Vec<u8>,
    pub mac: [u8; 32],
}

impl fmt::Debug for ProvisioningEnvelope {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProvisioningEnvelope")
            .field("session_id", &self.session_id)
            .field("payload", &"[REDACTED]")
            .field("mac", &"[REDACTED]")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingMessage {
    Hello(PairingHello),
    Decision(PairingDecision),
    Provision(ProvisioningEnvelope),
    CommitAck {
        session_id: PairingSessionId,
        mac: [u8; 32],
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingCandidate {
    pub instance_id: PairingInstanceId,
    pub endpoint: std::net::SocketAddr,
    pub expires_at_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingState {
    Idle,
    Discoverable {
        instance_id: PairingInstanceId,
        deadline_ms: u64,
    },
    Connecting {
        session_id: PairingSessionId,
        candidate: PairingCandidate,
        deadline_ms: u64,
        /// The local instance id of the discoverable window this attempt
        /// belongs to, kept so a released attempt can return to it.
        instance_id: PairingInstanceId,
        /// The deadline of the discoverable window, which outlives the
        /// per-attempt `deadline_ms`.
        window_deadline_ms: u64,
    },
    AwaitingConfirmation {
        session_id: PairingSessionId,
        sas: SasCode,
        local_confirmed: bool,
        remote_confirmed: bool,
        deadline_ms: u64,
    },
    Committing {
        session_id: PairingSessionId,
        peer: DeviceId,
        deadline_ms: u64,
    },
    Trusted {
        peer: DeviceId,
    },
    Failed {
        error: PairingError,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingInput {
    Start {
        instance_id: PairingInstanceId,
        deadline_ms: u64,
    },
    Stop,
    Select {
        session_id: PairingSessionId,
        candidate: PairingCandidate,
        deadline_ms: u64,
    },
    SasReady {
        session_id: PairingSessionId,
        sas: SasCode,
        deadline_ms: u64,
    },
    LocalConfirm {
        session_id: PairingSessionId,
    },
    RemoteConfirm {
        session_id: PairingSessionId,
    },
    BeginCommit {
        session_id: PairingSessionId,
        peer: DeviceId,
        deadline_ms: u64,
    },
    CommitComplete {
        session_id: PairingSessionId,
        peer: DeviceId,
    },
    Reject {
        session_id: Option<PairingSessionId>,
    },
    /// Abandons an outbound attempt without failing the window: the peer
    /// refused the connection because it was busy, so the local device returns
    /// to discoverable and may select again.
    Release {
        session_id: PairingSessionId,
    },
    Timeout {
        now_ms: u64,
    },
    Fail(PairingError),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingEvent {
    Started { deadline_ms: u64 },
    CandidateSelected(PairingSessionId),
    CandidateReleased(PairingSessionId),
    SasReady(SasCode),
    ConfirmationChanged { local: bool, remote: bool },
    CommitReady(PairingSessionId),
    Trusted(DeviceId),
    Stopped,
    Failed(PairingError),
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum PairingError {
    #[error("pairing is not active")]
    Inactive,
    /// The local device cannot accept an inbound connection right now because
    /// it already holds a pairing session. Never fatal to the local window.
    #[error("the device is busy with another pairing session")]
    Busy,
    /// The peer refused the outbound connection because it was busy. The local
    /// window survives and the attempt may be retried.
    #[error("the peer is busy with another pairing session")]
    PeerBusy,
    #[error("pairing transition is invalid")]
    InvalidTransition,
    #[error("pairing session has expired")]
    Expired,
    #[error("pairing message is malformed: {0}")]
    Malformed(&'static str),
    #[error("unsupported pairing protocol version {0}")]
    UnsupportedVersion(u16),
    #[error("pairing hello key does not match the TLS certificate")]
    CertificateKeyMismatch,
    #[error("pairing authentication failed")]
    Authentication,
    #[error("both devices need a root dataset")]
    BothRootless,
    #[error("the devices have different root datasets")]
    RootMismatch,
    #[error("pairing was rejected")]
    Rejected,
    #[error("pairing transport failed: {0}")]
    Transport(String),
}

pub fn reduce_pairing(
    state: &PairingState,
    input: PairingInput,
) -> Result<(PairingState, PairingEvent), PairingError> {
    use PairingInput as I;
    use PairingState as S;
    match (state, input) {
        (
            S::Idle | S::Failed { .. } | S::Trusted { .. },
            I::Start {
                instance_id,
                deadline_ms,
            },
        ) => Ok((
            S::Discoverable {
                instance_id,
                deadline_ms,
            },
            PairingEvent::Started { deadline_ms },
        )),
        (
            S::Discoverable {
                instance_id,
                deadline_ms: active,
            },
            I::Select {
                session_id,
                candidate,
                deadline_ms,
            },
        ) if deadline_ms <= *active => Ok((
            S::Connecting {
                session_id,
                candidate,
                deadline_ms,
                instance_id: *instance_id,
                window_deadline_ms: *active,
            },
            PairingEvent::CandidateSelected(session_id),
        )),
        (
            S::Connecting {
                session_id: active,
                instance_id,
                window_deadline_ms,
                ..
            },
            I::Release { session_id },
        ) if *active == session_id => Ok((
            S::Discoverable {
                instance_id: *instance_id,
                deadline_ms: *window_deadline_ms,
            },
            PairingEvent::CandidateReleased(session_id),
        )),
        (
            S::Connecting {
                session_id: active, ..
            },
            I::SasReady {
                session_id,
                sas,
                deadline_ms,
            },
        ) if *active == session_id => Ok((
            S::AwaitingConfirmation {
                session_id,
                sas: sas.clone(),
                local_confirmed: false,
                remote_confirmed: false,
                deadline_ms,
            },
            PairingEvent::SasReady(sas),
        )),
        (
            S::AwaitingConfirmation {
                session_id: active,
                sas,
                remote_confirmed,
                deadline_ms,
                ..
            },
            I::LocalConfirm { session_id },
        ) if *active == session_id => {
            let next = S::AwaitingConfirmation {
                session_id,
                sas: sas.clone(),
                local_confirmed: true,
                remote_confirmed: *remote_confirmed,
                deadline_ms: *deadline_ms,
            };
            Ok((
                next,
                if *remote_confirmed {
                    PairingEvent::CommitReady(session_id)
                } else {
                    PairingEvent::ConfirmationChanged {
                        local: true,
                        remote: false,
                    }
                },
            ))
        }
        (
            S::AwaitingConfirmation {
                session_id: active,
                sas,
                local_confirmed,
                deadline_ms,
                ..
            },
            I::RemoteConfirm { session_id },
        ) if *active == session_id => {
            let next = S::AwaitingConfirmation {
                session_id,
                sas: sas.clone(),
                local_confirmed: *local_confirmed,
                remote_confirmed: true,
                deadline_ms: *deadline_ms,
            };
            Ok((
                next,
                if *local_confirmed {
                    PairingEvent::CommitReady(session_id)
                } else {
                    PairingEvent::ConfirmationChanged {
                        local: false,
                        remote: true,
                    }
                },
            ))
        }
        (
            S::AwaitingConfirmation {
                session_id: active,
                local_confirmed: true,
                remote_confirmed: true,
                ..
            },
            I::BeginCommit {
                session_id,
                peer,
                deadline_ms,
            },
        ) if *active == session_id => Ok((
            S::Committing {
                session_id,
                peer,
                deadline_ms,
            },
            PairingEvent::CommitReady(session_id),
        )),
        (
            S::Committing {
                session_id: active, ..
            },
            I::CommitComplete { session_id, peer },
        ) if *active == session_id => Ok((S::Trusted { peer }, PairingEvent::Trusted(peer))),
        (_, I::Stop) => Ok((S::Idle, PairingEvent::Stopped)),
        (_, I::Reject { .. }) => Ok((
            S::Failed {
                error: PairingError::Rejected,
            },
            PairingEvent::Failed(PairingError::Rejected),
        )),
        (
            S::Discoverable { deadline_ms, .. }
            | S::Connecting { deadline_ms, .. }
            | S::AwaitingConfirmation { deadline_ms, .. }
            | S::Committing { deadline_ms, .. },
            I::Timeout { now_ms },
        ) if now_ms >= *deadline_ms => Ok((
            S::Failed {
                error: PairingError::Expired,
            },
            PairingEvent::Failed(PairingError::Expired),
        )),
        (_, I::Fail(error)) => Ok((
            S::Failed {
                error: error.clone(),
            },
            PairingEvent::Failed(error),
        )),
        _ => Err(PairingError::InvalidTransition),
    }
}

fn valid_sas(value: &str) -> bool {
    value.len() == 6 && value.bytes().all(|b| b.is_ascii_digit())
}

#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct PairingKeys {
    sas_material: [u8; 32],
    initiator_confirmation: [u8; 32],
    responder_confirmation: [u8; 32],
    provisioning: [u8; 32],
}

impl fmt::Debug for PairingKeys {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PairingKeys([REDACTED])")
    }
}

impl PairingKeys {
    #[must_use]
    pub fn sas(&self) -> SasCode {
        SasCode(format!("{:06}", unbiased_sas(&self.sas_material)))
    }
    fn confirmation_key(&self, role: PairingRole) -> &[u8; 32] {
        match role {
            PairingRole::Initiator => &self.initiator_confirmation,
            PairingRole::Responder => &self.responder_confirmation,
        }
    }
}

pub fn canonical_transcript(
    initiator: &PairingHello,
    responder: &PairingHello,
) -> Result<Vec<u8>, PairingError> {
    validate_hello(initiator, PairingRole::Initiator)?;
    validate_hello(responder, PairingRole::Responder)?;
    let mut out = Vec::with_capacity(256);
    field(&mut out, 1, TRANSCRIPT_DOMAIN)?;
    field(&mut out, 2, &PAIRING_PROTOCOL_VERSION.to_be_bytes())?;
    append_hello_transcript(&mut out, 10, initiator)?;
    append_hello_transcript(&mut out, 20, responder)?;
    Ok(out)
}

fn append_hello_transcript(
    out: &mut Vec<u8>,
    base: u8,
    hello: &PairingHello,
) -> Result<(), PairingError> {
    field(out, base, &[hello.role.tag()])?;
    field(out, base + 1, hello.public_key.as_bytes())?;
    field(out, base + 2, hello.instance_id.as_bytes())?;
    field(out, base + 3, &hello.nonce)?;
    match hello.root_state {
        RootState::NeedsDecision => field(out, base + 4, &[0]),
        RootState::Ready(root) => field(out, base + 4, root.to_string().as_bytes()),
    }
}

pub fn derive_pairing_keys(
    transcript: &[u8],
    tls_exporter: &[u8],
) -> Result<PairingKeys, PairingError> {
    if tls_exporter.len() < 32 {
        return Err(PairingError::Malformed("TLS exporter is too short"));
    }
    let transcript_hash = Sha256::digest(transcript);
    let hk = Hkdf::<Sha256>::new(Some(&transcript_hash), tls_exporter);
    fn expand(
        hk: &Hkdf<Sha256>,
        label: &[u8],
        transcript_hash: &[u8],
    ) -> Result<[u8; 32], PairingError> {
        let mut info =
            Vec::with_capacity(EXPORTER_DOMAIN.len() + label.len() + transcript_hash.len());
        info.extend_from_slice(EXPORTER_DOMAIN);
        info.extend_from_slice(label);
        info.extend_from_slice(transcript_hash);
        let mut out = [0; 32];
        hk.expand(&info, &mut out)
            .map_err(|_| PairingError::Authentication)?;
        Ok(out)
    }
    Ok(PairingKeys {
        sas_material: expand(&hk, b"/sas", &transcript_hash)?,
        initiator_confirmation: expand(&hk, b"/confirm/initiator", &transcript_hash)?,
        responder_confirmation: expand(&hk, b"/confirm/responder", &transcript_hash)?,
        provisioning: expand(&hk, b"/provision", &transcript_hash)?,
    })
}

fn unbiased_sas(seed: &[u8; 32]) -> u32 {
    const RANGE: u32 = 1_000_000;
    const LIMIT: u32 = u32::MAX - (u32::MAX % RANGE);
    let mut counter = 0_u32;
    loop {
        let mut mac = HmacSha256::new_from_slice(seed).expect("valid HMAC key");
        mac.update(b"fi-pair-sas-rejection-v1");
        mac.update(&counter.to_be_bytes());
        let bytes = mac.finalize().into_bytes();
        for chunk in bytes.chunks_exact(4) {
            let value = u32::from_be_bytes(chunk.try_into().expect("four byte chunk"));
            if value < LIMIT {
                return value % RANGE;
            }
        }
        counter = counter.wrapping_add(1);
    }
}

pub fn sign_decision(
    keys: &PairingKeys,
    role: PairingRole,
    session_id: PairingSessionId,
    kind: PairingDecisionKind,
) -> PairingDecision {
    let mut mac = HmacSha256::new_from_slice(keys.confirmation_key(role)).expect("valid HMAC key");
    mac.update(b"fi-pair-decision-v1");
    mac.update(&session_id.0);
    mac.update(&[match kind {
        PairingDecisionKind::Confirm => 1,
        PairingDecisionKind::Reject => 2,
    }]);
    PairingDecision {
        session_id,
        kind,
        mac: mac.finalize().into_bytes().into(),
    }
}

pub fn verify_decision(
    keys: &PairingKeys,
    role: PairingRole,
    expected_session: PairingSessionId,
    value: &PairingDecision,
    now_ms: u64,
    deadline_ms: u64,
) -> Result<(), PairingError> {
    if now_ms >= deadline_ms {
        return Err(PairingError::Expired);
    }
    if value.session_id != expected_session {
        return Err(PairingError::Authentication);
    }
    let expected = sign_decision(keys, role, expected_session, value.kind);
    if bool::from(expected.mac.ct_eq(&value.mac)) {
        Ok(())
    } else {
        Err(PairingError::Authentication)
    }
}

pub fn protect_provisioning(
    keys: &PairingKeys,
    session_id: PairingSessionId,
    data: &ProvisioningData,
) -> Result<ProvisioningEnvelope, PairingError> {
    let payload = encode_provisioning(data)?;
    let mut mac = HmacSha256::new_from_slice(&keys.provisioning).expect("valid HMAC key");
    mac.update(b"fi-pair-provision-v1");
    mac.update(&session_id.0);
    mac.update(&payload);
    Ok(ProvisioningEnvelope {
        session_id,
        payload,
        mac: mac.finalize().into_bytes().into(),
    })
}

pub fn open_provisioning(
    keys: &PairingKeys,
    expected_session: PairingSessionId,
    envelope: &ProvisioningEnvelope,
    now_ms: u64,
    deadline_ms: u64,
) -> Result<ProvisioningData, PairingError> {
    if now_ms >= deadline_ms {
        return Err(PairingError::Expired);
    }
    if envelope.session_id != expected_session {
        return Err(PairingError::Authentication);
    }
    let mut mac = HmacSha256::new_from_slice(&keys.provisioning).expect("valid HMAC key");
    mac.update(b"fi-pair-provision-v1");
    mac.update(&envelope.session_id.0);
    mac.update(&envelope.payload);
    mac.verify_slice(&envelope.mac)
        .map_err(|_| PairingError::Authentication)?;
    decode_provisioning(&envelope.payload)
}

#[must_use]
pub fn sign_commit_ack(keys: &PairingKeys, session_id: PairingSessionId) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(&keys.provisioning).expect("valid HMAC key");
    mac.update(b"fi-pair-commit-ack-v1");
    mac.update(&session_id.0);
    mac.finalize().into_bytes().into()
}

pub fn verify_commit_ack(
    keys: &PairingKeys,
    session_id: PairingSessionId,
    value: &[u8; 32],
) -> Result<(), PairingError> {
    let expected = sign_commit_ack(keys, session_id);
    if bool::from(expected.ct_eq(value)) {
        Ok(())
    } else {
        Err(PairingError::Authentication)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RootCompatibility {
    ProvisionInitiatorToResponder,
    ProvisionResponderToInitiator,
    SameRoot,
}

pub fn root_compatibility(
    initiator: &RootState,
    responder: &RootState,
) -> Result<RootCompatibility, PairingError> {
    match (initiator, responder) {
        (RootState::Ready(_), RootState::NeedsDecision) => {
            Ok(RootCompatibility::ProvisionInitiatorToResponder)
        }
        (RootState::NeedsDecision, RootState::Ready(_)) => {
            Ok(RootCompatibility::ProvisionResponderToInitiator)
        }
        (RootState::Ready(a), RootState::Ready(b)) if a == b => Ok(RootCompatibility::SameRoot),
        (RootState::Ready(_), RootState::Ready(_)) => Err(PairingError::RootMismatch),
        (RootState::NeedsDecision, RootState::NeedsDecision) => Err(PairingError::BothRootless),
    }
}

impl PairingMessage {
    pub fn encode(&self) -> Result<Vec<u8>, PairingError> {
        let mut out = Vec::new();
        out.extend_from_slice(b"FIPA");
        out.extend_from_slice(&PAIRING_PROTOCOL_VERSION.to_be_bytes());
        match self {
            Self::Hello(value) => {
                out.push(1);
                encode_hello_fields(&mut out, value)?;
            }
            Self::Decision(value) => {
                out.push(2);
                field(&mut out, 1, &value.session_id.0)?;
                field(
                    &mut out,
                    2,
                    &[match value.kind {
                        PairingDecisionKind::Confirm => 1,
                        PairingDecisionKind::Reject => 2,
                    }],
                )?;
                field(&mut out, 3, &value.mac)?;
            }
            Self::Provision(value) => {
                out.push(3);
                field(&mut out, 1, &value.session_id.0)?;
                field(&mut out, 2, &value.payload)?;
                field(&mut out, 3, &value.mac)?;
            }
            Self::CommitAck { session_id, mac } => {
                out.push(4);
                field(&mut out, 1, &session_id.0)?;
                field(&mut out, 2, mac)?;
            }
        }
        if out.len() > MAX_MESSAGE_SIZE {
            return Err(PairingError::Malformed("message too large"));
        }
        Ok(out)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, PairingError> {
        if bytes.len() < 7 || bytes.len() > MAX_MESSAGE_SIZE || &bytes[..4] != b"FIPA" {
            return Err(PairingError::Malformed("invalid message framing"));
        }
        let version = u16::from_be_bytes([bytes[4], bytes[5]]);
        if version != PAIRING_PROTOCOL_VERSION {
            return Err(PairingError::UnsupportedVersion(version));
        }
        let fields = parse_fields(&bytes[7..])?;
        match bytes[6] {
            1 => Ok(Self::Hello(decode_hello_fields(&fields)?)),
            2 => {
                exact_tags(&fields, &[1, 2, 3])?;
                Ok(Self::Decision(PairingDecision {
                    session_id: PairingSessionId(array(field_value(&fields, 1)?)?),
                    kind: match field_value(&fields, 2)? {
                        [1] => PairingDecisionKind::Confirm,
                        [2] => PairingDecisionKind::Reject,
                        _ => return Err(PairingError::Malformed("invalid decision")),
                    },
                    mac: array(field_value(&fields, 3)?)?,
                }))
            }
            3 => {
                exact_tags(&fields, &[1, 2, 3])?;
                Ok(Self::Provision(ProvisioningEnvelope {
                    session_id: PairingSessionId(array(field_value(&fields, 1)?)?),
                    payload: field_value(&fields, 2)?.to_vec(),
                    mac: array(field_value(&fields, 3)?)?,
                }))
            }
            4 => {
                exact_tags(&fields, &[1, 2])?;
                Ok(Self::CommitAck {
                    session_id: PairingSessionId(array(field_value(&fields, 1)?)?),
                    mac: array(field_value(&fields, 2)?)?,
                })
            }
            _ => Err(PairingError::Malformed("unknown message type")),
        }
    }
}

fn validate_hello(value: &PairingHello, role: PairingRole) -> Result<(), PairingError> {
    if value.version != PAIRING_PROTOCOL_VERSION {
        return Err(PairingError::UnsupportedVersion(value.version));
    }
    if value.role != role {
        return Err(PairingError::Malformed("incorrect role ordering"));
    }
    if value.friendly_name.is_empty() || value.friendly_name.len() > MAX_FRIENDLY_NAME {
        return Err(PairingError::Malformed("invalid friendly name"));
    }
    Ok(())
}

fn encode_hello_fields(out: &mut Vec<u8>, h: &PairingHello) -> Result<(), PairingError> {
    if h.friendly_name.is_empty() || h.friendly_name.len() > MAX_FRIENDLY_NAME {
        return Err(PairingError::Malformed("invalid friendly name"));
    }
    field(out, 1, &h.version.to_be_bytes())?;
    field(out, 2, &[h.role.tag()])?;
    field(out, 3, h.instance_id.as_bytes())?;
    field(out, 4, h.public_key.as_bytes())?;
    field(out, 5, &h.nonce)?;
    field(out, 6, h.friendly_name.as_bytes())?;
    match h.root_state {
        RootState::NeedsDecision => field(out, 7, &[0]),
        RootState::Ready(root) => {
            let mut value = vec![1];
            value.extend_from_slice(root.to_string().as_bytes());
            field(out, 7, &value)
        }
    }
}

fn decode_hello_fields(fields: &[(u8, &[u8])]) -> Result<PairingHello, PairingError> {
    exact_tags(fields, &[1, 2, 3, 4, 5, 6, 7])?;
    let version = u16::from_be_bytes(array(field_value(fields, 1)?)?);
    if version != PAIRING_PROTOCOL_VERSION {
        return Err(PairingError::UnsupportedVersion(version));
    }
    let role = match field_value(fields, 2)? {
        [1] => PairingRole::Initiator,
        [2] => PairingRole::Responder,
        _ => return Err(PairingError::Malformed("invalid role")),
    };
    let friendly_name = std::str::from_utf8(field_value(fields, 6)?)
        .map_err(|_| PairingError::Malformed("name is not UTF-8"))?
        .to_owned();
    if friendly_name.is_empty() || friendly_name.len() > MAX_FRIENDLY_NAME {
        return Err(PairingError::Malformed("invalid friendly name"));
    }
    let root = field_value(fields, 7)?;
    let root_state = match root {
        [0] => RootState::NeedsDecision,
        [1, rest @ ..] => RootState::Ready(
            std::str::from_utf8(rest)
                .map_err(|_| PairingError::Malformed("root is not UTF-8"))?
                .parse()
                .map_err(|_| PairingError::Malformed("invalid root"))?,
        ),
        _ => return Err(PairingError::Malformed("invalid root state")),
    };
    Ok(PairingHello {
        version,
        role,
        instance_id: PairingInstanceId::from_bytes(array(field_value(fields, 3)?)?),
        public_key: PublicDeviceKey::from_bytes(array(field_value(fields, 4)?)?)
            .map_err(|_| PairingError::Malformed("invalid public key"))?,
        nonce: array(field_value(fields, 5)?)?,
        friendly_name,
        root_state,
    })
}

fn encode_provisioning(data: &ProvisioningData) -> Result<Vec<u8>, PairingError> {
    let mut out = Vec::new();
    field(&mut out, 1, data.root.to_string().as_bytes())?;
    field(&mut out, 2, data.discovery_secret.expose())?;
    field(&mut out, 3, &data.epoch.to_be_bytes())?;
    field(&mut out, 4, data.existing_device_id.as_bytes())?;
    field(&mut out, 5, data.existing_public_key.as_bytes())?;
    field(&mut out, 6, data.existing_name.as_bytes())?;
    field(&mut out, 7, &data.sync_port.to_be_bytes())?;
    Ok(out)
}
fn decode_provisioning(bytes: &[u8]) -> Result<ProvisioningData, PairingError> {
    let f = parse_fields(bytes)?;
    exact_tags(&f, &[1, 2, 3, 4, 5, 6, 7])?;
    let root = std::str::from_utf8(field_value(&f, 1)?)
        .map_err(|_| PairingError::Malformed("invalid root"))?
        .parse()
        .map_err(|_| PairingError::Malformed("invalid root"))?;
    let secret = DiscoveryGroupSecret::from_bytes(array(field_value(&f, 2)?)?);
    let epoch = u64::from_be_bytes(array(field_value(&f, 3)?)?);
    let device = DeviceId::from_public_key(&array(field_value(&f, 5)?)?);
    if device.as_bytes() != field_value(&f, 4)? {
        return Err(PairingError::Malformed("device ID/key mismatch"));
    }
    let key = PublicDeviceKey::from_bytes(array(field_value(&f, 5)?)?)
        .map_err(|_| PairingError::Malformed("invalid key"))?;
    let name = std::str::from_utf8(field_value(&f, 6)?)
        .map_err(|_| PairingError::Malformed("invalid name"))?
        .to_owned();
    let sync_port = u16::from_be_bytes(array(field_value(&f, 7)?)?);
    if sync_port == 0 {
        return Err(PairingError::Malformed("invalid sync port"));
    }
    Ok(ProvisioningData {
        root,
        discovery_secret: secret,
        epoch,
        existing_device_id: device,
        existing_public_key: key,
        existing_name: name,
        sync_port,
    })
}

fn field(out: &mut Vec<u8>, tag: u8, value: &[u8]) -> Result<(), PairingError> {
    let len = u16::try_from(value.len()).map_err(|_| PairingError::Malformed("field too large"))?;
    out.push(tag);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}
fn parse_fields(mut bytes: &[u8]) -> Result<Vec<(u8, &[u8])>, PairingError> {
    let mut out = Vec::new();
    let mut previous = 0;
    while !bytes.is_empty() {
        if bytes.len() < 3 {
            return Err(PairingError::Malformed("truncated field"));
        }
        let tag = bytes[0];
        if tag <= previous {
            return Err(PairingError::Malformed("fields are not canonical"));
        }
        let len = usize::from(u16::from_be_bytes([bytes[1], bytes[2]]));
        if bytes.len() < 3 + len {
            return Err(PairingError::Malformed("truncated field value"));
        }
        out.push((tag, &bytes[3..3 + len]));
        bytes = &bytes[3 + len..];
        previous = tag;
    }
    Ok(out)
}
fn exact_tags(fields: &[(u8, &[u8])], tags: &[u8]) -> Result<(), PairingError> {
    if fields.iter().map(|x| x.0).eq(tags.iter().copied()) {
        Ok(())
    } else {
        Err(PairingError::Malformed("unknown or missing field"))
    }
}
fn field_value<'a>(fields: &[(u8, &'a [u8])], tag: u8) -> Result<&'a [u8], PairingError> {
    fields
        .iter()
        .find(|x| x.0 == tag)
        .map(|x| x.1)
        .ok_or(PairingError::Malformed("missing field"))
}
fn array<const N: usize>(value: &[u8]) -> Result<[u8; N], PairingError> {
    value
        .try_into()
        .map_err(|_| PairingError::Malformed("invalid field size"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::PrivateDeviceKey;

    fn hello(role: PairingRole, seed: u8, root: RootState) -> PairingHello {
        let key = PrivateDeviceKey::from_seed(&[seed; 32])
            .unwrap()
            .public_key();
        PairingHello {
            version: 1,
            role,
            instance_id: PairingInstanceId::from_bytes([seed; 16]),
            public_key: key,
            nonce: [seed + 1; 32],
            friendly_name: format!("device-{seed}"),
            root_state: root,
        }
    }

    #[test]
    fn canonical_messages_reject_mutation_unknown_fields_and_versions() {
        let value =
            PairingMessage::Hello(hello(PairingRole::Initiator, 3, RootState::NeedsDecision));
        let encoded = value.encode().unwrap();
        assert_eq!(
            hex::encode(&encoded),
            include_str!("../fixtures/pairing-hello-v1.hex").trim()
        );
        assert_eq!(PairingMessage::decode(&encoded).unwrap(), value);
        let mut unknown = encoded.clone();
        unknown.extend_from_slice(&[99, 0, 0]);
        assert!(PairingMessage::decode(&unknown).is_err());
        let mut version = encoded;
        version[5] = 2;
        assert_eq!(
            PairingMessage::decode(&version),
            Err(PairingError::UnsupportedVersion(2))
        );
    }

    #[test]
    fn fixed_transcript_vector_and_both_roles_share_sas() {
        let root = DocumentId::new();
        let a = hello(PairingRole::Initiator, 3, RootState::Ready(root));
        let b = hello(PairingRole::Responder, 7, RootState::NeedsDecision);
        let transcript = canonical_transcript(&a, &b).unwrap();
        let keys_a = derive_pairing_keys(&transcript, &[9; 32]).unwrap();
        let keys_b = derive_pairing_keys(&transcript, &[9; 32]).unwrap();
        assert_eq!(keys_a.sas(), keys_b.sas());
        assert_eq!(keys_a.sas().len(), 6);
        let changed = derive_pairing_keys(&transcript, &[8; 32]).unwrap();
        assert_ne!(keys_a.sas_material, changed.sas_material);
        assert_ne!(hex::encode(Sha256::digest(&transcript)), "");

        let mut mutations = Vec::new();
        let mut changed = a.clone();
        changed.nonce[0] ^= 1;
        mutations.push(changed);
        let mut changed = a.clone();
        changed.instance_id = PairingInstanceId::from_bytes([99; 16]);
        mutations.push(changed);
        let mut changed = a.clone();
        changed.public_key = PrivateDeviceKey::from_seed(&[44; 32]).unwrap().public_key();
        mutations.push(changed);
        for changed in mutations {
            let changed_transcript = canonical_transcript(&changed, &b).unwrap();
            assert_ne!(
                Sha256::digest(&changed_transcript),
                Sha256::digest(&transcript)
            );
            assert_ne!(
                derive_pairing_keys(&changed_transcript, &[9; 32])
                    .unwrap()
                    .sas_material,
                keys_a.sas_material
            );
        }
    }

    #[test]
    fn confirmations_and_provisioning_are_session_and_deadline_bound() {
        let keys = derive_pairing_keys(b"transcript", &[9; 32]).unwrap();
        let session = PairingSessionId([1; 16]);
        let decision = sign_decision(
            &keys,
            PairingRole::Initiator,
            session,
            PairingDecisionKind::Confirm,
        );
        assert!(verify_decision(&keys, PairingRole::Initiator, session, &decision, 4, 5).is_ok());
        assert_eq!(
            verify_decision(&keys, PairingRole::Initiator, session, &decision, 5, 5),
            Err(PairingError::Expired)
        );
        assert!(
            verify_decision(
                &keys,
                PairingRole::Initiator,
                PairingSessionId([2; 16]),
                &decision,
                1,
                5
            )
            .is_err()
        );

        let key = PrivateDeviceKey::from_seed(&[4; 32]).unwrap().public_key();
        let data = ProvisioningData {
            root: DocumentId::new(),
            discovery_secret: DiscoveryGroupSecret::from_bytes([5; 32]),
            epoch: 1,
            existing_device_id: DeviceId::from_public_key(key.as_bytes()),
            existing_public_key: key,
            existing_name: "existing".into(),
            sync_port: 4400,
        };
        let envelope = protect_provisioning(&keys, session, &data).unwrap();
        assert_eq!(
            open_provisioning(&keys, session, &envelope, 1, 5).unwrap(),
            data
        );
        let mut modified = envelope;
        modified.payload[0] ^= 1;
        assert_eq!(
            open_provisioning(&keys, session, &modified, 1, 5),
            Err(PairingError::Authentication)
        );
    }

    #[test]
    fn root_policy_never_merges_different_roots() {
        let a = DocumentId::new();
        let b = DocumentId::new();
        assert_eq!(
            root_compatibility(&RootState::Ready(a), &RootState::NeedsDecision),
            Ok(RootCompatibility::ProvisionInitiatorToResponder)
        );
        assert_eq!(
            root_compatibility(&RootState::Ready(a), &RootState::Ready(b)),
            Err(PairingError::RootMismatch)
        );
        assert_eq!(
            root_compatibility(&RootState::NeedsDecision, &RootState::NeedsDecision),
            Err(PairingError::BothRootless)
        );
    }
}
