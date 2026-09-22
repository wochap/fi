//! Application-facing pairing/discovery lifecycle and durable trust control.

use std::{
    collections::{BTreeMap, HashMap},
    net::IpAddr,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use rand_core::{OsRng, RngCore};
use sha2::Digest;
use tokio::{
    sync::{broadcast, watch},
    task::JoinHandle,
};

use crate::{
    adapters::SqliteControlStore,
    control::{
        DiscoveryGroupMetadata, DiscoveryRotationJournal, DiscoveryRotationStage,
        PairingJournalRecord, PairingJournalStage, PeerTrustRecord, TrustState,
        TrustedDeviceRecord,
    },
    discovery::{
        AddressPolicy, DEFAULT_RECORD_TTL_MS, DiscoveryAdvertisement, DiscoveryEvent,
        DiscoveryGroupSecret, DiscoveryProvider, DiscoveryScope, PairingInstanceId,
        group_routing_token, group_service_selector, match_group_endpoint,
    },
    discovery_control::{
        DISCOVERY_UPDATE_SIZE, DiscoverySecretAck, DiscoverySecretUpdate, authorize_peer,
        decode_ack, decode_update, encode_ack, encode_update,
    },
    identity::{DeviceId, DeviceIdentity, PublicDeviceKey, SecureKeyStore},
    pairing::{
        PAIRING_PROTOCOL_VERSION, PairingCandidate, PairingDecisionKind, PairingError,
        PairingEvent, PairingHello, PairingInput, PairingKeys, PairingMessage, PairingRole,
        PairingSessionId, PairingState, ProvisioningData, RootCompatibility, RootState,
        canonical_transcript, derive_pairing_keys, open_provisioning, pairing_session_id,
        protect_provisioning, reduce_pairing, root_compatibility, sign_commit_ack, sign_decision,
        verify_commit_ack, verify_decision,
    },
    pairing_transport::{PairingConnection, PairingStream, PairingTransport},
};

struct ActivePairingSession {
    role: PairingRole,
    connection: PairingConnection,
    stream: tokio::sync::Mutex<PairingStream>,
    keys: PairingKeys,
    peer: PairingHello,
    compatibility: RootCompatibility,
    deadline_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingCommitPlan {
    pub session_id: PairingSessionId,
    pub peer_device_id: DeviceId,
    pub peer_public_key: PublicDeviceKey,
    pub peer_name: String,
    pub compatibility: RootCompatibility,
    pub peer_endpoint: std::net::SocketAddr,
    pub peer_root_state: RootState,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NormalDiscoveryEvent {
    Upsert {
        peer: DeviceId,
        address: std::net::SocketAddr,
        expires_at_ms: u64,
    },
}

#[derive(Clone)]
struct DiscoveryGroupState {
    active: DiscoveryGroupSecret,
    previous: Option<(DiscoveryGroupSecret, u64)>,
}

const DISCOVERY_ROTATION_RETENTION_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

/// Every live address resolved for one pairing instance, with per-address expiry.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct CandidateAddresses {
    /// Monotonic order of first observation; higher is newer.
    first_seen: u64,
    /// Service instance names that resolved to this instance (expiry is by name).
    names: std::collections::BTreeSet<String>,
    addresses: BTreeMap<std::net::SocketAddr, u64>,
}

/// Pairing candidates keyed on the per-window instance id, with a deterministic
/// choice among each instance's addresses and endpoint-keyed collapse across
/// instances.
///
/// One physical device produces a new instance id every time it re-arms pairing,
/// while its previous advertisement lingers in browser caches until TTL or
/// goodbye. Both resolve to the same `ip:port`, because the QUIC socket outlives
/// the window. The newer instance therefore owns the endpoint and the older one
/// loses it, so the device shows as one row.
#[derive(Debug, Default)]
struct CandidateTable {
    policy: AddressPolicy,
    by_instance: BTreeMap<PairingInstanceId, CandidateAddresses>,
    by_name: HashMap<String, PairingInstanceId>,
    sequence: u64,
}

impl CandidateTable {
    fn new(policy: AddressPolicy) -> Self {
        Self {
            policy,
            ..Self::default()
        }
    }

    /// Records one resolved address. Returns `false` when the address is not
    /// dialable from the local socket and was ignored.
    fn upsert(
        &mut self,
        instance: PairingInstanceId,
        instance_name: String,
        address: std::net::SocketAddr,
        expires_at_ms: u64,
    ) -> bool {
        if !self.policy.admits_peer_address(address.ip()) {
            return false;
        }
        self.sequence += 1;
        let sequence = self.sequence;
        let entry = self
            .by_instance
            .entry(instance)
            .or_insert_with(|| CandidateAddresses {
                first_seen: sequence,
                ..CandidateAddresses::default()
            });
        entry.addresses.insert(address, expires_at_ms);
        entry.names.insert(instance_name.clone());
        self.by_name.insert(instance_name, instance);
        // The newest instance that resolved to this endpoint owns it. Older ones
        // lose it, and a stale re-resolution of an older one does not steal it back.
        let owner = self
            .by_instance
            .iter()
            .filter(|(_, record)| record.addresses.contains_key(&address))
            .max_by_key(|(_, record)| record.first_seen)
            .map(|(other, _)| *other);
        for (other, record) in &mut self.by_instance {
            if Some(*other) != owner {
                record.addresses.remove(&address);
            }
        }
        true
    }

    fn expire_name(&mut self, instance_name: &str) {
        if let Some(instance) = self.by_name.remove(instance_name)
            && let Some(record) = self.by_instance.get_mut(&instance)
        {
            record.names.remove(instance_name);
            if record.names.is_empty() {
                self.by_instance.remove(&instance);
            }
        }
    }

    /// Drops expired addresses and instances with nothing left to dial.
    fn prune(&mut self, now_ms: u64) {
        self.by_instance.retain(|_, record| {
            record.addresses.retain(|_, expires| *expires > now_ms);
            !record.addresses.is_empty()
        });
        let live: std::collections::HashSet<_> = self.by_instance.keys().copied().collect();
        self.by_name.retain(|_, instance| live.contains(instance));
    }

    fn candidates(&self) -> Vec<PairingCandidate> {
        self.by_instance
            .iter()
            .filter_map(|(instance, record)| {
                let endpoint = AddressPolicy::select(record.addresses.keys().copied())?;
                Some(PairingCandidate {
                    instance_id: *instance,
                    endpoint,
                    expires_at_ms: record.addresses.values().copied().max().unwrap_or(0),
                })
            })
            .collect()
    }
}

pub struct PairingManager {
    identity: Arc<DeviceIdentity>,
    keys: Arc<dyn SecureKeyStore>,
    control: Arc<SqliteControlStore>,
    discovery: Arc<dyn DiscoveryProvider>,
    transport: Arc<PairingTransport>,
    state_tx: watch::Sender<PairingState>,
    candidates_tx: watch::Sender<Vec<PairingCandidate>>,
    events: broadcast::Sender<PairingEvent>,
    normal_events: broadcast::Sender<NormalDiscoveryEvent>,
    group_tx: watch::Sender<Option<DiscoveryGroupState>>,
    address_policy: AddressPolicy,
    normal_scope: Mutex<Option<DiscoveryScope>>,
    normal_port: Mutex<Option<u16>>,
    migration_scope: Mutex<Option<DiscoveryScope>>,
    deadline: Mutex<Option<JoinHandle<()>>>,
    accept_task: Mutex<Option<JoinHandle<()>>>,
    sessions: Mutex<HashMap<PairingSessionId, Arc<ActivePairingSession>>>,
    /// The root state advertised in every `Hello`. Read at handshake time, not
    /// captured when the window opens; `AppCore` updates it on every bootstrap
    /// transition through [`Self::set_root_state`].
    root_state: Mutex<RootState>,
    discovery_task: JoinHandle<()>,
}

impl std::fmt::Debug for PairingManager {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PairingManager")
            .field("device_id", &self.identity.id())
            .field("state", &self.state_tx.borrow().clone())
            .finish_non_exhaustive()
    }
}

impl PairingManager {
    pub fn new(
        identity: Arc<DeviceIdentity>,
        keys: Arc<dyn SecureKeyStore>,
        control: Arc<SqliteControlStore>,
        discovery: Arc<dyn DiscoveryProvider>,
        bind_ip: IpAddr,
    ) -> Result<Arc<Self>, PairingError> {
        let transport = Arc::new(PairingTransport::bind((bind_ip, 0).into(), &identity)?);
        let address_policy = AddressPolicy::for_bind(bind_ip);
        let (state_tx, _) = watch::channel(PairingState::Idle);
        let (candidates_tx, _) = watch::channel(Vec::new());
        let (events, _) = broadcast::channel(128);
        let (normal_events, _) = broadcast::channel(128);
        let (group_tx, group_rx) = watch::channel::<Option<DiscoveryGroupState>>(None);
        let mut discovered = discovery.subscribe();
        let own_state = state_tx.subscribe();
        let candidates = candidates_tx.clone();
        let control_for_discovery = control.clone();
        let normal_events_for_discovery = normal_events.clone();
        let discovery_task = tokio::spawn(async move {
            let mut table = CandidateTable::new(address_policy);
            while let Ok(event) = discovered.recv().await {
                match event {
                    DiscoveryEvent::Upsert(endpoint)
                        if endpoint.scope == DiscoveryScope::Pairing =>
                    {
                        let Some(instance) = endpoint
                            .properties
                            .get("i")
                            .and_then(|value| decode_instance(value))
                        else {
                            continue;
                        };
                        let own = match &*own_state.borrow() {
                            PairingState::Discoverable { instance_id, .. } => Some(*instance_id),
                            _ => None,
                        };
                        if own == Some(instance) {
                            continue;
                        }
                        if !table.upsert(
                            instance,
                            endpoint.instance_name,
                            endpoint.address,
                            endpoint.expires_at_ms,
                        ) {
                            tracing::debug!(
                                event = "pairing_candidate_rejected",
                                peer_instance = %instance,
                                endpoint = %endpoint.address,
                                "resolved address is not dialable from the local socket"
                            );
                        }
                    }
                    DiscoveryEvent::Expired {
                        scope: DiscoveryScope::Pairing,
                        instance_name,
                    } => {
                        table.expire_name(&instance_name);
                    }
                    DiscoveryEvent::Upsert(endpoint) => {
                        let Some(group) = group_rx.borrow().clone() else {
                            continue;
                        };
                        let trusted = control_for_discovery
                            .trusted_devices()
                            .unwrap_or_default()
                            .into_iter()
                            .filter(|record| record.state == TrustState::Trusted)
                            .map(|record| record.device_id);
                        let trusted: Vec<_> = trusted.collect();
                        let matched = match_group_endpoint(
                            &endpoint,
                            &group.active,
                            &address_policy,
                            trusted.iter().copied(),
                        )
                        .or_else(|| {
                            group.previous.as_ref().and_then(|(secret, _)| {
                                match_group_endpoint(
                                    &endpoint,
                                    secret,
                                    &address_policy,
                                    trusted.iter().copied(),
                                )
                            })
                        });
                        if let Some((peer, address, expires_at_ms)) = matched {
                            let _ =
                                normal_events_for_discovery.send(NormalDiscoveryEvent::Upsert {
                                    peer,
                                    address,
                                    expires_at_ms,
                                });
                        }
                    }
                    _ => {}
                }
                table.prune(now_ms());
                candidates.send_replace(table.candidates());
            }
        });
        Ok(Arc::new(Self {
            identity,
            keys,
            control,
            discovery,
            transport,
            state_tx,
            candidates_tx,
            events,
            normal_events,
            group_tx,
            address_policy,
            normal_scope: Mutex::new(None),
            normal_port: Mutex::new(None),
            migration_scope: Mutex::new(None),
            deadline: Mutex::new(None),
            accept_task: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            root_state: Mutex::new(RootState::NeedsDecision),
            discovery_task,
        }))
    }

    /// Replaces the root state a subsequent handshake advertises. The single
    /// update point for every bootstrap transition.
    pub fn set_root_state(&self, state: RootState) {
        if let Ok(mut current) = self.root_state.lock()
            && *current != state
        {
            tracing::info!(
                event = "pairing_root_state",
                ready = matches!(state, RootState::Ready(_)),
                "pairing root state updated"
            );
            *current = state;
        }
    }

    /// The root state a handshake started now would advertise.
    #[must_use]
    pub fn root_state(&self) -> RootState {
        self.root_state
            .lock()
            .map(|state| state.clone())
            .unwrap_or(RootState::NeedsDecision)
    }

    #[must_use]
    pub fn state(&self) -> PairingState {
        self.state_tx.borrow().clone()
    }
    #[must_use]
    pub fn candidates(&self) -> Vec<PairingCandidate> {
        self.candidates_tx.borrow().clone()
    }
    #[must_use]
    pub fn subscribe_state(&self) -> watch::Receiver<PairingState> {
        self.state_tx.subscribe()
    }
    #[must_use]
    pub fn subscribe_candidates(&self) -> watch::Receiver<Vec<PairingCandidate>> {
        self.candidates_tx.subscribe()
    }
    #[must_use]
    pub fn subscribe_events(&self) -> broadcast::Receiver<PairingEvent> {
        self.events.subscribe()
    }
    pub async fn discovery_secret(&self) -> Result<Option<DiscoveryGroupSecret>, PairingError> {
        self.keys
            .load_discovery_group_secret()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))
    }
    #[must_use]
    pub fn subscribe_normal_discovery(&self) -> broadcast::Receiver<NormalDiscoveryEvent> {
        self.normal_events.subscribe()
    }
    /// Which peer addresses this manager will dial, derived from its bind address.
    #[must_use]
    pub const fn address_policy(&self) -> AddressPolicy {
        self.address_policy
    }
    pub fn local_addr(&self) -> Result<std::net::SocketAddr, PairingError> {
        self.transport.local_addr()
    }

    pub async fn start(
        self: &Arc<Self>,
        duration: Duration,
        friendly_name: String,
    ) -> Result<PairingInstanceId, PairingError> {
        if duration.is_zero() {
            return Err(PairingError::InvalidTransition);
        }
        if !matches!(
            self.state(),
            PairingState::Idle | PairingState::Failed { .. } | PairingState::Trusted { .. }
        ) {
            return Err(PairingError::InvalidTransition);
        }
        let mut instance = [0; 16];
        OsRng.fill_bytes(&mut instance);
        let instance = PairingInstanceId::from_bytes(instance);
        let mut name = [0; 12];
        OsRng.fill_bytes(&mut name);
        let name = hex::encode(name);
        let deadline_ms =
            now_ms().saturating_add(duration.as_millis().try_into().unwrap_or(u64::MAX));
        self.transport.start();
        let port = self.transport.local_addr()?.port();
        self.discovery
            .start(DiscoveryAdvertisement::pairing(
                instance,
                name,
                port,
                DEFAULT_RECORD_TTL_MS.min(duration.as_millis().try_into().unwrap_or(u64::MAX)),
            ))
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.apply(PairingInput::Start {
            instance_id: instance,
            deadline_ms,
        })?;
        let weak = Arc::downgrade(self);
        self.cancel_deadline();
        *self
            .deadline
            .lock()
            .map_err(|_| PairingError::Transport("deadline lock poisoned".into()))? =
            Some(tokio::spawn(async move {
                tokio::time::sleep(duration).await;
                if let Some(manager) = weak.upgrade() {
                    let _ = manager.timeout().await;
                }
            }));
        self.cancel_accept();
        let manager = self.clone();
        *self
            .accept_task
            .lock()
            .map_err(|_| PairingError::Transport("accept lock poisoned".into()))? =
            Some(tokio::spawn(async move {
                manager.accept_loop(duration, friendly_name).await;
            }));
        Ok(instance)
    }

    /// Accepts inbound pairing connections for the lifetime of the window.
    ///
    /// An inbound connection that cannot be taken right now — the device is
    /// already connecting, confirming, or committing — is refused on its own
    /// connection and the loop keeps listening. The local window, candidate
    /// list, and any in-flight outbound attempt are untouched. Only a failure
    /// inside an accepted handshake ends the local attempt.
    async fn accept_loop(self: Arc<Self>, window: Duration, friendly_name: String) {
        let deadline = tokio::time::sleep(window);
        tokio::pin!(deadline);
        loop {
            if !self.state_is_active() {
                return;
            }
            let connection = tokio::select! {
                () = &mut deadline => return,
                accepted = self.transport.accept() => match accepted {
                    Ok(connection) => connection,
                    Err(error) => {
                        tracing::warn!(
                            event = "pairing_accept_error",
                            error = %error,
                            "pairing listener failed to accept"
                        );
                        return;
                    }
                },
            };
            tracing::info!(
                event = "pairing_accept",
                remote = %connection.remote_address(),
                "accepted inbound pairing connection"
            );
            match self
                .accept_handshake(connection.clone(), friendly_name.clone())
                .await
            {
                Ok(_) => {}
                Err(PairingError::Busy) => {
                    tracing::info!(
                        event = "pairing_refuse",
                        remote = %connection.remote_address(),
                        "refused inbound pairing connection while busy"
                    );
                    connection.refuse();
                }
                Err(PairingError::Inactive) => {
                    connection.close();
                    return;
                }
                Err(error) => {
                    self.fail(error).await;
                    return;
                }
            }
        }
    }

    pub async fn stop(&self) -> Result<(), PairingError> {
        if let Some(task) = self
            .deadline
            .lock()
            .map_err(|_| PairingError::Transport("deadline lock poisoned".into()))?
            .take()
        {
            task.abort();
        }
        let _ = self.discovery.stop(&DiscoveryScope::Pairing).await;
        self.transport.stop();
        self.clear_sessions();
        self.candidates_tx.send_replace(Vec::new());
        self.apply(PairingInput::Stop)?;
        Ok(())
    }

    async fn timeout(&self) -> Result<(), PairingError> {
        let _ = self.discovery.stop(&DiscoveryScope::Pairing).await;
        self.transport.stop();
        self.clear_sessions();
        self.candidates_tx.send_replace(Vec::new());
        self.apply(PairingInput::Timeout { now_ms: now_ms() })?;
        Ok(())
    }

    pub fn select(
        &self,
        candidate: PairingCandidate,
        duration: Duration,
    ) -> Result<PairingSessionId, PairingError> {
        if candidate.expires_at_ms <= now_ms() {
            return Err(PairingError::Expired);
        }
        let mut id = [0; 16];
        OsRng.fill_bytes(&mut id);
        let session_id = PairingSessionId(id);
        let deadline_ms =
            now_ms().saturating_add(duration.as_millis().try_into().unwrap_or(u64::MAX));
        self.apply(PairingInput::Select {
            session_id,
            candidate,
            deadline_ms,
        })?;
        Ok(session_id)
    }

    pub fn sas_ready(
        &self,
        session_id: PairingSessionId,
        sas: crate::pairing::SasCode,
        deadline_ms: u64,
    ) -> Result<(), PairingError> {
        self.apply(PairingInput::SasReady {
            session_id,
            sas,
            deadline_ms,
        })
        .map(|_| ())
    }
    pub async fn connect(
        &self,
        candidate: PairingCandidate,
        friendly_name: String,
        duration: Duration,
    ) -> Result<PairingSessionId, PairingError> {
        let result = self.connect_inner(candidate, friendly_name, duration).await;
        match &result {
            Ok(_) => {}
            // The peer refused because it was busy. That is the peer's session,
            // not a local failure: return to discoverable so the user can retry
            // without restarting pairing.
            Err(PairingError::PeerBusy) => self.release(),
            // The local device already holds a session (an inbound landed
            // first, or an earlier select is in flight). Leave it alone.
            Err(PairingError::Busy) => {}
            Err(error) => self.fail(error.clone()).await,
        }
        result
    }

    fn release(&self) {
        if let PairingState::Connecting { session_id, .. } = self.state() {
            tracing::info!(
                event = "pairing_released",
                "peer was busy; returning to discoverable"
            );
            let _ = self.apply(PairingInput::Release { session_id });
        }
    }

    async fn connect_inner(
        &self,
        candidate: PairingCandidate,
        friendly_name: String,
        duration: Duration,
    ) -> Result<PairingSessionId, PairingError> {
        let (local_instance, window_deadline) = self.discoverable_window()?;
        let session_id = pairing_session_id(local_instance, candidate.instance_id);
        let deadline_ms = now_ms()
            .saturating_add(duration.as_millis().try_into().unwrap_or(u64::MAX))
            .min(window_deadline);
        self.apply(PairingInput::Select {
            session_id,
            candidate: candidate.clone(),
            deadline_ms,
        })?;
        tracing::info!(
            event = "pairing_dial",
            peer_instance = %candidate.instance_id,
            endpoint = %candidate.endpoint,
            "dialing pairing candidate"
        );
        let connection = self.transport.connect(candidate.endpoint).await?;
        let hello = make_hello(
            PairingRole::Initiator,
            local_instance,
            self.identity.public_key(),
            friendly_name,
            self.root_state(),
        );
        // A peer that is busy closes the connection with a distinct code; a
        // stream error observed after that close is a refusal, not a failure.
        let refused = |error: PairingError| connection.peer_refusal().unwrap_or(error);
        let mut stream = connection.open_stream().await.map_err(refused)?;
        stream
            .send(&PairingMessage::Hello(hello.clone()))
            .await
            .map_err(refused)?;
        let PairingMessage::Hello(peer) = stream.receive().await.map_err(refused)? else {
            return Err(PairingError::Malformed("hello required"));
        };
        self.finish_handshake(session_id, connection, stream, hello, peer)
            .await?;
        Ok(session_id)
    }

    pub async fn confirm(
        &self,
        session_id: PairingSessionId,
    ) -> Result<PairingCommitPlan, PairingError> {
        let result = self.confirm_inner(session_id).await;
        if let Err(error) = &result {
            self.fail(error.clone()).await;
        }
        result
    }

    async fn confirm_inner(
        &self,
        session_id: PairingSessionId,
    ) -> Result<PairingCommitPlan, PairingError> {
        let session = self.session(session_id)?;
        self.apply(PairingInput::LocalConfirm { session_id })?;
        let decision = sign_decision(
            &session.keys,
            session.role,
            session_id,
            PairingDecisionKind::Confirm,
        );
        let mut stream = session.stream.lock().await;
        stream.send(&PairingMessage::Decision(decision)).await?;
        let remaining = session.deadline_ms.saturating_sub(now_ms());
        let message = tokio::time::timeout(Duration::from_millis(remaining), stream.receive())
            .await
            .map_err(|_| PairingError::Expired)??;
        let PairingMessage::Decision(remote) = message else {
            return Err(PairingError::Malformed("decision required"));
        };
        let remote_role = match session.role {
            PairingRole::Initiator => PairingRole::Responder,
            PairingRole::Responder => PairingRole::Initiator,
        };
        verify_decision(
            &session.keys,
            remote_role,
            session_id,
            &remote,
            now_ms(),
            session.deadline_ms,
        )?;
        if remote.kind == PairingDecisionKind::Reject {
            drop(stream);
            self.apply(PairingInput::Reject {
                session_id: Some(session_id),
            })?;
            self.stop_transient().await;
            return Err(PairingError::Rejected);
        }
        drop(stream);
        self.apply(PairingInput::RemoteConfirm { session_id })?;
        let peer_device_id = DeviceId::from_public_key(session.peer.public_key.as_bytes());
        self.apply(PairingInput::BeginCommit {
            session_id,
            peer: peer_device_id,
            deadline_ms: session.deadline_ms,
        })?;
        Ok(PairingCommitPlan {
            session_id,
            peer_device_id,
            peer_public_key: session.peer.public_key,
            peer_name: session.peer.friendly_name.clone(),
            compatibility: session.compatibility,
            peer_endpoint: session.connection.remote_address(),
            peer_root_state: session.peer.root_state.clone(),
        })
    }
    pub fn remote_confirm(&self, session_id: PairingSessionId) -> Result<(), PairingError> {
        self.apply(PairingInput::RemoteConfirm { session_id })
            .map(|_| ())
    }
    pub async fn reject(
        self: &Arc<Self>,
        session_id: Option<PairingSessionId>,
    ) -> Result<(), PairingError> {
        if let Some(session_id) = session_id
            && let Ok(session) = self.session(session_id)
        {
            let decision = sign_decision(
                &session.keys,
                session.role,
                session_id,
                PairingDecisionKind::Reject,
            );
            let mut stream = session.stream.lock().await;
            let _ = stream.send(&PairingMessage::Decision(decision)).await;
            let _ = stream.finish();
        }
        self.apply(PairingInput::Reject { session_id })?;
        self.cancel_deadline();
        let _ = self.discovery.stop(&DiscoveryScope::Pairing).await;
        self.transport.deactivate_listener();
        self.candidates_tx.send_replace(Vec::new());
        if let Some(session_id) = session_id
            && let Ok(mut sessions) = self.sessions.lock()
        {
            sessions.remove(&session_id);
        }
        Ok(())
    }

    fn apply(&self, input: PairingInput) -> Result<PairingEvent, PairingError> {
        let (state, event) = reduce_pairing(&self.state(), input)?;
        tracing::info!(
            event = "pairing_state",
            device_id = %self.identity.id(),
            state = pairing_state_name(&state),
            "pairing state transition"
        );
        self.state_tx.send_replace(state);
        let _ = self.events.send(event.clone());
        Ok(event)
    }

    async fn stop_transient(&self) {
        self.cancel_deadline();
        let _ = self.discovery.stop(&DiscoveryScope::Pairing).await;
        self.transport.stop();
        self.clear_sessions();
        self.candidates_tx.send_replace(Vec::new());
    }

    async fn fail(&self, error: PairingError) {
        tracing::warn!(event = "pairing_fail", error = %error, "pairing failed");
        let _ = self.apply(PairingInput::Fail(error));
        self.stop_transient().await;
    }

    pub async fn ensure_discovery_secret(
        &self,
        ready: bool,
    ) -> Result<(DiscoveryGroupSecret, DiscoveryGroupMetadata), PairingError> {
        if !ready {
            return Err(PairingError::InvalidTransition);
        }
        if let Some(secret) = self
            .keys
            .load_discovery_group_secret()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?
        {
            let metadata = self
                .control
                .discovery_metadata()
                .map_err(|error| PairingError::Transport(error.to_string()))?
                .ok_or(PairingError::Malformed("secret metadata missing"))?;
            self.group_tx.send_replace(Some(DiscoveryGroupState {
                active: secret.clone(),
                previous: None,
            }));
            return Ok((secret, metadata));
        }
        let mut bytes = [0; 32];
        OsRng.fill_bytes(&mut bytes);
        let secret = DiscoveryGroupSecret::from_bytes(bytes);
        self.keys
            .store_discovery_group_secret(&secret)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let metadata = DiscoveryGroupMetadata {
            epoch: 1,
            updated_at_ms: now_ms(),
        };
        self.control
            .store_discovery_metadata(metadata)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.group_tx.send_replace(Some(DiscoveryGroupState {
            active: secret.clone(),
            previous: None,
        }));
        Ok((secret, metadata))
    }

    pub async fn install_discovery_secret(
        &self,
        secret: &DiscoveryGroupSecret,
        metadata: DiscoveryGroupMetadata,
    ) -> Result<(), PairingError> {
        let current = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        if let Some(current) = current {
            if metadata.epoch < current.epoch {
                return Ok(());
            }
            if metadata.epoch == current.epoch {
                return Ok(());
            }
        }
        let previous = if let Some(current) = current {
            let previous = self
                .keys
                .load_discovery_group_secret()
                .await
                .map_err(|error| PairingError::Transport(error.to_string()))?
                .ok_or(PairingError::Malformed("discovery secret missing"))?;
            self.keys
                .store_previous_discovery_group_secret(current.epoch, &previous)
                .await
                .map_err(|error| PairingError::Transport(error.to_string()))?;
            self.control
                .store_discovery_rotation(DiscoveryRotationJournal {
                    previous_epoch: current.epoch,
                    target_epoch: metadata.epoch,
                    retain_until_ms: now_ms().saturating_add(DISCOVERY_ROTATION_RETENTION_MS),
                    stage: DiscoveryRotationStage::Active,
                    updated_at_ms: metadata.updated_at_ms,
                })
                .map_err(|error| PairingError::Transport(error.to_string()))?;
            Some((previous, current.epoch))
        } else {
            None
        };
        let active_port = *self
            .normal_port
            .lock()
            .map_err(|_| PairingError::Transport("normal discovery lock poisoned".into()))?;
        self.keys
            .store_discovery_group_secret(secret)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.control
            .store_discovery_metadata(metadata)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.group_tx.send_replace(Some(DiscoveryGroupState {
            active: secret.clone(),
            previous,
        }));
        if let Some(port) = active_port {
            self.stop_normal_discovery().await?;
            self.start_normal_discovery(port).await?;
        }
        Ok(())
    }

    pub async fn start_normal_discovery(&self, port: u16) -> Result<bool, PairingError> {
        if self
            .normal_scope
            .lock()
            .map_err(|_| PairingError::Transport("normal discovery lock poisoned".into()))?
            .is_some()
        {
            return Ok(true);
        }
        let Some(secret) = self
            .keys
            .load_discovery_group_secret()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?
        else {
            return Ok(false);
        };
        // A secret with no epoch row is an orphan: the key store is host-scoped
        // while the metadata is dataset-scoped, so a fresh or reset data
        // directory can meet a secret left by another dataset on this host.
        // That is "not in a group", not a malformed store.
        let Some(mut metadata) = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?
        else {
            tracing::warn!(
                event = "discovery_secret_orphaned",
                "discovery secret present without group metadata; treating as not in a group"
            );
            return Ok(false);
        };
        let journal = self
            .control
            .discovery_rotation()
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        if let Some(journal) = journal
            && journal.stage == DiscoveryRotationStage::Prepared
            && journal.target_epoch > metadata.epoch
        {
            metadata = DiscoveryGroupMetadata {
                epoch: journal.target_epoch,
                updated_at_ms: journal.updated_at_ms,
            };
            self.control
                .store_discovery_metadata(metadata)
                .map_err(|error| PairingError::Transport(error.to_string()))?;
            self.control
                .store_discovery_rotation(DiscoveryRotationJournal {
                    stage: DiscoveryRotationStage::Active,
                    ..journal
                })
                .map_err(|error| PairingError::Transport(error.to_string()))?;
        }
        let selector = group_service_selector(&secret, metadata.epoch);
        let route = group_routing_token(&secret, metadata.epoch, self.identity.id());
        let mut name = [0; 12];
        OsRng.fill_bytes(&mut name);
        let scope = DiscoveryScope::Group {
            epoch: metadata.epoch,
            selector: selector.clone(),
        };
        self.discovery
            .start(DiscoveryAdvertisement::group(
                selector,
                metadata.epoch,
                route,
                hex::encode(name),
                port,
                DEFAULT_RECORD_TTL_MS,
            ))
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        *self
            .normal_scope
            .lock()
            .map_err(|_| PairingError::Transport("normal discovery lock poisoned".into()))? =
            Some(scope);
        *self
            .normal_port
            .lock()
            .map_err(|_| PairingError::Transport("normal discovery lock poisoned".into()))? =
            Some(port);
        let previous = if let Some(journal) = self
            .control
            .discovery_rotation()
            .map_err(|error| PairingError::Transport(error.to_string()))?
            && journal.stage == DiscoveryRotationStage::Active
            && journal.retain_until_ms > now_ms()
        {
            self.keys
                .load_previous_discovery_group_secret()
                .await
                .map_err(|error| PairingError::Transport(error.to_string()))?
                .filter(|(epoch, _)| *epoch == journal.previous_epoch)
                .map(|(epoch, secret)| (secret, epoch))
        } else {
            self.keys
                .remove_previous_discovery_group_secret()
                .await
                .map_err(|error| PairingError::Transport(error.to_string()))?;
            self.control
                .clear_discovery_rotation()
                .map_err(|error| PairingError::Transport(error.to_string()))?;
            None
        };
        if let Some((previous_secret, previous_epoch)) = previous.as_ref() {
            let migration = DiscoveryScope::Group {
                epoch: *previous_epoch,
                selector: group_service_selector(previous_secret, *previous_epoch),
            };
            self.discovery
                .start_browse(migration.clone())
                .await
                .map_err(|error| PairingError::Transport(error.to_string()))?;
            *self.migration_scope.lock().map_err(|_| {
                PairingError::Transport("migration discovery lock poisoned".into())
            })? = Some(migration);
        }
        self.group_tx.send_replace(Some(DiscoveryGroupState {
            active: secret,
            previous,
        }));
        Ok(true)
    }

    pub async fn stop_normal_discovery(&self) -> Result<(), PairingError> {
        *self
            .normal_port
            .lock()
            .map_err(|_| PairingError::Transport("normal discovery lock poisoned".into()))? = None;
        let normal = self
            .normal_scope
            .lock()
            .map_err(|_| PairingError::Transport("normal discovery lock poisoned".into()))?
            .take();
        let migration = self
            .migration_scope
            .lock()
            .map_err(|_| PairingError::Transport("migration discovery lock poisoned".into()))?
            .take();
        if let Some(scope) = normal {
            let _ = self.discovery.stop(&scope).await;
        }
        if let Some(scope) = migration {
            let _ = self.discovery.stop(&scope).await;
        }
        Ok(())
    }

    pub async fn rotate_discovery_secret(
        &self,
        port: u16,
        now: u64,
        retention_ms: u64,
    ) -> Result<u64, PairingError> {
        let previous = self
            .keys
            .load_discovery_group_secret()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("discovery secret missing"))?;
        let current = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("secret metadata missing"))?;
        let target_epoch = current
            .epoch
            .checked_add(1)
            .ok_or(PairingError::Malformed("discovery epoch exhausted"))?;
        self.keys
            .store_previous_discovery_group_secret(current.epoch, &previous)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let journal = DiscoveryRotationJournal {
            previous_epoch: current.epoch,
            target_epoch,
            retain_until_ms: now.saturating_add(retention_ms),
            stage: DiscoveryRotationStage::Prepared,
            updated_at_ms: now,
        };
        self.control
            .store_discovery_rotation(journal)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let mut bytes = [0; 32];
        OsRng.fill_bytes(&mut bytes);
        let next = DiscoveryGroupSecret::from_bytes(bytes);
        self.keys
            .store_discovery_group_secret(&next)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.control
            .store_discovery_metadata(DiscoveryGroupMetadata {
                epoch: target_epoch,
                updated_at_ms: now,
            })
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.control
            .store_discovery_rotation(DiscoveryRotationJournal {
                stage: DiscoveryRotationStage::Active,
                ..journal
            })
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.stop_normal_discovery().await?;
        self.start_normal_discovery(port).await?;
        Ok(target_epoch)
    }

    pub fn rotation_update_frames(
        &self,
    ) -> Result<Vec<(DeviceId, [u8; DISCOVERY_UPDATE_SIZE])>, PairingError> {
        let group = self
            .group_tx
            .borrow()
            .clone()
            .ok_or(PairingError::Malformed("discovery group is inactive"))?;
        let (previous, _) = group
            .previous
            .as_ref()
            .ok_or(PairingError::Malformed("rotation migration is inactive"))?;
        let update = DiscoverySecretUpdate::new(
            self.control
                .discovery_metadata()
                .map_err(|error| PairingError::Transport(error.to_string()))?
                .ok_or(PairingError::Malformed("secret metadata missing"))?
                .epoch,
            &group.active,
        );
        let frame = encode_update(&update, previous);
        Ok(self
            .control
            .trusted_devices()
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .into_iter()
            .filter(|record| record.state == TrustState::Trusted)
            .map(|record| (record.device_id, frame))
            .collect())
    }

    pub async fn accept_rotation_update(
        &self,
        peer: DeviceId,
        frame: &[u8],
    ) -> Result<Vec<u8>, PairingError> {
        authorize_peer(&self.control, peer).map_err(|_| PairingError::Authentication)?;
        let current_secret = self
            .keys
            .load_discovery_group_secret()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("discovery secret missing"))?;
        let update = match decode_update(frame, &current_secret) {
            Ok(update) => update,
            Err(_) => {
                let (_, previous) = self
                    .keys
                    .load_previous_discovery_group_secret()
                    .await
                    .map_err(|error| PairingError::Transport(error.to_string()))?
                    .ok_or(PairingError::Authentication)?;
                decode_update(frame, &previous).map_err(|_| PairingError::Authentication)?
            }
        };
        let current_epoch = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("secret metadata missing"))?
            .epoch;
        if update.epoch > current_epoch {
            let next = update.secret();
            self.install_discovery_secret(
                &next,
                DiscoveryGroupMetadata {
                    epoch: update.epoch,
                    updated_at_ms: now_ms(),
                },
            )
            .await?;
            Ok(encode_ack(
                DiscoverySecretAck {
                    epoch: update.epoch,
                },
                &next,
            )
            .to_vec())
        } else {
            Ok(encode_ack(
                DiscoverySecretAck {
                    epoch: current_epoch,
                },
                &current_secret,
            )
            .to_vec())
        }
    }

    pub async fn validate_rotation_ack(&self, frame: &[u8]) -> Result<u64, PairingError> {
        let secret = self
            .keys
            .load_discovery_group_secret()
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("discovery secret missing"))?;
        let ack = decode_ack(frame, &secret).map_err(|_| PairingError::Authentication)?;
        let epoch = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("secret metadata missing"))?
            .epoch;
        if ack.epoch != epoch {
            return Err(PairingError::Authentication);
        }
        Ok(epoch)
    }

    pub fn journal(
        &self,
        plan: &PairingCommitPlan,
        stage: PairingJournalStage,
        joining_root: Option<String>,
    ) -> Result<(), PairingError> {
        self.control
            .store_pairing_journal(&PairingJournalRecord {
                session_id: plan.session_id.0,
                peer_device_id: plan.peer_device_id,
                stage,
                joining_root,
                updated_at_ms: now_ms(),
            })
            .map_err(|error| PairingError::Transport(error.to_string()))
    }

    pub fn establish_trust(
        &self,
        peer_key: PublicDeviceKey,
        name: String,
        now: u64,
    ) -> Result<TrustedDeviceRecord, PairingError> {
        let device_id = DeviceId::from_public_key(peer_key.as_bytes());
        let record = TrustedDeviceRecord {
            device_id,
            public_key: peer_key,
            friendly_name: name,
            paired_at_ms: now,
            last_seen_ms: Some(now),
            last_sync_ms: None,
            state: TrustState::Trusted,
        };
        self.control
            .upsert_trusted_device(&record)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.control
            .upsert_peer_trust(&PeerTrustRecord {
                device_id,
                public_key: peer_key,
                state: TrustState::Trusted,
                updated_at_ms: now,
                last_seen_ms: Some(now),
            })
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        Ok(record)
    }

    pub fn finish_trust(
        &self,
        plan: &PairingCommitPlan,
        now: u64,
    ) -> Result<TrustedDeviceRecord, PairingError> {
        let record = self.establish_trust(plan.peer_public_key, plan.peer_name.clone(), now)?;
        self.apply(PairingInput::CommitComplete {
            session_id: plan.session_id,
            peer: plan.peer_device_id,
        })?;
        if let Ok(mut sessions) = self.sessions.lock()
            && let Some(session) = sessions.remove(&plan.session_id)
        {
            session.connection.close();
        }
        self.cancel_deadline();
        self.transport.deactivate_listener();
        self.candidates_tx.send_replace(Vec::new());
        let discovery = self.discovery.clone();
        tokio::spawn(async move {
            let _ = discovery.stop(&DiscoveryScope::Pairing).await;
        });
        Ok(record)
    }

    pub fn local_is_provisioner(&self, plan: &PairingCommitPlan) -> Result<bool, PairingError> {
        let role = self.session(plan.session_id)?.role;
        Ok(matches!(
            (role, plan.compatibility),
            (
                PairingRole::Initiator,
                RootCompatibility::ProvisionInitiatorToResponder
            ) | (
                PairingRole::Responder,
                RootCompatibility::ProvisionResponderToInitiator
            )
        ))
    }

    pub async fn send_provisioning(
        &self,
        plan: &PairingCommitPlan,
        data: &ProvisioningData,
    ) -> Result<(), PairingError> {
        let session = self.session(plan.session_id)?;
        let envelope = protect_provisioning(&session.keys, plan.session_id, data)?;
        let mut stream = session.stream.lock().await;
        stream.send(&PairingMessage::Provision(envelope)).await?;
        let remaining = session.deadline_ms.saturating_sub(now_ms());
        let message = tokio::time::timeout(Duration::from_millis(remaining), stream.receive())
            .await
            .map_err(|_| PairingError::Expired)??;
        let PairingMessage::CommitAck { session_id, mac } = message else {
            return Err(PairingError::Malformed("commit acknowledgement required"));
        };
        if session_id != plan.session_id {
            return Err(PairingError::Authentication);
        }
        verify_commit_ack(&session.keys, session_id, &mac)
    }

    pub async fn receive_provisioning(
        &self,
        plan: &PairingCommitPlan,
    ) -> Result<ProvisioningData, PairingError> {
        let session = self.session(plan.session_id)?;
        let mut stream = session.stream.lock().await;
        let remaining = session.deadline_ms.saturating_sub(now_ms());
        let message = tokio::time::timeout(Duration::from_millis(remaining), stream.receive())
            .await
            .map_err(|_| PairingError::Expired)??;
        let PairingMessage::Provision(envelope) = message else {
            return Err(PairingError::Malformed("provisioning envelope required"));
        };
        open_provisioning(
            &session.keys,
            plan.session_id,
            &envelope,
            now_ms(),
            session.deadline_ms,
        )
    }

    pub async fn acknowledge_provisioning(
        &self,
        plan: &PairingCommitPlan,
    ) -> Result<(), PairingError> {
        let session = self.session(plan.session_id)?;
        let mac = sign_commit_ack(&session.keys, plan.session_id);
        session
            .stream
            .lock()
            .await
            .send(&PairingMessage::CommitAck {
                session_id: plan.session_id,
                mac,
            })
            .await
    }

    pub fn trusted_devices(&self) -> Result<Vec<TrustedDeviceRecord>, PairingError> {
        self.control
            .trusted_devices()
            .map_err(|error| PairingError::Transport(error.to_string()))
    }
    pub fn rename(&self, peer: DeviceId, name: &str) -> Result<bool, PairingError> {
        self.control
            .rename_trusted_device(peer, name)
            .map_err(|error| PairingError::Transport(error.to_string()))
    }
    pub fn revoke(&self, peer: DeviceId, now: u64) -> Result<bool, PairingError> {
        self.control
            .revoke_trusted_device(peer, now)
            .map_err(|error| PairingError::Transport(error.to_string()))
    }

    fn state_is_active(&self) -> bool {
        matches!(
            self.state(),
            PairingState::Discoverable { .. }
                | PairingState::Connecting { .. }
                | PairingState::AwaitingConfirmation { .. }
                | PairingState::Committing { .. }
        )
    }

    fn clear_sessions(&self) {
        if let Ok(mut sessions) = self.sessions.lock() {
            for (_, session) in sessions.drain() {
                session.connection.close();
            }
        }
        self.cancel_accept();
    }

    fn cancel_accept(&self) {
        if let Ok(mut task) = self.accept_task.lock()
            && let Some(task) = task.take()
        {
            task.abort();
        }
    }

    fn cancel_deadline(&self) {
        if let Ok(mut deadline) = self.deadline.lock()
            && let Some(task) = deadline.take()
        {
            task.abort();
        }
    }

    fn session(&self, id: PairingSessionId) -> Result<Arc<ActivePairingSession>, PairingError> {
        self.sessions
            .lock()
            .map_err(|_| PairingError::Transport("session lock poisoned".into()))?
            .get(&id)
            .cloned()
            .ok_or(PairingError::Inactive)
    }

    /// Runs the responder side of a handshake on an accepted connection.
    ///
    /// Returns `Busy` when the device already holds a session (connecting,
    /// awaiting confirmation, or committing) and `Inactive` when no window is
    /// open. Neither is a failure of the local attempt; the caller refuses or
    /// drops the connection and decides whether to keep listening.
    async fn accept_handshake(
        &self,
        connection: PairingConnection,
        friendly_name: String,
    ) -> Result<PairingSessionId, PairingError> {
        let (local_instance, window_deadline) = self.discoverable_window()?;
        let mut stream = connection.accept_stream().await?;
        let PairingMessage::Hello(peer) = stream.receive().await? else {
            return Err(PairingError::Malformed("hello required"));
        };
        let candidate = PairingCandidate {
            instance_id: peer.instance_id,
            endpoint: connection.remote_address(),
            expires_at_ms: window_deadline,
        };
        let session_id = pairing_session_id(peer.instance_id, local_instance);
        // The state may have moved while the peer's `Hello` was in flight (a
        // local outbound select, for instance). That is still "busy", not a
        // failure.
        if let Err(error) = self.apply(PairingInput::Select {
            session_id,
            candidate,
            deadline_ms: window_deadline,
        }) {
            return Err(self
                .discoverable_window()
                .map_or_else(|busy| busy, |_| error));
        }
        let hello = make_hello(
            PairingRole::Responder,
            local_instance,
            self.identity.public_key(),
            friendly_name,
            self.root_state(),
        );
        stream.send(&PairingMessage::Hello(hello.clone())).await?;
        self.finish_handshake(session_id, connection, stream, hello, peer)
            .await?;
        Ok(session_id)
    }

    /// The open discoverable window, or why an inbound cannot be taken now.
    fn discoverable_window(&self) -> Result<(PairingInstanceId, u64), PairingError> {
        match self.state() {
            PairingState::Discoverable {
                instance_id,
                deadline_ms,
            } => Ok((instance_id, deadline_ms)),
            PairingState::Connecting { .. }
            | PairingState::AwaitingConfirmation { .. }
            | PairingState::Committing { .. } => Err(PairingError::Busy),
            PairingState::Idle | PairingState::Trusted { .. } | PairingState::Failed { .. } => {
                Err(PairingError::Inactive)
            }
        }
    }

    async fn finish_handshake(
        &self,
        session_id: PairingSessionId,
        connection: PairingConnection,
        stream: PairingStream,
        local: PairingHello,
        peer: PairingHello,
    ) -> Result<(), PairingError> {
        if !connection
            .peer_public_key()
            .constant_time_eq(&peer.public_key)
        {
            return Err(PairingError::CertificateKeyMismatch);
        }
        let (initiator, responder) = match local.role {
            PairingRole::Initiator => (&local, &peer),
            PairingRole::Responder => (&peer, &local),
        };
        let compatibility = root_compatibility(&initiator.root_state, &responder.root_state)?;
        let transcript = canonical_transcript(initiator, responder)?;
        let hash = sha2::Sha256::digest(&transcript);
        let exporter = connection.exporter(&hash)?;
        let keys = derive_pairing_keys(&transcript, &exporter)?;
        let sas = keys.sas();
        let deadline_ms = state_deadline(&self.state()).ok_or(PairingError::Inactive)?;
        self.sessions
            .lock()
            .map_err(|_| PairingError::Transport("session lock poisoned".into()))?
            .insert(
                session_id,
                Arc::new(ActivePairingSession {
                    role: local.role,
                    connection,
                    stream: tokio::sync::Mutex::new(stream),
                    keys,
                    peer,
                    compatibility,
                    deadline_ms,
                }),
            );
        self.apply(PairingInput::SasReady {
            session_id,
            sas,
            deadline_ms,
        })?;
        Ok(())
    }
}

fn pairing_state_name(state: &PairingState) -> &'static str {
    match state {
        PairingState::Idle => "idle",
        PairingState::Discoverable { .. } => "discoverable",
        PairingState::Connecting { .. } => "connecting",
        PairingState::AwaitingConfirmation { .. } => "awaiting_confirmation",
        PairingState::Committing { .. } => "committing",
        PairingState::Trusted { .. } => "trusted",
        PairingState::Failed { .. } => "failed",
    }
}

impl Drop for PairingManager {
    fn drop(&mut self) {
        self.discovery_task.abort();
        if let Ok(slot) = self.deadline.get_mut()
            && let Some(task) = slot.take()
        {
            task.abort();
        }
        if let Ok(slot) = self.accept_task.get_mut()
            && let Some(task) = slot.take()
        {
            task.abort();
        }
        self.transport.stop();
    }
}

fn make_hello(
    role: PairingRole,
    instance_id: PairingInstanceId,
    public_key: PublicDeviceKey,
    friendly_name: String,
    root_state: RootState,
) -> PairingHello {
    let mut nonce = [0; 32];
    OsRng.fill_bytes(&mut nonce);
    PairingHello {
        version: PAIRING_PROTOCOL_VERSION,
        role,
        instance_id,
        public_key,
        nonce,
        friendly_name,
        root_state,
    }
}

fn state_deadline(state: &PairingState) -> Option<u64> {
    match state {
        PairingState::Discoverable { deadline_ms, .. }
        | PairingState::Connecting { deadline_ms, .. }
        | PairingState::AwaitingConfirmation { deadline_ms, .. }
        | PairingState::Committing { deadline_ms, .. } => Some(*deadline_ms),
        PairingState::Idle | PairingState::Trusted { .. } | PairingState::Failed { .. } => None,
    }
}

fn decode_instance(value: &str) -> Option<PairingInstanceId> {
    let bytes = hex::decode(value).ok()?;
    Some(PairingInstanceId::from_bytes(bytes.try_into().ok()?))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        discovery::{FakeDiscoveryProvider, ManualClock},
        identity::{InMemorySecureKeyStore, PrivateDeviceKey},
    };

    fn instance(byte: u8) -> PairingInstanceId {
        PairingInstanceId::from_bytes([byte; 16])
    }

    #[test]
    fn candidate_choice_is_deterministic_regardless_of_resolution_order() {
        let routable: std::net::SocketAddr = "192.168.0.104:36402".parse().unwrap();
        let bridge: std::net::SocketAddr = "10.88.0.1:36402".parse().unwrap();
        let loopback: std::net::SocketAddr = "127.0.0.1:36402".parse().unwrap();
        let mut forward = CandidateTable::new(AddressPolicy::default());
        let mut reverse = CandidateTable::new(AddressPolicy::default());
        for address in [routable, loopback, bridge] {
            forward.upsert(instance(1), "adv".into(), address, 1_000);
        }
        for address in [bridge, loopback, routable] {
            reverse.upsert(instance(1), "adv".into(), address, 1_000);
        }
        assert_eq!(forward.candidates(), reverse.candidates());
        let candidates = forward.candidates();
        assert_eq!(candidates.len(), 1, "one instance, one row");
        assert_ne!(
            candidates[0].endpoint, loopback,
            "loopback is never dialable"
        );
        // Both remaining addresses are private; the choice is numeric and stable,
        // never "whichever resolved last" — Stage 1 observed `10.88.0.1` winning
        // by arrival, which the advertisement filter now keeps off the wire.
        assert_eq!(candidates[0].endpoint, bridge);
        let mut only_routable = CandidateTable::new(AddressPolicy::default());
        only_routable.upsert(instance(1), "adv".into(), loopback, 1_000);
        assert!(only_routable.candidates().is_empty());
        only_routable.upsert(instance(1), "adv".into(), routable, 1_000);
        assert_eq!(only_routable.candidates()[0].endpoint, routable);
    }

    #[test]
    fn re_armed_device_shows_once_and_stale_instance_cannot_steal_endpoint() {
        let endpoint: std::net::SocketAddr = "192.168.0.22:34729".parse().unwrap();
        let mut table = CandidateTable::new(AddressPolicy::default());
        table.upsert(instance(1), "window-1".into(), endpoint, 1_000);
        table.upsert(instance(2), "window-2".into(), endpoint, 1_000);
        let candidates = table.candidates();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].instance_id, instance(2));
        // A cache refresh of the stale record does not bring the old row back.
        table.upsert(instance(1), "window-1".into(), endpoint, 2_000);
        let candidates = table.candidates();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].instance_id, instance(2));
        // Distinct devices (distinct endpoints) are never collapsed.
        table.upsert(
            instance(3),
            "other".into(),
            "192.168.0.50:4000".parse().unwrap(),
            1_000,
        );
        assert_eq!(table.candidates().len(), 2);
        // Two instances on one host differ by port and stay separate.
        table.upsert(
            instance(4),
            "same-host".into(),
            "192.168.0.50:4001".parse().unwrap(),
            1_000,
        );
        assert_eq!(table.candidates().len(), 3);
    }

    #[test]
    fn addresses_expire_individually_and_names_expire_instances() {
        let a: std::net::SocketAddr = "192.168.0.104:1".parse().unwrap();
        let b: std::net::SocketAddr = "192.168.1.9:1".parse().unwrap();
        let mut table = CandidateTable::new(AddressPolicy::default());
        table.upsert(instance(1), "adv".into(), a, 100);
        table.upsert(instance(1), "adv".into(), b, 200);
        table.prune(150);
        assert_eq!(
            table.candidates()[0].endpoint,
            b,
            "expired address stops resolving"
        );
        table.prune(250);
        assert!(table.candidates().is_empty());
        table.upsert(instance(1), "adv".into(), a, 1_000);
        table.expire_name("adv");
        assert!(
            table.candidates().is_empty(),
            "goodbye removes the instance"
        );
    }

    async fn manager(
        seed: u8,
    ) -> (
        Arc<PairingManager>,
        Arc<FakeDiscoveryProvider>,
        tempfile::TempDir,
    ) {
        let directory = tempfile::tempdir().unwrap();
        let keys = Arc::new(InMemorySecureKeyStore::seeded([seed; 32]));
        let identity = Arc::new(DeviceIdentity::load_or_create(keys.as_ref()).await.unwrap());
        let control =
            Arc::new(SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap());
        let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0))));
        let manager = PairingManager::new(
            identity,
            keys,
            control,
            discovery.clone(),
            "127.0.0.1".parse().unwrap(),
        )
        .unwrap();
        (manager, discovery, directory)
    }

    #[tokio::test]
    async fn live_channel_produces_matching_sas_and_bilateral_trust() {
        let (a, _, _a_dir) = manager(3).await;
        let (b, _, _b_dir) = manager(7).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        let a_instance = {
            a.set_root_state(RootState::Ready(root));
            a.start(window, "A".into())
        }
        .await
        .unwrap();
        let b_instance = {
            b.set_root_state(RootState::Ready(root));
            b.start(window, "B".into())
        }
        .await
        .unwrap();
        let candidate = PairingCandidate {
            instance_id: b_instance,
            endpoint: b.transport.local_addr().unwrap(),
            expires_at_ms: now_ms() + 5_000,
        };
        let a_session = a.connect(candidate, "A".into(), window).await.unwrap();
        let b_session = loop {
            if let PairingState::AwaitingConfirmation { session_id, .. } = b.state() {
                break session_id;
            }
            tokio::task::yield_now().await;
        };
        assert_eq!(a_session, pairing_session_id(a_instance, b_instance));
        assert_eq!(a_session, b_session);
        let a_sas = match a.state() {
            PairingState::AwaitingConfirmation { sas, .. } => sas,
            state => panic!("unexpected state: {state:?}"),
        };
        let b_sas = match b.state() {
            PairingState::AwaitingConfirmation { sas, .. } => sas,
            state => panic!("unexpected state: {state:?}"),
        };
        assert_eq!(a_sas, b_sas);
        let (a_plan, b_plan) = tokio::join!(a.confirm(a_session), b.confirm(b_session));
        let a_plan = a_plan.unwrap();
        let b_plan = b_plan.unwrap();
        a.finish_trust(&a_plan, 10).unwrap();
        b.finish_trust(&b_plan, 10).unwrap();
        assert_eq!(a.trusted_devices().unwrap().len(), 1);
        assert_eq!(b.trusted_devices().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn inactive_listener_rejects_pairing_and_timeout_cleans_advertisement() {
        let (a, discovery, _a_dir) = manager(11).await;
        let (b, _, _b_dir) = manager(13).await;
        assert!(
            a.transport
                .connect(b.transport.local_addr().unwrap())
                .await
                .is_err()
        );
        {
            a.set_root_state(RootState::NeedsDecision);
            a.start(Duration::from_millis(20), "A".into())
        }
        .await
        .unwrap();
        assert_eq!(discovery.advertisements().len(), 1);
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert_eq!(
            a.state(),
            PairingState::Failed {
                error: PairingError::Expired
            }
        );
        assert!(discovery.advertisements().is_empty());
        assert!(a.candidates().is_empty());
    }

    #[tokio::test]
    async fn rotation_is_monotonic_browses_previous_and_cleans_expired_secret() {
        let (manager, discovery, _directory) = manager(17).await;
        manager.ensure_discovery_secret(true).await.unwrap();
        manager.start_normal_discovery(41017).await.unwrap();
        let now = now_ms();
        let epoch = manager
            .rotate_discovery_secret(41017, now, 60_000)
            .await
            .unwrap();
        assert_eq!(epoch, 2);
        assert_eq!(
            manager.control.discovery_metadata().unwrap().unwrap().epoch,
            2
        );
        assert_eq!(
            manager
                .keys
                .load_previous_discovery_group_secret()
                .await
                .unwrap()
                .unwrap()
                .0,
            1
        );
        assert!(discovery.advertisements().iter().any(|advertisement| {
            matches!(advertisement.scope, DiscoveryScope::Group { epoch: 2, .. })
        }));
        assert!(
            discovery
                .browsing_scopes()
                .iter()
                .any(|scope| { matches!(scope, DiscoveryScope::Group { epoch: 1, .. }) })
        );

        let active = manager.discovery_secret().await.unwrap().unwrap();
        manager
            .install_discovery_secret(
                &DiscoveryGroupSecret::from_bytes([99; 32]),
                DiscoveryGroupMetadata {
                    epoch: 1,
                    updated_at_ms: now,
                },
            )
            .await
            .unwrap();
        assert_eq!(manager.discovery_secret().await.unwrap(), Some(active));

        let journal = manager.control.discovery_rotation().unwrap().unwrap();
        manager
            .control
            .store_discovery_rotation(DiscoveryRotationJournal {
                retain_until_ms: 0,
                ..journal
            })
            .unwrap();
        manager.stop_normal_discovery().await.unwrap();
        manager.start_normal_discovery(41017).await.unwrap();
        assert!(manager.control.discovery_rotation().unwrap().is_none());
        assert!(
            manager
                .keys
                .load_previous_discovery_group_secret()
                .await
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn rotation_targets_online_and_offline_trusted_peers_but_not_revoked_peers() {
        let (sender, _, _sender_directory) = manager(19).await;
        let (online, _, _online_directory) = manager(20).await;
        let (offline, _, _offline_directory) = manager(21).await;
        let (revoked, _, _revoked_directory) = manager(22).await;
        let shared = DiscoveryGroupSecret::from_bytes([91; 32]);
        let metadata = DiscoveryGroupMetadata {
            epoch: 1,
            updated_at_ms: 1,
        };
        for (port, manager) in [(41019, &sender), (41020, &online), (41021, &offline)] {
            manager
                .keys
                .store_discovery_group_secret(&shared)
                .await
                .unwrap();
            manager.control.store_discovery_metadata(metadata).unwrap();
            manager.start_normal_discovery(port).await.unwrap();
        }
        for (peer, state) in [
            (&online, TrustState::Trusted),
            (&offline, TrustState::Trusted),
            (&revoked, TrustState::Revoked),
        ] {
            sender
                .control
                .upsert_peer_trust(&PeerTrustRecord {
                    device_id: peer.identity.id(),
                    public_key: peer.identity.public_key(),
                    state,
                    updated_at_ms: 1,
                    last_seen_ms: None,
                })
                .unwrap();
            sender
                .control
                .upsert_trusted_device(&TrustedDeviceRecord {
                    device_id: peer.identity.id(),
                    public_key: peer.identity.public_key(),
                    friendly_name: "peer".into(),
                    paired_at_ms: 1,
                    last_seen_ms: None,
                    last_sync_ms: None,
                    state,
                })
                .unwrap();
        }
        for recipient in [&online, &offline] {
            recipient
                .control
                .upsert_peer_trust(&PeerTrustRecord {
                    device_id: sender.identity.id(),
                    public_key: sender.identity.public_key(),
                    state: TrustState::Trusted,
                    updated_at_ms: 1,
                    last_seen_ms: None,
                })
                .unwrap();
        }

        sender
            .rotate_discovery_secret(41019, now_ms(), 60_000)
            .await
            .unwrap();
        let frames = sender.rotation_update_frames().unwrap();
        assert_eq!(frames.len(), 2);
        assert!(frames.iter().any(|(peer, _)| *peer == online.identity.id()));
        assert!(
            frames
                .iter()
                .any(|(peer, _)| *peer == offline.identity.id())
        );
        assert!(
            !frames
                .iter()
                .any(|(peer, _)| *peer == revoked.identity.id())
        );

        let online_frame = frames
            .iter()
            .find(|(peer, _)| *peer == online.identity.id())
            .unwrap()
            .1;
        let ack = online
            .accept_rotation_update(sender.identity.id(), &online_frame)
            .await
            .unwrap();
        assert_eq!(sender.validate_rotation_ack(&ack).await.unwrap(), 2);
        let duplicate_ack = online
            .accept_rotation_update(sender.identity.id(), &online_frame)
            .await
            .unwrap();
        assert_eq!(
            sender.validate_rotation_ack(&duplicate_ack).await.unwrap(),
            2
        );

        let active = online.discovery_secret().await.unwrap().unwrap();
        let replay = encode_update(&DiscoverySecretUpdate::new(1, &shared), &active);
        online
            .accept_rotation_update(sender.identity.id(), &replay)
            .await
            .unwrap();
        assert_eq!(online.discovery_secret().await.unwrap(), Some(active));

        let offline_frame = frames
            .iter()
            .find(|(peer, _)| *peer == offline.identity.id())
            .unwrap()
            .1;
        offline
            .accept_rotation_update(sender.identity.id(), &offline_frame)
            .await
            .unwrap();
        assert_eq!(
            offline.control.discovery_metadata().unwrap().unwrap().epoch,
            2
        );
        assert_eq!(
            sender
                .accept_rotation_update(revoked.identity.id(), &online_frame)
                .await,
            Err(PairingError::Authentication)
        );
    }

    #[tokio::test]
    async fn prepared_rotation_recovers_epoch_after_secret_store_crash_boundary() {
        let (manager, _, _directory) = manager(18).await;
        let (previous, metadata) = manager.ensure_discovery_secret(true).await.unwrap();
        manager
            .keys
            .store_previous_discovery_group_secret(metadata.epoch, &previous)
            .await
            .unwrap();
        manager
            .keys
            .store_discovery_group_secret(&DiscoveryGroupSecret::from_bytes([42; 32]))
            .await
            .unwrap();
        manager
            .control
            .store_discovery_rotation(DiscoveryRotationJournal {
                previous_epoch: 1,
                target_epoch: 2,
                retain_until_ms: now_ms() + 60_000,
                stage: DiscoveryRotationStage::Prepared,
                updated_at_ms: now_ms(),
            })
            .unwrap();
        manager.start_normal_discovery(41018).await.unwrap();
        assert_eq!(
            manager.control.discovery_metadata().unwrap().unwrap().epoch,
            2
        );
        assert_eq!(
            manager.control.discovery_rotation().unwrap().unwrap().stage,
            DiscoveryRotationStage::Active
        );
    }

    #[tokio::test]
    async fn remote_rejection_never_creates_trust() {
        let (a, _, _a_dir) = manager(31).await;
        let (b, _, _b_dir) = manager(32).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        {
            a.set_root_state(RootState::Ready(root));
            a.start(window, "A".into())
        }
        .await
        .unwrap();
        let b_instance = {
            b.set_root_state(RootState::Ready(root));
            b.start(window, "B".into())
        }
        .await
        .unwrap();
        let a_session = a
            .connect(
                PairingCandidate {
                    instance_id: b_instance,
                    endpoint: b.transport.local_addr().unwrap(),
                    expires_at_ms: now_ms() + 5_000,
                },
                "A".into(),
                window,
            )
            .await
            .unwrap();
        let b_session = loop {
            if let PairingState::AwaitingConfirmation { session_id, .. } = b.state() {
                break session_id;
            }
            tokio::task::yield_now().await;
        };
        b.reject(Some(b_session)).await.unwrap();
        assert_eq!(a.confirm(a_session).await, Err(PairingError::Rejected));
        assert!(a.trusted_devices().unwrap().is_empty());
        assert!(b.trusted_devices().unwrap().is_empty());
        assert!(
            a.keys
                .load_discovery_group_secret()
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            b.keys
                .load_discovery_group_secret()
                .await
                .unwrap()
                .is_none()
        );

        {
            a.set_root_state(RootState::Ready(root));
            a.start(window, "A".into())
        }
        .await
        .unwrap();
        let next_b = {
            b.set_root_state(RootState::Ready(root));
            b.start(window, "B".into())
        }
        .await
        .unwrap();
        let next_a_session = a
            .connect(
                PairingCandidate {
                    instance_id: next_b,
                    endpoint: b.transport.local_addr().unwrap(),
                    expires_at_ms: now_ms() + 5_000,
                },
                "A".into(),
                window,
            )
            .await
            .unwrap();
        let next_b_session = loop {
            if let PairingState::AwaitingConfirmation { session_id, .. } = b.state() {
                break session_id;
            }
            tokio::task::yield_now().await;
        };
        let (a_plan, b_plan) = tokio::join!(a.confirm(next_a_session), b.confirm(next_b_session));
        a.finish_trust(&a_plan.unwrap(), 2).unwrap();
        b.finish_trust(&b_plan.unwrap(), 2).unwrap();
        assert_eq!(a.trusted_devices().unwrap().len(), 1);
        assert_eq!(b.trusted_devices().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn hello_key_mismatch_never_displays_sas_or_creates_trust() {
        let (target, _, _target_dir) = manager(41).await;
        let root = automerge_repo::DocumentId::new();
        {
            target.set_root_state(RootState::Ready(root));
            target.start(Duration::from_secs(5), "target".into())
        }
        .await
        .unwrap();
        let rogue_keys = InMemorySecureKeyStore::seeded([42; 32]);
        let rogue_identity = DeviceIdentity::load_or_create(&rogue_keys).await.unwrap();
        let rogue =
            PairingTransport::bind("127.0.0.1:0".parse().unwrap(), &rogue_identity).unwrap();
        let connection = rogue
            .connect(target.transport.local_addr().unwrap())
            .await
            .unwrap();
        let mut stream = connection.open_stream().await.unwrap();
        let mismatched = PrivateDeviceKey::from_seed(&[43; 32]).unwrap().public_key();
        stream
            .send(&PairingMessage::Hello(make_hello(
                PairingRole::Initiator,
                PairingInstanceId::from_bytes([1; 16]),
                mismatched,
                "rogue".into(),
                RootState::Ready(root),
            )))
            .await
            .unwrap();
        let mut state = target.subscribe_state();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if matches!(
                    state.borrow().clone(),
                    PairingState::Failed {
                        error: PairingError::CertificateKeyMismatch
                    }
                ) {
                    break;
                }
                state.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
        assert!(target.trusted_devices().unwrap().is_empty());
    }

    #[tokio::test]
    async fn disconnect_while_awaiting_confirmation_creates_no_trust() {
        let (a, _, _a_dir) = manager(45).await;
        let (b, _, _b_dir) = manager(46).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        {
            a.set_root_state(RootState::Ready(root));
            a.start(window, "A".into())
        }
        .await
        .unwrap();
        let b_instance = {
            b.set_root_state(RootState::Ready(root));
            b.start(window, "B".into())
        }
        .await
        .unwrap();
        let session = a
            .connect(
                PairingCandidate {
                    instance_id: b_instance,
                    endpoint: b.transport.local_addr().unwrap(),
                    expires_at_ms: now_ms() + 5_000,
                },
                "A".into(),
                window,
            )
            .await
            .unwrap();
        a.stop().await.unwrap();
        assert!(b.confirm(session).await.is_err());
        assert!(a.trusted_devices().unwrap().is_empty());
        assert!(b.trusted_devices().unwrap().is_empty());
    }

    #[tokio::test]
    async fn independent_groups_emit_no_cross_group_normal_endpoint() {
        let provider = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(100))));
        let directory_a = tempfile::tempdir().unwrap();
        let directory_b = tempfile::tempdir().unwrap();
        let keys_a = Arc::new(InMemorySecureKeyStore::seeded([61; 32]));
        let keys_b = Arc::new(InMemorySecureKeyStore::seeded([62; 32]));
        let identity_a = Arc::new(
            DeviceIdentity::load_or_create(keys_a.as_ref())
                .await
                .unwrap(),
        );
        let identity_b = Arc::new(
            DeviceIdentity::load_or_create(keys_b.as_ref())
                .await
                .unwrap(),
        );
        let a = PairingManager::new(
            identity_a.clone(),
            keys_a,
            Arc::new(SqliteControlStore::open(directory_a.path().join("control.sqlite")).unwrap()),
            provider.clone(),
            "127.0.0.1".parse().unwrap(),
        )
        .unwrap();
        let b = PairingManager::new(
            identity_b.clone(),
            keys_b,
            Arc::new(SqliteControlStore::open(directory_b.path().join("control.sqlite")).unwrap()),
            provider.clone(),
            "127.0.0.1".parse().unwrap(),
        )
        .unwrap();
        a.establish_trust(identity_b.public_key(), "B".into(), 1)
            .unwrap();
        b.establish_trust(identity_a.public_key(), "A".into(), 1)
            .unwrap();
        a.install_discovery_secret(
            &DiscoveryGroupSecret::from_bytes([1; 32]),
            DiscoveryGroupMetadata {
                epoch: 1,
                updated_at_ms: 1,
            },
        )
        .await
        .unwrap();
        b.install_discovery_secret(
            &DiscoveryGroupSecret::from_bytes([2; 32]),
            DiscoveryGroupMetadata {
                epoch: 1,
                updated_at_ms: 1,
            },
        )
        .await
        .unwrap();
        let mut a_events = a.subscribe_normal_discovery();
        let mut b_events = b.subscribe_normal_discovery();
        a.start_normal_discovery(41001).await.unwrap();
        b.start_normal_discovery(41002).await.unwrap();
        for advertisement in provider.advertisements() {
            provider
                .resolve(&advertisement, "127.0.0.1".parse().unwrap())
                .unwrap();
        }
        assert!(
            tokio::time::timeout(Duration::from_millis(50), a_events.recv())
                .await
                .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(50), b_events.recv())
                .await
                .is_err()
        );
    }

    fn candidate_for(manager: &PairingManager, instance: PairingInstanceId) -> PairingCandidate {
        PairingCandidate {
            instance_id: instance,
            endpoint: manager.transport.local_addr().unwrap(),
            expires_at_ms: now_ms() + 5_000,
        }
    }

    async fn await_sas(manager: &PairingManager) -> PairingSessionId {
        let mut state = manager.subscribe_state();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if let PairingState::AwaitingConfirmation { session_id, .. } =
                    state.borrow().clone()
                {
                    break session_id;
                }
                state.changed().await.unwrap();
            }
        })
        .await
        .expect("SAS displayed")
    }

    #[tokio::test]
    async fn refused_inbound_leaves_window_open_and_later_inbound_is_processed() {
        let (a, a_discovery, _a_dir) = manager(51).await;
        let (b, _, _b_dir) = manager(52).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        a.set_root_state(RootState::Ready(root));
        b.set_root_state(RootState::Ready(root));
        let a_instance = a.start(window, "A".into()).await.unwrap();
        let b_instance = b.start(window, "B".into()).await.unwrap();
        // A holds an outbound attempt (selected, not yet dialed) when B's
        // inbound arrives.
        a.select(candidate_for(&b, b_instance), window).unwrap();
        assert_eq!(
            b.connect(candidate_for(&a, a_instance), "B".into(), window)
                .await,
            Err(PairingError::PeerBusy)
        );
        assert!(
            matches!(b.state(), PairingState::Discoverable { .. }),
            "the dialer keeps its window: {:?}",
            b.state()
        );
        assert!(
            matches!(a.state(), PairingState::Connecting { .. }),
            "the refusal did not disturb the local attempt: {:?}",
            a.state()
        );
        assert_eq!(
            a_discovery.advertisements().len(),
            1,
            "the refused inbound did not end the window"
        );
        // The outbound attempt is abandoned; the same window accepts the next
        // inbound.
        a.release();
        assert!(matches!(a.state(), PairingState::Discoverable { .. }));
        let b_session = b
            .connect(candidate_for(&a, a_instance), "B".into(), window)
            .await
            .unwrap();
        assert_eq!(await_sas(&a).await, b_session);
        assert_eq!(b_session, pairing_session_id(b_instance, a_instance));
    }

    #[tokio::test]
    async fn simultaneous_dial_never_destroys_both_windows() {
        let (a, a_discovery, _a_dir) = manager(53).await;
        let (b, b_discovery, _b_dir) = manager(54).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        a.set_root_state(RootState::Ready(root));
        b.set_root_state(RootState::Ready(root));
        let a_instance = a.start(window, "A".into()).await.unwrap();
        let b_instance = b.start(window, "B".into()).await.unwrap();
        let (from_a, from_b) = tokio::join!(
            a.connect(candidate_for(&b, b_instance), "A".into(), window),
            b.connect(candidate_for(&a, a_instance), "B".into(), window),
        );
        assert!(
            !matches!(a.state(), PairingState::Failed { .. }),
            "A must not fail: {:?}",
            a.state()
        );
        assert!(
            !matches!(b.state(), PairingState::Failed { .. }),
            "B must not fail: {:?}",
            b.state()
        );
        assert_eq!(a_discovery.advertisements().len(), 1);
        assert_eq!(b_discovery.advertisements().len(), 1);
        for outcome in [&from_a, &from_b] {
            if let Err(error) = outcome {
                assert!(
                    matches!(error, PairingError::Busy | PairingError::PeerBusy),
                    "only a busy refusal is acceptable: {error:?}"
                );
            }
        }
        let session = match (from_a, from_b) {
            (Ok(_), Ok(_)) => panic!("two sessions cannot both be established"),
            (Ok(session), Err(_)) | (Err(_), Ok(session)) => session,
            (Err(_), Err(_)) => {
                // Phase A: both refused, both windows open, one retry succeeds.
                assert!(matches!(a.state(), PairingState::Discoverable { .. }));
                assert!(matches!(b.state(), PairingState::Discoverable { .. }));
                a.connect(candidate_for(&b, b_instance), "A".into(), window)
                    .await
                    .unwrap()
            }
        };
        assert_eq!(await_sas(&a).await, session);
        assert_eq!(await_sas(&b).await, session);
    }

    #[tokio::test]
    async fn root_created_after_window_opens_is_advertised_and_never_provisioned() {
        let (a, _, _a_dir) = manager(55).await;
        let (b, _, _b_dir) = manager(56).await;
        let window = Duration::from_secs(5);
        a.set_root_state(RootState::NeedsDecision);
        b.set_root_state(RootState::Ready(automerge_repo::DocumentId::new()));
        let a_instance = a.start(window, "A".into()).await.unwrap();
        b.start(window, "B".into()).await.unwrap();
        // A creates its own root while its window is open.
        a.set_root_state(RootState::Ready(automerge_repo::DocumentId::new()));
        // The responder judges compatibility first and may drop the connection
        // before the initiator has judged it, so the dialer sees either the
        // mismatch or the resulting transport loss. Never a provisioning plan.
        let outcome = b
            .connect(candidate_for(&a, a_instance), "B".into(), window)
            .await;
        assert!(
            matches!(
                outcome,
                Err(PairingError::RootMismatch | PairingError::Transport(_))
            ),
            "unexpected outcome: {outcome:?}"
        );
        let mut state = a.subscribe_state();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if let PairingState::Failed { error } = state.borrow().clone() {
                    assert_eq!(
                        error,
                        PairingError::RootMismatch,
                        "the handshake carries the current root, not the captured needs-decision"
                    );
                    break;
                }
                state.changed().await.unwrap();
            }
        })
        .await
        .unwrap();
        assert!(a.sessions.lock().unwrap().is_empty());
        assert!(b.sessions.lock().unwrap().is_empty());
        assert!(a.trusted_devices().unwrap().is_empty());
        assert!(b.trusted_devices().unwrap().is_empty());
    }

    #[tokio::test]
    async fn join_completed_in_one_session_is_advertised_ready_in_the_next() {
        let (a, _, _a_dir) = manager(57).await;
        let (b, _, _b_dir) = manager(58).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        a.set_root_state(RootState::NeedsDecision);
        b.set_root_state(RootState::Ready(root));
        let a_instance = a.start(window, "A".into()).await.unwrap();
        b.start(window, "B".into()).await.unwrap();
        let first = b
            .connect(candidate_for(&a, a_instance), "B".into(), window)
            .await
            .unwrap();
        await_sas(&a).await;
        assert_eq!(
            a.session(first).unwrap().compatibility,
            RootCompatibility::ProvisionInitiatorToResponder
        );
        a.stop().await.unwrap();
        b.stop().await.unwrap();
        // The join through that session lands; the manager learns the root.
        a.set_root_state(RootState::Ready(root));
        let a_instance = a.start(window, "A".into()).await.unwrap();
        b.start(window, "B".into()).await.unwrap();
        let second = b
            .connect(candidate_for(&a, a_instance), "B".into(), window)
            .await
            .unwrap();
        await_sas(&a).await;
        assert_eq!(
            a.session(second).unwrap().compatibility,
            RootCompatibility::SameRoot
        );
    }
}
