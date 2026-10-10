//! Application-facing pairing/discovery lifecycle and durable trust control.

use std::{
    collections::{BTreeMap, HashMap},
    net::{IpAddr, SocketAddr},
    ops::RangeInclusive,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
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
        AddressPolicy, DEFAULT_RECORD_TTL_MS, DiscoveredEndpoint, DiscoveryAdvertisement,
        DiscoveryEvent, DiscoveryGroupSecret, DiscoveryProvider, DiscoveryScope, GroupRejection,
        PairingInstanceId, classify_group_endpoint, discovery_secret_fingerprint,
        group_routing_token, group_service_selector,
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

/// How long an inbound pairing peer may take to deliver its hello before the
/// connection is cut off.
const INBOUND_HELLO_TIMEOUT: Duration = Duration::from_secs(10);

/// Which UDP ports a pairing window may bind.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PairingPorts {
    /// An operating-system-chosen port.
    Ephemeral,
    /// The lowest free port in `range` other than `exclude` (the device's own
    /// sync port).
    Range {
        range: RangeInclusive<u16>,
        exclude: u16,
    },
}

/// Where a pairing window binds its socket. Nothing is bound until a window opens.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingBind {
    pub ip: IpAddr,
    pub ports: PairingPorts,
}

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
/// goodbye. Both resolve to the same `ip:port` when the new window binds the
/// same free port as the old one. The newer instance therefore owns the endpoint and the older one
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
    bind: PairingBind,
    /// Bound only while a pairing window is open.
    transport: Mutex<Option<Arc<PairingTransport>>>,
    inbound_hello_timeout_ms: AtomicU64,
    state_tx: watch::Sender<PairingState>,
    candidates_tx: watch::Sender<Vec<PairingCandidate>>,
    events: broadcast::Sender<PairingEvent>,
    normal_events: broadcast::Sender<NormalDiscoveryEvent>,
    group_tx: watch::Sender<Option<DiscoveryGroupState>>,
    address_policy: AddressPolicy,
    normal_scope: Mutex<Option<DiscoveryScope>>,
    /// The Discoverable preference. While off, every path into
    /// [`Self::start_normal_discovery`] is a no-op; pairing discovery is not
    /// governed by it.
    normal_discovery_enabled: AtomicBool,
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
        bind: PairingBind,
    ) -> Result<Arc<Self>, PairingError> {
        let address_policy = AddressPolicy::for_bind(bind.ip);
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
        let local_id = identity.id();
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
                        let known: Vec<_> = control_for_discovery
                            .trusted_devices()
                            .unwrap_or_default()
                            .into_iter()
                            .map(|record| (record.device_id, record.state))
                            .collect();
                        let classify = |secret| {
                            classify_group_endpoint(
                                &endpoint,
                                secret,
                                &address_policy,
                                local_id,
                                &known,
                            )
                        };
                        let active = classify(&group.active);
                        let previous = group.previous.as_ref().map(|(secret, _)| classify(secret));
                        match (active, previous) {
                            (Ok((peer, address, expires_at_ms)), _)
                            | (Err(_), Some(Ok((peer, address, expires_at_ms)))) => {
                                let _ = normal_events_for_discovery.send(
                                    NormalDiscoveryEvent::Upsert {
                                        peer,
                                        address,
                                        expires_at_ms,
                                    },
                                );
                            }
                            // The previous secret got past the selector, so its
                            // reason is the informative one.
                            (Err(GroupRejection::Selector), Some(Err(previous))) => {
                                log_group_rejection(&endpoint, previous);
                            }
                            (Err(active), _) => log_group_rejection(&endpoint, active),
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
            bind,
            transport: Mutex::new(None),
            inbound_hello_timeout_ms: AtomicU64::new(
                INBOUND_HELLO_TIMEOUT
                    .as_millis()
                    .try_into()
                    .unwrap_or(u64::MAX),
            ),
            state_tx,
            candidates_tx,
            events,
            normal_events,
            group_tx,
            address_policy,
            normal_scope: Mutex::new(None),
            normal_discovery_enabled: AtomicBool::new(true),
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
            .map_err(PairingError::from)
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
    /// The pairing socket's address; `Inactive` while no pairing window holds one.
    pub fn local_addr(&self) -> Result<std::net::SocketAddr, PairingError> {
        self.current_transport()?.local_addr()
    }

    #[cfg(test)]
    fn set_inbound_hello_timeout(&self, timeout: Duration) {
        self.inbound_hello_timeout_ms.store(
            timeout.as_millis().try_into().unwrap_or(u64::MAX),
            Ordering::Release,
        );
    }

    fn inbound_hello_timeout(&self) -> Duration {
        Duration::from_millis(self.inbound_hello_timeout_ms.load(Ordering::Acquire))
    }

    /// Binds a pairing socket under the configured port rules.
    fn bind_transport(&self) -> Result<Arc<PairingTransport>, PairingError> {
        let bind = |port: u16| {
            PairingTransport::bind(
                SocketAddr::new(self.bind.ip, port),
                &self.identity,
                self.address_policy,
            )
        };
        let transport = match &self.bind.ports {
            PairingPorts::Ephemeral => bind(0)?,
            PairingPorts::Range { range, exclude } => {
                let mut bound = None;
                for port in range.clone().filter(|port| port != exclude) {
                    match bind(port) {
                        Ok(transport) => {
                            bound = Some(transport);
                            break;
                        }
                        Err(PairingError::AddrInUse(_)) => {}
                        Err(error) => return Err(error),
                    }
                }
                bound.ok_or(PairingError::PortsExhausted {
                    first: *range.start(),
                    last: *range.end(),
                })?
            }
        };
        let port = transport.local_addr()?.port();
        tracing::info!(event = "sync_port_bound", role = "pairing", port);
        Ok(Arc::new(transport))
    }

    fn current_transport(&self) -> Result<Arc<PairingTransport>, PairingError> {
        self.transport
            .lock()
            .map_err(|_| PairingError::Transport("transport lock poisoned".into()))?
            .clone()
            .ok_or(PairingError::Inactive)
    }

    /// Closes the pairing socket, if any, so nothing answers on its port.
    fn release_transport(&self) {
        let Some(transport) = self.transport.lock().ok().and_then(|mut slot| slot.take()) else {
            return;
        };
        let port = transport.local_addr().map(|address| address.port()).ok();
        transport.stop();
        transport.close_endpoint();
        tracing::info!(event = "pairing_port_released", port);
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
        self.release_transport();
        let transport = self.bind_transport()?;
        let port = transport.local_addr()?.port();
        transport.start();
        *self
            .transport
            .lock()
            .map_err(|_| PairingError::Transport("transport lock poisoned".into()))? =
            Some(transport);
        if let Err(error) = self
            .discovery
            .start(DiscoveryAdvertisement::pairing(
                instance,
                name,
                port,
                DEFAULT_RECORD_TTL_MS.min(duration.as_millis().try_into().unwrap_or(u64::MAX)),
            ))
            .await
        {
            self.release_transport();
            return Err(PairingError::Transport(error.to_string()));
        }
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
    /// connection and the loop keeps listening. An inbound whose handshake
    /// fails before the SAS (bad hello, key mismatch, incompatible roots, or no
    /// hello within the inbound timeout) is rejected on its own connection too,
    /// and the device returns to discoverable with its window unchanged. The
    /// local window, candidate list, and any in-flight outbound attempt are
    /// never failed from here.
    async fn accept_loop(self: Arc<Self>, window: Duration, friendly_name: String) {
        let deadline = tokio::time::sleep(window);
        tokio::pin!(deadline);
        loop {
            if !self.state_is_active() {
                return;
            }
            let Ok(transport) = self.current_transport() else {
                return;
            };
            let connection = tokio::select! {
                () = &mut deadline => return,
                accepted = transport.accept() => match accepted {
                    Ok(connection) => connection,
                    Err(_) => return,
                },
            };
            drop(transport);
            tracing::info!(
                event = "pairing_accept",
                remote = %connection.remote_address(),
                "accepted inbound pairing connection"
            );
            let mut selected = None;
            let outcome = tokio::time::timeout(
                self.inbound_hello_timeout(),
                self.accept_handshake(connection.clone(), friendly_name.clone(), &mut selected),
            )
            .await
            .unwrap_or(Err(PairingError::Transport(
                "no pairing hello before the inbound timeout".into(),
            )));
            match outcome {
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
                Err(error) => self.refuse_inbound(&connection, selected, &error),
            }
        }
    }

    /// Rejects one inbound connection whose handshake failed and puts the
    /// device back to discoverable if that inbound had selected a session.
    fn refuse_inbound(
        &self,
        connection: &PairingConnection,
        session: Option<PairingSessionId>,
        error: &PairingError,
    ) {
        tracing::info!(
            event = "pairing_inbound_rejected",
            remote = %connection.remote_address(),
            error = %error
        );
        connection.reject_handshake();
        let Some(session) = session else {
            return;
        };
        if let Ok(mut sessions) = self.sessions.lock() {
            sessions.remove(&session);
        }
        if let PairingState::Connecting { session_id, .. } = self.state()
            && session_id == session
        {
            let _ = self.apply(PairingInput::Release { session_id });
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
        self.release_transport();
        self.clear_sessions();
        self.candidates_tx.send_replace(Vec::new());
        self.apply(PairingInput::Stop)?;
        Ok(())
    }

    async fn timeout(&self) -> Result<(), PairingError> {
        // Publish the expiry before tearing the transport down, so a wait that
        // sees the connection close can tell it was caused by the deadline.
        let applied = self.apply(PairingInput::Timeout { now_ms: now_ms() });
        let _ = self.discovery.stop(&DiscoveryScope::Pairing).await;
        self.release_transport();
        self.clear_sessions();
        self.candidates_tx.send_replace(Vec::new());
        applied?;
        Ok(())
    }

    /// Reports a stream failure at or past the session deadline as expiry.
    ///
    /// At the deadline both devices tear their transport down, so the wait may
    /// observe the close before its own timer fires. That close is the expiry,
    /// not a transport failure. A failure before the deadline is unchanged.
    fn at_deadline(&self, session: &ActivePairingSession, error: PairingError) -> PairingError {
        let expired = now_ms() >= session.deadline_ms
            || matches!(
                self.state(),
                PairingState::Failed {
                    error: PairingError::Expired
                }
            );
        match error {
            PairingError::Transport(_) if expired => PairingError::Expired,
            error => error,
        }
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
        peer: DeviceId,
        sas: crate::pairing::SasCode,
        deadline_ms: u64,
    ) -> Result<(), PairingError> {
        self.apply(PairingInput::SasReady {
            session_id,
            peer,
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
        let connection = self
            .current_transport()?
            .connect(candidate.endpoint)
            .await?;
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
            .map_err(|_| PairingError::Expired)?
            .map_err(|error| self.at_deadline(&session, error))?;
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
            // The socket is released below; let the decision reach the peer first.
            let _ = tokio::time::timeout(Duration::from_secs(2), stream.finish_and_flush()).await;
        }
        self.apply(PairingInput::Reject { session_id })?;
        self.cancel_deadline();
        let _ = self.discovery.stop(&DiscoveryScope::Pairing).await;
        self.candidates_tx.send_replace(Vec::new());
        if let Some(session_id) = session_id
            && let Ok(mut sessions) = self.sessions.lock()
        {
            sessions.remove(&session_id);
        }
        self.release_transport();
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
        self.release_transport();
        self.clear_sessions();
        self.candidates_tx.send_replace(Vec::new());
    }

    pub(crate) async fn fail(&self, error: PairingError) {
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
        let existing = self
            .keys
            .load_discovery_group_secret()
            .await
            .map_err(PairingError::from)?;
        let metadata = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        if let (Some(secret), Some(metadata)) = (&existing, metadata) {
            self.group_tx.send_replace(Some(DiscoveryGroupState {
                active: secret.clone(),
                previous: None,
            }));
            return Ok((secret.clone(), metadata));
        }
        if existing.is_some() {
            // Same orphan as `start_normal_discovery` reports: the key store is
            // host-scoped while the epoch row is dataset-scoped, so a fresh or
            // manually-cleared data directory meets a secret left by another
            // dataset on this host. We are not in that group, and provisioning
            // under its selector would collide with it, so the orphan (and any
            // retained previous-epoch secret) is replaced by a new group.
            tracing::warn!(
                event = "discovery_secret_orphaned",
                "discovery secret present without group metadata; replacing it with a new group"
            );
            self.keys
                .remove_previous_discovery_group_secret()
                .await
                .map_err(PairingError::from)?;
            self.control
                .clear_discovery_rotation()
                .map_err(|error| PairingError::Transport(error.to_string()))?;
        }
        let mut bytes = [0; 32];
        OsRng.fill_bytes(&mut bytes);
        let secret = DiscoveryGroupSecret::from_bytes(bytes);
        self.keys
            .store_discovery_group_secret(&secret)
            .await
            .map_err(PairingError::from)?;
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
                .map_err(PairingError::from)?
                .ok_or(PairingError::Malformed("discovery secret missing"))?;
            self.keys
                .store_previous_discovery_group_secret(current.epoch, &previous)
                .await
                .map_err(PairingError::from)?;
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
            .map_err(PairingError::from)?;
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

    /// Gates normal discovery. Does not start or stop it; the caller decides.
    pub fn set_normal_discovery_enabled(&self, enabled: bool) {
        self.normal_discovery_enabled
            .store(enabled, Ordering::Release);
    }

    pub async fn start_normal_discovery(&self, port: u16) -> Result<bool, PairingError> {
        if !self.normal_discovery_enabled.load(Ordering::Acquire) {
            return Ok(false);
        }
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
            .map_err(PairingError::from)?
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
                discovery_secret_fingerprint(&secret),
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
                .map_err(PairingError::from)?
                .filter(|(epoch, _)| *epoch == journal.previous_epoch)
                .map(|(epoch, secret)| (secret, epoch))
        } else {
            self.keys
                .remove_previous_discovery_group_secret()
                .await
                .map_err(PairingError::from)?;
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
            .map_err(PairingError::from)?
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
            .map_err(PairingError::from)?;
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
            .map_err(PairingError::from)?;
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
            .map_err(PairingError::from)?
            .ok_or(PairingError::Malformed("discovery secret missing"))?;
        let update = match decode_update(frame, &current_secret) {
            Ok(update) => update,
            Err(_) => {
                let (_, previous) = self
                    .keys
                    .load_previous_discovery_group_secret()
                    .await
                    .map_err(PairingError::from)?
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
            .map_err(PairingError::from)?
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
                failure_reason: None,
                updated_at_ms: now_ms(),
            })
            .map_err(|error| PairingError::Transport(error.to_string()))
    }

    /// Records why the commit for this session failed. The stage is left at the
    /// last durable step, so the entry reads as an incomplete session with a
    /// reason rather than as a rolled-back one; the trust record, if any, is
    /// deliberately kept because the peer may legitimately hold trust for us.
    pub fn journal_failure(
        &self,
        plan: &PairingCommitPlan,
        reason: &str,
    ) -> Result<(), PairingError> {
        self.control
            .record_pairing_journal_failure(plan.session_id.0, reason, now_ms())
            .map(|_| ())
            .map_err(|error| PairingError::Transport(error.to_string()))
    }

    /// Finishes a commit that stored trust but never reached `Complete`,
    /// because the local side failed after the peer had already succeeded.
    /// Runs on the next authenticated connection with that peer, so the two
    /// devices stop disagreeing without needing a fresh pairing window.
    ///
    /// Only resumes entries whose trust is already durable: an earlier failure
    /// left nothing to reconcile and still needs a real pairing window.
    pub fn resume_incomplete_commit(&self, peer: DeviceId, now: u64) -> Result<bool, PairingError> {
        let Some(record) = self
            .control
            .incomplete_pairing_journal_for_peer(peer)
            .map_err(|error| PairingError::Transport(error.to_string()))?
        else {
            return Ok(false);
        };
        if !matches!(
            record.stage,
            PairingJournalStage::TrustStored
                | PairingJournalStage::RootJoining
                | PairingJournalStage::AwaitingAcknowledgement
        ) {
            return Ok(false);
        }
        // A session still in flight is not an interrupted one. Its own commit
        // will complete or fail it, and completing the journal here would both
        // race that commit and hide a real failure from a later resume.
        if self
            .sessions
            .lock()
            .is_ok_and(|sessions| sessions.contains_key(&PairingSessionId(record.session_id)))
        {
            return Ok(false);
        }
        let trusted = self
            .control
            .trusted_device(peer)
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .is_some_and(|record| record.state == TrustState::Trusted);
        if !trusted {
            return Ok(false);
        }
        self.control
            .store_pairing_journal(&PairingJournalRecord {
                session_id: record.session_id,
                peer_device_id: peer,
                stage: PairingJournalStage::Complete,
                joining_root: record.joining_root,
                failure_reason: None,
                updated_at_ms: now,
            })
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        tracing::info!(
            event = "pairing_commit_resumed",
            peer = %peer,
            "resumed an unacknowledged pairing commit"
        );
        Ok(true)
    }

    /// Whether `peer` is already a trusted, non-revoked device.
    pub fn is_trusted(&self, peer: DeviceId) -> Result<bool, PairingError> {
        Ok(self
            .control
            .trusted_device(peer)
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .is_some_and(|record| record.state == TrustState::Trusted))
    }

    /// IP addresses at which trusted, non-revoked devices are known to be
    /// reachable. Pairing beacons are anonymous by design, so this is what a
    /// candidate list matches against to suppress already-paired devices.
    pub fn trusted_device_addresses(&self) -> Result<Vec<std::net::IpAddr>, PairingError> {
        let devices = self
            .control
            .trusted_devices()
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let mut addresses = Vec::new();
        for device in devices {
            if device.state != TrustState::Trusted {
                continue;
            }
            if let Some(metadata) = self
                .control
                .peer_connection(device.device_id)
                .map_err(|error| PairingError::Transport(error.to_string()))?
                && let Some(endpoint) = metadata.endpoint
            {
                addresses.push(endpoint.ip());
            }
        }
        Ok(addresses)
    }

    pub fn establish_trust(
        &self,
        peer_key: PublicDeviceKey,
        name: String,
        now: u64,
    ) -> Result<TrustedDeviceRecord, PairingError> {
        let device_id = DeviceId::from_public_key(peer_key.as_bytes());
        // An already-trusted peer updates its record; re-pairing must not look
        // like a first pairing, and must not leave a second row behind.
        let existing = self
            .control
            .trusted_device(device_id)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        let record = TrustedDeviceRecord {
            device_id,
            public_key: peer_key,
            announced_name: crate::device_name::normalize_device_name(&name)
                .map_err(|_| PairingError::Malformed("invalid friendly name"))?,
            // A re-pair keeps the nickname the user set for this device.
            nickname: existing.as_ref().and_then(|record| record.nickname.clone()),
            paired_at_ms: existing.as_ref().map_or(now, |record| record.paired_at_ms),
            last_seen_ms: Some(now),
            // The sync bridge may already have recorded convergence (the
            // joiner syncs before `finish_trust` re-runs this); keep it.
            last_sync_ms: existing.and_then(|record| record.last_sync_ms),
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
        let already_paired = self.is_trusted(plan.peer_device_id)?;
        let record = self.establish_trust(plan.peer_public_key, plan.peer_name.clone(), now)?;
        self.apply(PairingInput::CommitComplete {
            session_id: plan.session_id,
            peer: plan.peer_device_id,
            already_paired,
        })?;
        if let Ok(mut sessions) = self.sessions.lock()
            && let Some(session) = sessions.remove(&plan.session_id)
        {
            session.connection.close();
        }
        self.cancel_deadline();
        self.release_transport();
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
            .map_err(|_| PairingError::Expired)?
            .map_err(|error| self.at_deadline(&session, error))?;
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
            .map_err(|_| PairingError::Expired)?
            .map_err(|error| self.at_deadline(&session, error))?;
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
        let mut stream = session.stream.lock().await;
        stream
            .send(&PairingMessage::CommitAck {
                session_id: plan.session_id,
                mac,
            })
            .await?;
        // The caller closes the connection immediately after this returns, and
        // the provisioner is blocked waiting for exactly this message, so the
        // acknowledgement has to be on the wire and acknowledged before the
        // close can discard it.
        stream.finish_and_flush().await
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
    pub fn delete_revoked(&self, peer: DeviceId) -> Result<bool, PairingError> {
        self.control
            .delete_revoked_device(peer)
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
    ///
    /// `selected` receives the session id once this inbound has moved the state
    /// with `PairingInput::Select`, so a failure can be undone for this
    /// connection alone.
    async fn accept_handshake(
        &self,
        connection: PairingConnection,
        friendly_name: String,
        selected: &mut Option<PairingSessionId>,
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
        *selected = Some(session_id);
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
        let peer_device_id = DeviceId::from_public_key(peer.public_key.as_bytes());
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
        self.sas_ready(session_id, peer_device_id, sas, deadline_ms)?;
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
        self.release_transport();
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

fn log_group_rejection(endpoint: &DiscoveredEndpoint, rejection: GroupRejection) {
    match rejection {
        GroupRejection::Own => tracing::debug!(
            event = "discovery_group_record_rejected",
            scope = ?endpoint.scope,
            instance = %endpoint.instance_name,
            address = %endpoint.address,
            reason = rejection.reason()
        ),
        GroupRejection::Untrusted(device_id) => tracing::info!(
            event = "discovery_group_record_rejected",
            scope = ?endpoint.scope,
            instance = %endpoint.instance_name,
            address = %endpoint.address,
            reason = rejection.reason(),
            device_id = %device_id
        ),
        GroupRejection::Address | GroupRejection::Selector | GroupRejection::Token => {
            tracing::info!(
                event = "discovery_group_record_rejected",
                scope = ?endpoint.scope,
                instance = %endpoint.instance_name,
                address = %endpoint.address,
                reason = rejection.reason()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        discovery::{FakeDiscoveryProvider, ManualClock},
        identity::{
            InMemorySecureKeyStore, PlatformSecretPersistence, PlatformSecretWrite,
            PrivateDeviceKey, SecureStoreError, WriteThroughSecureKeyStore,
        },
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

    /// The key store is host-scoped, the epoch row is dataset-scoped: a reset
    /// or hand-cleared data directory meets a secret left by another dataset on
    /// the same host. Provisioning must not fail on that orphan.
    #[tokio::test]
    async fn an_orphaned_secret_is_replaced_rather_than_failing_the_commit() {
        let directory = tempfile::tempdir().unwrap();
        let keys = Arc::new(InMemorySecureKeyStore::seeded([75; 32]));
        // A secret left behind by a dataset this control store knows nothing of.
        let orphan = DiscoveryGroupSecret::from_bytes([9; 32]);
        keys.store_discovery_group_secret(&orphan).await.unwrap();
        let identity = Arc::new(DeviceIdentity::load_or_create(keys.as_ref()).await.unwrap());
        let control =
            Arc::new(SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap());
        let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0))));
        let manager = PairingManager::new(
            identity,
            keys.clone(),
            control,
            discovery,
            PairingBind {
                ip: "127.0.0.1".parse().unwrap(),
                ports: PairingPorts::Ephemeral,
            },
        )
        .unwrap();

        let (secret, metadata) = manager.ensure_discovery_secret(true).await.unwrap();
        assert_eq!(metadata.epoch, 1);
        assert_ne!(
            secret, orphan,
            "the other dataset's group must not be joined by accident"
        );
        assert_eq!(
            keys.load_discovery_group_secret().await.unwrap(),
            Some(secret.clone())
        );

        // Now that the epoch row exists, the secret is stable across calls.
        let (again, metadata_again) = manager.ensure_discovery_secret(true).await.unwrap();
        assert_eq!(again, secret);
        assert_eq!(metadata_again.epoch, metadata.epoch);
    }

    /// Pairing beacons carry no identity, so an already-paired device is
    /// recognised by the address it answers on, not by who it says it is.
    #[tokio::test]
    async fn trusted_device_addresses_cover_known_endpoints_only() {
        let (manager, _discovery, _directory) = manager(73).await;
        let peer_key = PrivateDeviceKey::generate().public_key();
        let peer = DeviceId::from_public_key(peer_key.as_bytes());
        manager
            .establish_trust(peer_key, "laptop".into(), 1_000)
            .unwrap();
        assert!(
            manager.trusted_device_addresses().unwrap().is_empty(),
            "a trusted device with no known endpoint suppresses nothing"
        );

        manager
            .control
            .store_peer_connection(&crate::control::PeerConnectionMetadata {
                device_id: peer,
                state: crate::routing::PeerConnectionState::Connected,
                endpoint: Some("192.168.0.22:34729".parse().unwrap()),
                updated_at_ms: 1_000,
            })
            .unwrap();
        let addresses = manager.trusted_device_addresses().unwrap();
        assert_eq!(
            addresses,
            vec!["192.168.0.22".parse::<std::net::IpAddr>().unwrap()]
        );
        assert!(manager.is_trusted(peer).unwrap());

        // A revoked device stops suppressing its own address.
        manager.revoke(peer, 2_000).unwrap();
        assert!(manager.trusted_device_addresses().unwrap().is_empty());
        assert!(!manager.is_trusted(peer).unwrap());
    }

    /// Re-pairing an already-trusted peer updates its record; it must not
    /// insert a second one or reset when the pairing began.
    #[tokio::test]
    async fn re_establishing_trust_updates_the_existing_record() {
        let (manager, _discovery, _directory) = manager(74).await;
        let peer_key = PrivateDeviceKey::generate().public_key();
        let peer = DeviceId::from_public_key(peer_key.as_bytes());
        manager
            .establish_trust(peer_key, "laptop".into(), 1_000)
            .unwrap();
        assert_eq!(manager.trusted_devices().unwrap()[0].nickname, None);
        assert!(manager.rename(peer, "Work laptop").unwrap());
        manager
            .establish_trust(peer_key, "laptop renamed".into(), 5_000)
            .unwrap();
        let trusted = manager.trusted_devices().unwrap();
        assert_eq!(trusted.len(), 1);
        assert_eq!(trusted[0].device_id, peer);
        assert_eq!(trusted[0].announced_name, "laptop renamed");
        assert_eq!(
            trusted[0].nickname.as_deref(),
            Some("Work laptop"),
            "a re-pair keeps the nickname"
        );
        assert_eq!(
            trusted[0].paired_at_ms, 1_000,
            "the original pairing time survives a re-pair"
        );
    }

    /// The peer finished its commit and reported success; this side stored
    /// trust, journalled `AwaitingAcknowledgement`, and then failed. The entry
    /// must stay resumable and must not fork the trust record.
    #[tokio::test]
    async fn a_failed_commit_stays_resumable_without_duplicating_trust() {
        let (manager, _discovery, _directory) = manager(71).await;
        let peer_key = PrivateDeviceKey::generate().public_key();
        let peer = DeviceId::from_public_key(peer_key.as_bytes());
        let session = [7; 16];

        manager
            .establish_trust(peer_key, "phone".into(), 1_000)
            .unwrap();
        manager
            .control
            .store_pairing_journal(&PairingJournalRecord {
                session_id: session,
                peer_device_id: peer,
                stage: PairingJournalStage::AwaitingAcknowledgement,
                joining_root: None,
                failure_reason: None,
                updated_at_ms: 1_000,
            })
            .unwrap();
        manager
            .control
            .record_pairing_journal_failure(session, "secure key store is locked", 1_100)
            .unwrap();

        let recorded = manager.control.pairing_journal(session).unwrap().unwrap();
        assert_eq!(recorded.stage, PairingJournalStage::AwaitingAcknowledgement);
        assert_eq!(
            recorded.failure_reason.as_deref(),
            Some("secure key store is locked"),
            "the session is incomplete with its reason, not rolled back"
        );
        assert_eq!(
            manager.trusted_devices().unwrap().len(),
            1,
            "trust is kept: the peer legitimately holds trust for us"
        );

        // The next authenticated connection finishes it, with no second record
        // and no contradictory outcome.
        assert!(manager.resume_incomplete_commit(peer, 2_000).unwrap());
        let resumed = manager.control.pairing_journal(session).unwrap().unwrap();
        assert_eq!(resumed.stage, PairingJournalStage::Complete);
        assert_eq!(resumed.failure_reason, None);
        let trusted = manager.trusted_devices().unwrap();
        assert_eq!(trusted.len(), 1);
        assert_eq!(trusted[0].device_id, peer);
        assert_eq!(trusted[0].state, TrustState::Trusted);

        // Idempotent: a later reconnection finds nothing left to resume.
        assert!(!manager.resume_incomplete_commit(peer, 3_000).unwrap());
    }

    /// The sync channel comes up mid-commit, so the reconnect hook meets a
    /// session that is still running. Completing its journal there would race
    /// the commit and mask a failure it has not reached yet.
    #[tokio::test]
    async fn a_live_session_is_never_resumed_from_under_its_own_commit() {
        let (a, _, _a_dir) = manager(76).await;
        let (b, _, _b_dir) = manager(77).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        a.set_root_state(RootState::Ready(root));
        let a_instance = a.start(window, "A".into()).await.unwrap();
        b.set_root_state(RootState::Ready(root));
        let b_instance = b.start(window, "B".into()).await.unwrap();
        let candidate = PairingCandidate {
            instance_id: b_instance,
            endpoint: b.local_addr().unwrap(),
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
        let (a_plan, b_plan) = tokio::join!(a.confirm(a_session), b.confirm(b_session));
        let a_plan = a_plan.unwrap();
        b_plan.unwrap();
        let peer = a_plan.peer_device_id;

        // Mid-commit: trust and the journal are already durable, and the peer
        // has just come up on the sync channel.
        a.establish_trust(a_plan.peer_public_key, "B".into(), 1_000)
            .unwrap();
        a.journal(&a_plan, PairingJournalStage::AwaitingAcknowledgement, None)
            .unwrap();
        assert!(
            !a.resume_incomplete_commit(peer, 2_000).unwrap(),
            "the running commit owns this session"
        );
        assert_eq!(
            a.control
                .pairing_journal(a_session.0)
                .unwrap()
                .unwrap()
                .stage,
            PairingJournalStage::AwaitingAcknowledgement,
            "the journal is left for the commit to finish"
        );

        // Once the session is gone, an entry it never completed is resumable.
        a.finish_trust(&a_plan, 10).unwrap();
        a.journal(&a_plan, PairingJournalStage::AwaitingAcknowledgement, None)
            .unwrap();
        assert!(a.resume_incomplete_commit(peer, 3_000).unwrap());
        assert_eq!(
            a.control
                .pairing_journal(a_session.0)
                .unwrap()
                .unwrap()
                .stage,
            PairingJournalStage::Complete
        );
    }

    /// A failure before trust was stored has nothing to reconcile, so it must
    /// not be silently "completed" on the next connection.
    #[tokio::test]
    async fn an_early_failure_is_not_resumable() {
        let (manager, _discovery, _directory) = manager(72).await;
        let peer_key = PrivateDeviceKey::generate().public_key();
        let peer = DeviceId::from_public_key(peer_key.as_bytes());
        manager
            .control
            .store_pairing_journal(&PairingJournalRecord {
                session_id: [8; 16],
                peer_device_id: peer,
                stage: PairingJournalStage::Confirmed,
                joining_root: None,
                failure_reason: Some("secure key store is locked".into()),
                updated_at_ms: 1_000,
            })
            .unwrap();
        assert!(!manager.resume_incomplete_commit(peer, 2_000).unwrap());
        assert!(manager.trusted_devices().unwrap().is_empty());
    }

    async fn manager(
        seed: u8,
    ) -> (
        Arc<PairingManager>,
        Arc<FakeDiscoveryProvider>,
        tempfile::TempDir,
    ) {
        manager_with_keys(Arc::new(InMemorySecureKeyStore::seeded([seed; 32]))).await
    }

    async fn manager_with_keys(
        keys: Arc<dyn SecureKeyStore>,
    ) -> (
        Arc<PairingManager>,
        Arc<FakeDiscoveryProvider>,
        tempfile::TempDir,
    ) {
        let directory = tempfile::tempdir().unwrap();
        let identity = Arc::new(DeviceIdentity::load_or_create(keys.as_ref()).await.unwrap());
        let control =
            Arc::new(SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap());
        let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0))));
        let manager = PairingManager::new(
            identity,
            keys,
            control,
            discovery.clone(),
            PairingBind {
                ip: "127.0.0.1".parse().unwrap(),
                ports: PairingPorts::Ephemeral,
            },
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
            endpoint: b.local_addr().unwrap(),
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
        assert_eq!(a.local_addr(), Err(PairingError::Inactive));
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
        assert_eq!(a.local_addr(), Err(PairingError::Inactive));
    }

    fn port_is_free(port: u16) -> bool {
        std::net::UdpSocket::bind(("127.0.0.1", port)).is_ok()
    }

    /// A closed QUIC endpoint drops its socket once its driver winds down.
    async fn port_becomes_free(port: u16) -> bool {
        for _ in 0..100 {
            if port_is_free(port) {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        false
    }

    #[tokio::test]
    async fn pairing_socket_is_released_when_the_window_ends() {
        let (a, _, _a_dir) = manager(14).await;
        a.start(Duration::from_secs(5), "A".into()).await.unwrap();
        let port = a.local_addr().unwrap().port();
        a.stop().await.unwrap();
        assert_eq!(a.local_addr(), Err(PairingError::Inactive));
        assert!(
            port_becomes_free(port).await,
            "stop releases the pairing port"
        );

        a.start(Duration::from_millis(20), "A".into())
            .await
            .unwrap();
        let port = a.local_addr().unwrap().port();
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert_eq!(a.local_addr(), Err(PairingError::Inactive));
        assert!(
            port_becomes_free(port).await,
            "expiry releases the pairing port"
        );

        let (b, _, _b_dir) = manager(15).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        a.set_root_state(RootState::Ready(root));
        b.set_root_state(RootState::Ready(root));
        a.start(window, "A".into()).await.unwrap();
        let b_instance = b.start(window, "B".into()).await.unwrap();
        let (a_port, b_port) = (
            a.local_addr().unwrap().port(),
            b.local_addr().unwrap().port(),
        );
        let a_session = a
            .connect(candidate_for(&b, b_instance), "A".into(), window)
            .await
            .unwrap();
        let b_session = await_sas(&b).await;
        let (a_plan, b_plan) = tokio::join!(a.confirm(a_session), b.confirm(b_session));
        a.finish_trust(&a_plan.unwrap(), 10).unwrap();
        b.finish_trust(&b_plan.unwrap(), 10).unwrap();
        assert_eq!(a.local_addr(), Err(PairingError::Inactive));
        assert_eq!(b.local_addr(), Err(PairingError::Inactive));
        assert!(port_becomes_free(a_port).await && port_becomes_free(b_port).await);
    }

    /// Three consecutive free loopback UDP ports.
    fn free_port_triple() -> u16 {
        loop {
            let probe = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
            let first = probe.local_addr().unwrap().port();
            drop(probe);
            if first < u16::MAX - 2 && (first..=first + 2).all(port_is_free) {
                return first;
            }
        }
    }

    #[tokio::test]
    async fn range_skips_the_sync_port_and_reports_exhaustion() {
        let keys: Arc<dyn SecureKeyStore> = Arc::new(InMemorySecureKeyStore::seeded([16; 32]));
        let directory = tempfile::tempdir().unwrap();
        let identity = Arc::new(DeviceIdentity::load_or_create(keys.as_ref()).await.unwrap());
        let control =
            Arc::new(SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap());
        let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0))));
        let first = free_port_triple();
        let last = first + 2;
        let _middle = std::net::UdpSocket::bind(("127.0.0.1", first + 1)).unwrap();
        let manager = PairingManager::new(
            identity,
            keys,
            control,
            discovery.clone(),
            PairingBind {
                ip: "127.0.0.1".parse().unwrap(),
                ports: PairingPorts::Range {
                    range: first..=last,
                    exclude: first,
                },
            },
        )
        .unwrap();
        manager
            .start(Duration::from_secs(5), "A".into())
            .await
            .unwrap();
        assert_eq!(manager.local_addr().unwrap().port(), last);
        manager.stop().await.unwrap();
        assert!(port_becomes_free(last).await);
        let _last = std::net::UdpSocket::bind(("127.0.0.1", last)).unwrap();
        assert_eq!(
            manager.start(Duration::from_secs(5), "A".into()).await,
            Err(PairingError::PortsExhausted { first, last })
        );
        assert!(discovery.advertisements().is_empty());
        assert_eq!(manager.state(), PairingState::Idle);
    }

    #[tokio::test]
    async fn disabled_normal_discovery_survives_rotation_and_leaves_pairing_alone() {
        let (manager, discovery, _directory) = manager(19).await;
        manager.ensure_discovery_secret(true).await.unwrap();
        manager.set_normal_discovery_enabled(false);
        assert!(!manager.start_normal_discovery(41021).await.unwrap());
        let epoch = manager
            .rotate_discovery_secret(41021, now_ms(), 60_000)
            .await
            .unwrap();
        assert_eq!(epoch, 2);
        assert_eq!(
            manager.control.discovery_metadata().unwrap().unwrap().epoch,
            2
        );
        assert!(manager.normal_scope.lock().unwrap().is_none());
        assert!(discovery.advertisements().is_empty());
        assert!(discovery.browsing_scopes().is_empty());

        manager.set_root_state(RootState::NeedsDecision);
        manager
            .start(Duration::from_secs(5), "A".into())
            .await
            .unwrap();
        assert_eq!(discovery.advertisements().len(), 1);
        assert!(manager.normal_scope.lock().unwrap().is_none());

        manager.set_normal_discovery_enabled(true);
        assert!(manager.start_normal_discovery(41021).await.unwrap());
        assert!(manager.normal_scope.lock().unwrap().is_some());
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
                    announced_name: "peer".into(),
                    nickname: None,
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

    /// Platform store double that keeps the latest durable value of each slot.
    #[derive(Default)]
    struct RecordingPlatform {
        writes: std::sync::Mutex<Vec<String>>,
        current: std::sync::Mutex<Option<[u8; 32]>>,
        previous: std::sync::Mutex<Option<(u64, [u8; 32])>>,
        fail: std::sync::atomic::AtomicBool,
    }

    #[async_trait::async_trait]
    impl PlatformSecretPersistence for RecordingPlatform {
        async fn persist(&self, write: PlatformSecretWrite<'_>) -> Result<(), SecureStoreError> {
            if self.fail.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(SecureStoreError::Unavailable("platform refused".into()));
            }
            self.writes.lock().unwrap().push(format!("{write:?}"));
            match write {
                PlatformSecretWrite::StoreCurrent(secret) => {
                    *self.current.lock().unwrap() = Some(*secret.expose());
                }
                PlatformSecretWrite::RemoveCurrent => *self.current.lock().unwrap() = None,
                PlatformSecretWrite::StorePrevious { epoch, secret } => {
                    *self.previous.lock().unwrap() = Some((epoch, *secret.expose()));
                }
                PlatformSecretWrite::RemovePrevious => *self.previous.lock().unwrap() = None,
            }
            Ok(())
        }
    }

    async fn rotation_pair(
        recipient_seed: u8,
    ) -> (
        Arc<PairingManager>,
        Arc<PairingManager>,
        Arc<RecordingPlatform>,
        DiscoveryGroupSecret,
        [tempfile::TempDir; 2],
    ) {
        let (sender, _, sender_directory) = manager(recipient_seed + 1).await;
        let platform = Arc::new(RecordingPlatform::default());
        let (recipient, _, recipient_directory) =
            manager_with_keys(Arc::new(WriteThroughSecureKeyStore::new(
                InMemorySecureKeyStore::seeded([recipient_seed; 32]),
                platform.clone(),
            )))
            .await;
        let shared = DiscoveryGroupSecret::from_bytes([93; 32]);
        let metadata = DiscoveryGroupMetadata {
            epoch: 1,
            updated_at_ms: 1,
        };
        for (port, manager) in [(41030, &sender), (41031, &recipient)] {
            manager
                .keys
                .store_discovery_group_secret(&shared)
                .await
                .unwrap();
            manager.control.store_discovery_metadata(metadata).unwrap();
            manager.start_normal_discovery(port).await.unwrap();
        }
        for (local, peer) in [(&sender, &recipient), (&recipient, &sender)] {
            local
                .control
                .upsert_peer_trust(&PeerTrustRecord {
                    device_id: peer.identity.id(),
                    public_key: peer.identity.public_key(),
                    state: TrustState::Trusted,
                    updated_at_ms: 1,
                    last_seen_ms: None,
                })
                .unwrap();
            local
                .control
                .upsert_trusted_device(&TrustedDeviceRecord {
                    device_id: peer.identity.id(),
                    public_key: peer.identity.public_key(),
                    announced_name: "peer".into(),
                    nickname: None,
                    paired_at_ms: 1,
                    last_seen_ms: None,
                    last_sync_ms: None,
                    state: TrustState::Trusted,
                })
                .unwrap();
        }
        platform.writes.lock().unwrap().clear();
        (
            sender,
            recipient,
            platform,
            shared,
            [sender_directory, recipient_directory],
        )
    }

    #[tokio::test]
    async fn inbound_rotation_is_persisted_before_ack() {
        let (sender, recipient, platform, shared, _directories) = rotation_pair(44).await;
        sender
            .rotate_discovery_secret(41030, now_ms(), 60_000)
            .await
            .unwrap();
        let (_, frame) = sender.rotation_update_frames().unwrap()[0];
        let ack = recipient
            .accept_rotation_update(sender.identity.id(), &frame)
            .await
            .unwrap();
        assert_eq!(sender.validate_rotation_ack(&ack).await.unwrap(), 2);

        assert_eq!(
            *platform.writes.lock().unwrap(),
            ["StorePrevious { epoch: 1, .. }", "StoreCurrent"]
        );
        assert_eq!(
            *platform.previous.lock().unwrap(),
            Some((1, *shared.expose()))
        );
        let sender_secret = sender.discovery_secret().await.unwrap().unwrap();
        let durable = platform.current.lock().unwrap().unwrap();
        assert_eq!(&durable, sender_secret.expose());

        // A restart seeds a fresh store from the platform values only.
        let restarted = InMemorySecureKeyStore::seeded([44; 32]);
        restarted
            .store_discovery_group_secret(&DiscoveryGroupSecret::from_bytes(durable))
            .await
            .unwrap();
        let reloaded = restarted
            .load_discovery_group_secret()
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            crate::discovery::group_service_selector(&reloaded, 2),
            crate::discovery::group_service_selector(&sender_secret, 2)
        );
    }

    #[tokio::test]
    async fn inbound_rotation_not_acknowledged_when_persist_fails() {
        let (sender, recipient, platform, _shared, _directories) = rotation_pair(46).await;
        sender
            .rotate_discovery_secret(41030, now_ms(), 60_000)
            .await
            .unwrap();
        let (_, frame) = sender.rotation_update_frames().unwrap()[0];
        platform
            .fail
            .store(true, std::sync::atomic::Ordering::SeqCst);
        assert!(
            recipient
                .accept_rotation_update(sender.identity.id(), &frame)
                .await
                .is_err()
        );
        assert_eq!(
            recipient
                .control
                .discovery_metadata()
                .unwrap()
                .unwrap()
                .epoch,
            1
        );

        platform
            .fail
            .store(false, std::sync::atomic::Ordering::SeqCst);
        let ack = recipient
            .accept_rotation_update(sender.identity.id(), &frame)
            .await
            .unwrap();
        assert_eq!(sender.validate_rotation_ack(&ack).await.unwrap(), 2);
        assert_eq!(
            recipient
                .control
                .discovery_metadata()
                .unwrap()
                .unwrap()
                .epoch,
            2
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn group_record_rejections_are_logged() {
        use crate::diagnostics::{RecentEvents, RecentEventsLayer};
        use tracing_subscriber::layer::SubscriberExt;

        let retained = Arc::new(RecentEvents::new(1000));
        let _guard = tracing::subscriber::set_default(
            tracing_subscriber::registry().with(RecentEventsLayer::with_buffer(retained.clone())),
        );
        let (revoked, _, _revoked_directory) = manager(51).await;
        let (stranger, _, _stranger_directory) = manager(52).await;
        let (manager, discovery, _directory) = manager(50).await;
        let secret = DiscoveryGroupSecret::from_bytes([94; 32]);
        manager
            .keys
            .store_discovery_group_secret(&secret)
            .await
            .unwrap();
        manager
            .control
            .store_discovery_metadata(DiscoveryGroupMetadata {
                epoch: 1,
                updated_at_ms: 1,
            })
            .unwrap();
        manager
            .control
            .upsert_trusted_device(&TrustedDeviceRecord {
                device_id: revoked.identity.id(),
                public_key: revoked.identity.public_key(),
                announced_name: "revoked".into(),
                nickname: None,
                paired_at_ms: 1,
                last_seen_ms: None,
                last_sync_ms: None,
                state: TrustState::Revoked,
            })
            .unwrap();
        manager.start_normal_discovery(41040).await.unwrap();

        let foreign = DiscoveryGroupSecret::from_bytes([95; 32]);
        let record = |secret: &DiscoveryGroupSecret, device: DeviceId, name: &str| {
            DiscoveryAdvertisement::group(
                group_service_selector(secret, 1),
                1,
                group_routing_token(secret, 1, device),
                discovery_secret_fingerprint(secret),
                name.into(),
                41041,
                60_000,
            )
        };
        let loopback: std::net::IpAddr = "127.0.0.1".parse().unwrap();
        // The manager binds loopback, so only loopback peers are dialable.
        let lan: std::net::IpAddr = "192.168.1.30".parse().unwrap();
        let cases = [
            (record(&secret, revoked.identity.id(), "revoked"), loopback),
            (
                record(&secret, stranger.identity.id(), "stranger"),
                loopback,
            ),
            (record(&foreign, revoked.identity.id(), "foreign"), loopback),
            (record(&secret, revoked.identity.id(), "far"), lan),
            (record(&secret, manager.identity.id(), "own"), loopback),
        ];
        let field = |event: &crate::diagnostics::LogEvent, name: &str| {
            event
                .fields
                .iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
                .unwrap_or_default()
        };
        let rejections = || {
            retained
                .all()
                .into_iter()
                .filter(|event| event.event.as_deref() == Some("discovery_group_record_rejected"))
                .collect::<Vec<_>>()
        };
        let logged = |instance: &str| {
            rejections()
                .iter()
                .find(|event| field(event, "instance") == instance)
                .cloned()
        };
        // Parallel tests without a subscriber can race this test's callsite
        // registration and leave an event disabled; re-resolve until each
        // record has been logged once.
        for _ in 0..200 {
            let missing: Vec<_> = cases
                .iter()
                .filter(|(advertisement, _)| logged(&advertisement.instance_name).is_none())
                .collect();
            if missing.is_empty() {
                break;
            }
            tracing::callsite::rebuild_interest_cache();
            for (advertisement, address) in missing {
                discovery.resolve(advertisement, *address).unwrap();
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        let observed: Vec<_> = cases
            .iter()
            .filter_map(|(advertisement, _)| logged(&advertisement.instance_name))
            .map(|event| {
                (
                    field(&event, "instance"),
                    field(&event, "reason"),
                    event.level.clone(),
                    event.device_id.clone(),
                )
            })
            .collect();
        let info = |instance: &str, reason: &str, device: Option<String>| {
            (
                instance.to_owned(),
                reason.to_owned(),
                "INFO".to_owned(),
                device,
            )
        };
        assert_eq!(
            observed,
            [
                info(
                    "revoked",
                    "untrusted",
                    Some(revoked.identity.id().to_string())
                ),
                info("stranger", "token", None),
                info("foreign", "selector", None),
                info("far", "address", None),
                // Own records stay below info.
                ("own".into(), "own".into(), "DEBUG".into(), None),
            ]
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
                    endpoint: b.local_addr().unwrap(),
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
                    endpoint: b.local_addr().unwrap(),
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

    fn loopback_bind() -> PairingBind {
        PairingBind {
            ip: "127.0.0.1".parse().unwrap(),
            ports: PairingPorts::Ephemeral,
        }
    }

    fn rogue_transport(identity: &DeviceIdentity) -> PairingTransport {
        PairingTransport::bind(
            "127.0.0.1:0".parse().unwrap(),
            identity,
            AddressPolicy::for_bind("127.0.0.1".parse().unwrap()),
        )
        .unwrap()
    }

    async fn rogue_identity(seed: u8) -> DeviceIdentity {
        DeviceIdentity::load_or_create(&InMemorySecureKeyStore::seeded([seed; 32]))
            .await
            .unwrap()
    }

    /// Waits until `connection` is closed and returns the application close code.
    async fn closed_code(connection: &PairingConnection) -> Option<u64> {
        let _ = tokio::time::timeout(Duration::from_secs(3), connection.accept_stream()).await;
        connection.close_code()
    }

    /// The target survived a failed inbound: still discoverable with its
    /// original deadline, no trust, and a legitimate peer reaches the SAS.
    async fn assert_window_survives(target: &Arc<PairingManager>, deadline: u64, seed: u8) {
        let PairingState::Discoverable {
            instance_id,
            deadline_ms,
        } = target.state()
        else {
            panic!("target stays discoverable: {:?}", target.state());
        };
        assert_eq!(deadline_ms, deadline);
        assert!(target.trusted_devices().unwrap().is_empty());
        let (peer, _, _peer_dir) = manager(seed).await;
        peer.set_root_state(target.root_state());
        let window = Duration::from_secs(5);
        peer.start(window, "peer".into()).await.unwrap();
        let session = peer
            .connect(candidate_for(target, instance_id), "peer".into(), window)
            .await
            .unwrap();
        assert_eq!(await_sas(target).await, session);
        assert!(matches!(
            peer.state(),
            PairingState::AwaitingConfirmation { .. }
        ));
    }

    async fn discoverable_target(seed: u8) -> (Arc<PairingManager>, u64, tempfile::TempDir) {
        let (target, _, directory) = manager(seed).await;
        target.set_root_state(RootState::Ready(automerge_repo::DocumentId::new()));
        target
            .start(Duration::from_secs(10), "target".into())
            .await
            .unwrap();
        let PairingState::Discoverable { deadline_ms, .. } = target.state() else {
            panic!("target is discoverable");
        };
        (target, deadline_ms, directory)
    }

    #[tokio::test]
    async fn hello_key_mismatch_never_displays_sas_or_creates_trust() {
        let (target, deadline, _target_dir) = discoverable_target(41).await;
        let rogue_identity = rogue_identity(42).await;
        let rogue = rogue_transport(&rogue_identity);
        let connection = rogue.connect(target.local_addr().unwrap()).await.unwrap();
        let mut stream = connection.open_stream().await.unwrap();
        let mismatched = PrivateDeviceKey::from_seed(&[43; 32]).unwrap().public_key();
        stream
            .send(&PairingMessage::Hello(make_hello(
                PairingRole::Initiator,
                PairingInstanceId::from_bytes([1; 16]),
                mismatched,
                "rogue".into(),
                target.root_state(),
            )))
            .await
            .unwrap();
        assert_eq!(closed_code(&connection).await, Some(2));
        assert_window_survives(&target, deadline, 44).await;
    }

    #[tokio::test]
    async fn malformed_inbound_hello_keeps_the_window_open() {
        let (target, deadline, _target_dir) = discoverable_target(61).await;
        let rogue_identity = rogue_identity(62).await;
        let rogue = rogue_transport(&rogue_identity);
        let connection = rogue.connect(target.local_addr().unwrap()).await.unwrap();
        let mut stream = connection.open_stream().await.unwrap();
        let keys = derive_pairing_keys(b"transcript", &[0; 32]).unwrap();
        stream
            .send(&PairingMessage::Decision(sign_decision(
                &keys,
                PairingRole::Initiator,
                PairingSessionId([1; 16]),
                PairingDecisionKind::Reject,
            )))
            .await
            .unwrap();
        assert_eq!(closed_code(&connection).await, Some(2));
        assert_window_survives(&target, deadline, 63).await;
    }

    #[tokio::test]
    async fn stalled_inbound_is_cut_off_and_the_window_survives() {
        let (target, deadline, _target_dir) = discoverable_target(64).await;
        target.set_inbound_hello_timeout(Duration::from_millis(200));
        let rogue_identity = rogue_identity(65).await;
        let rogue = rogue_transport(&rogue_identity);
        let connection = rogue.connect(target.local_addr().unwrap()).await.unwrap();
        let _stream = connection.open_stream().await.unwrap();
        assert_eq!(closed_code(&connection).await, Some(2));
        assert_window_survives(&target, deadline, 66).await;
    }

    #[tokio::test]
    async fn non_lan_inbound_is_dropped_without_affecting_the_window() {
        let keys: Arc<dyn SecureKeyStore> = Arc::new(InMemorySecureKeyStore::seeded([67; 32]));
        let directory = tempfile::tempdir().unwrap();
        let identity = Arc::new(DeviceIdentity::load_or_create(keys.as_ref()).await.unwrap());
        let control =
            Arc::new(SqliteControlStore::open(directory.path().join("control.sqlite")).unwrap());
        let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0))));
        let target = PairingManager::new(
            identity,
            keys,
            control,
            discovery,
            PairingBind {
                ip: "0.0.0.0".parse().unwrap(),
                ports: PairingPorts::Ephemeral,
            },
        )
        .unwrap();
        target
            .start(Duration::from_secs(10), "target".into())
            .await
            .unwrap();
        let port = target.local_addr().unwrap().port();
        let rogue_identity = rogue_identity(68).await;
        let rogue = rogue_transport(&rogue_identity);
        let outcome = tokio::time::timeout(
            Duration::from_secs(2),
            rogue.connect(([127, 0, 0, 1], port).into()),
        )
        .await;
        assert!(
            matches!(outcome, Err(_) | Ok(Err(_))),
            "dial must not complete"
        );
        assert!(matches!(target.state(), PairingState::Discoverable { .. }));
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
                    endpoint: b.local_addr().unwrap(),
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

    /// The peer's own deadline closes the connection at the moment the local
    /// session expires. That close is the expiry, not a transport failure.
    #[tokio::test]
    async fn peer_close_at_the_deadline_reports_expiry() {
        let (a, _, _a_dir) = manager(47).await;
        let (b, _, _b_dir) = manager(48).await;
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
                    endpoint: b.local_addr().unwrap(),
                    expires_at_ms: now_ms() + 5_000,
                },
                "A".into(),
                Duration::from_millis(500),
            )
            .await
            .unwrap();
        let active = a.session(session).unwrap();
        let deadline_ms = active.deadline_ms;
        let lost = || PairingError::Transport("connection lost".into());
        let peer = b.clone();
        let close = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(deadline_ms.saturating_sub(now_ms()))).await;
            peer.stop().await.unwrap();
        });
        let error = a.confirm(session).await.unwrap_err();
        close.await.unwrap();
        assert_eq!(error, PairingError::Expired);
        assert_eq!(
            a.state(),
            PairingState::Failed {
                error: PairingError::Expired
            }
        );
        // The classification itself does not depend on which timer won.
        assert_eq!(a.at_deadline(&active, lost()), PairingError::Expired);
        assert!(a.trusted_devices().unwrap().is_empty());
        assert!(b.trusted_devices().unwrap().is_empty());
    }

    /// A connection lost well before the deadline stays a transport failure.
    #[tokio::test]
    async fn peer_close_before_the_deadline_reports_transport_failure() {
        let (a, _, _a_dir) = manager(49).await;
        let (b, _, _b_dir) = manager(50).await;
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
                    endpoint: b.local_addr().unwrap(),
                    expires_at_ms: now_ms() + 5_000,
                },
                "A".into(),
                window,
            )
            .await
            .unwrap();
        let active = a.session(session).unwrap();
        assert!(matches!(
            a.at_deadline(&active, PairingError::Transport("connection lost".into())),
            PairingError::Transport(_)
        ));
        b.stop().await.unwrap();
        let error = a.confirm(session).await.unwrap_err();
        assert!(matches!(error, PairingError::Transport(_)), "{error}");
        assert!(matches!(
            a.state(),
            PairingState::Failed {
                error: PairingError::Transport(_)
            }
        ));
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
            loopback_bind(),
        )
        .unwrap();
        let b = PairingManager::new(
            identity_b.clone(),
            keys_b,
            Arc::new(SqliteControlStore::open(directory_b.path().join("control.sqlite")).unwrap()),
            provider.clone(),
            loopback_bind(),
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
            endpoint: manager.local_addr().unwrap(),
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
        a.select(candidate_for(&b, b_instance), Duration::from_secs(4))
            .unwrap();
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
        // The mismatch is an inbound pre-SAS failure: the responder refuses that
        // connection and stays discoverable.
        let state = a.subscribe_state();
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if matches!(state.borrow().clone(), PairingState::Discoverable { .. })
                    && a.sessions.lock().unwrap().is_empty()
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
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
