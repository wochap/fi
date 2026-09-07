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
        DiscoveryGroupMetadata, PairingJournalRecord, PairingJournalStage, PeerTrustRecord,
        TrustState, TrustedDeviceRecord,
    },
    discovery::{
        DEFAULT_RECORD_TTL_MS, DiscoveryAdvertisement, DiscoveryEvent, DiscoveryGroupSecret,
        DiscoveryProvider, DiscoveryScope, PairingInstanceId, group_routing_token,
        group_service_selector, match_group_endpoint,
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
    group_tx: watch::Sender<Option<(DiscoveryGroupSecret, u64)>>,
    normal_scope: Mutex<Option<DiscoveryScope>>,
    deadline: Mutex<Option<JoinHandle<()>>>,
    accept_task: Mutex<Option<JoinHandle<()>>>,
    sessions: Mutex<HashMap<PairingSessionId, Arc<ActivePairingSession>>>,
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
        let (state_tx, _) = watch::channel(PairingState::Idle);
        let (candidates_tx, _) = watch::channel(Vec::new());
        let (events, _) = broadcast::channel(128);
        let (normal_events, _) = broadcast::channel(128);
        let (group_tx, group_rx) = watch::channel(None);
        let mut discovered = discovery.subscribe();
        let own_state = state_tx.subscribe();
        let candidates = candidates_tx.clone();
        let control_for_discovery = control.clone();
        let normal_events_for_discovery = normal_events.clone();
        let discovery_task = tokio::spawn(async move {
            let mut by_instance = BTreeMap::new();
            let mut names = HashMap::new();
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
                        by_instance.insert(
                            instance,
                            PairingCandidate {
                                instance_id: instance,
                                endpoint: endpoint.address,
                                expires_at_ms: endpoint.expires_at_ms,
                            },
                        );
                        names.insert(endpoint.instance_name, instance);
                    }
                    DiscoveryEvent::Expired {
                        scope: DiscoveryScope::Pairing,
                        instance_name,
                    } => {
                        if let Some(instance) = names.remove(&instance_name) {
                            by_instance.remove(&instance);
                        }
                    }
                    DiscoveryEvent::Upsert(endpoint) => {
                        let Some((secret, _)) = group_rx.borrow().clone() else {
                            continue;
                        };
                        let trusted = control_for_discovery
                            .trusted_devices()
                            .unwrap_or_default()
                            .into_iter()
                            .filter(|record| record.state == TrustState::Trusted)
                            .map(|record| record.device_id);
                        if let Some((peer, address, expires_at_ms)) =
                            match_group_endpoint(&endpoint, &secret, trusted)
                        {
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
                let now = now_ms();
                by_instance.retain(|_, candidate| candidate.expires_at_ms > now);
                candidates.send_replace(by_instance.values().cloned().collect());
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
            normal_scope: Mutex::new(None),
            deadline: Mutex::new(None),
            accept_task: Mutex::new(None),
            sessions: Mutex::new(HashMap::new()),
            discovery_task,
        }))
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
    #[must_use]
    pub fn subscribe_normal_discovery(&self) -> broadcast::Receiver<NormalDiscoveryEvent> {
        self.normal_events.subscribe()
    }
    pub fn local_addr(&self) -> Result<std::net::SocketAddr, PairingError> {
        self.transport.local_addr()
    }

    pub async fn start(
        self: &Arc<Self>,
        duration: Duration,
        friendly_name: String,
        root_state: RootState,
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
        let manager = self.clone();
        *self
            .accept_task
            .lock()
            .map_err(|_| PairingError::Transport("accept lock poisoned".into()))? =
            Some(tokio::spawn(async move {
                if manager.state_is_active() {
                    let Ok(connection) = manager.transport.accept().await else {
                        return;
                    };
                    match manager
                        .accept_handshake(connection, friendly_name.clone(), root_state.clone())
                        .await
                    {
                        Ok(_) => {}
                        Err(error) => {
                            manager.fail(error).await;
                        }
                    }
                }
            }));
        Ok(instance)
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
        sas: String,
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
        root_state: RootState,
        duration: Duration,
    ) -> Result<PairingSessionId, PairingError> {
        let result = self
            .connect_inner(candidate, friendly_name, root_state, duration)
            .await;
        if let Err(error) = &result {
            self.fail(error.clone()).await;
        }
        result
    }

    async fn connect_inner(
        &self,
        candidate: PairingCandidate,
        friendly_name: String,
        root_state: RootState,
        duration: Duration,
    ) -> Result<PairingSessionId, PairingError> {
        let (local_instance, window_deadline) = match self.state() {
            PairingState::Discoverable {
                instance_id,
                deadline_ms,
            } => (instance_id, deadline_ms),
            _ => return Err(PairingError::Inactive),
        };
        let session_id = pairing_session_id(local_instance, candidate.instance_id);
        let deadline_ms = now_ms()
            .saturating_add(duration.as_millis().try_into().unwrap_or(u64::MAX))
            .min(window_deadline);
        self.apply(PairingInput::Select {
            session_id,
            candidate: candidate.clone(),
            deadline_ms,
        })?;
        let connection = self.transport.connect(candidate.endpoint).await?;
        let hello = make_hello(
            PairingRole::Initiator,
            local_instance,
            self.identity.public_key(),
            friendly_name,
            root_state,
        );
        let mut stream = connection.open_stream().await?;
        stream.send(&PairingMessage::Hello(hello.clone())).await?;
        let PairingMessage::Hello(peer) = stream.receive().await? else {
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
            self.group_tx
                .send_replace(Some((secret.clone(), metadata.epoch)));
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
        self.group_tx
            .send_replace(Some((secret.clone(), metadata.epoch)));
        Ok((secret, metadata))
    }

    pub async fn install_discovery_secret(
        &self,
        secret: &DiscoveryGroupSecret,
        metadata: DiscoveryGroupMetadata,
    ) -> Result<(), PairingError> {
        self.keys
            .store_discovery_group_secret(secret)
            .await
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.control
            .store_discovery_metadata(metadata)
            .map_err(|error| PairingError::Transport(error.to_string()))?;
        self.group_tx
            .send_replace(Some((secret.clone(), metadata.epoch)));
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
        let metadata = self
            .control
            .discovery_metadata()
            .map_err(|error| PairingError::Transport(error.to_string()))?
            .ok_or(PairingError::Malformed("secret metadata missing"))?;
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
        self.group_tx.send_replace(Some((secret, metadata.epoch)));
        Ok(true)
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

    async fn accept_handshake(
        &self,
        connection: PairingConnection,
        friendly_name: String,
        root_state: RootState,
    ) -> Result<PairingSessionId, PairingError> {
        let (local_instance, window_deadline) = match self.state() {
            PairingState::Discoverable {
                instance_id,
                deadline_ms,
            } => (instance_id, deadline_ms),
            _ => return Err(PairingError::Inactive),
        };
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
        self.apply(PairingInput::Select {
            session_id,
            candidate,
            deadline_ms: window_deadline,
        })?;
        let hello = make_hello(
            PairingRole::Responder,
            local_instance,
            self.identity.public_key(),
            friendly_name,
            root_state,
        );
        stream.send(&PairingMessage::Hello(hello.clone())).await?;
        self.finish_handshake(session_id, connection, stream, hello, peer)
            .await?;
        Ok(session_id)
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
        let a_instance = a
            .start(window, "A".into(), RootState::Ready(root))
            .await
            .unwrap();
        let b_instance = b
            .start(window, "B".into(), RootState::Ready(root))
            .await
            .unwrap();
        let candidate = PairingCandidate {
            instance_id: b_instance,
            endpoint: b.transport.local_addr().unwrap(),
            expires_at_ms: now_ms() + 5_000,
        };
        let a_session = a
            .connect(candidate, "A".into(), RootState::Ready(root), window)
            .await
            .unwrap();
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
        a.start(
            Duration::from_millis(20),
            "A".into(),
            RootState::NeedsDecision,
        )
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
    async fn remote_rejection_never_creates_trust() {
        let (a, _, _a_dir) = manager(31).await;
        let (b, _, _b_dir) = manager(32).await;
        let root = automerge_repo::DocumentId::new();
        let window = Duration::from_secs(5);
        a.start(window, "A".into(), RootState::Ready(root))
            .await
            .unwrap();
        let b_instance = b
            .start(window, "B".into(), RootState::Ready(root))
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
                RootState::Ready(root),
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

        a.start(window, "A".into(), RootState::Ready(root))
            .await
            .unwrap();
        let next_b = b
            .start(window, "B".into(), RootState::Ready(root))
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
                RootState::Ready(root),
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
        target
            .start(
                Duration::from_secs(5),
                "target".into(),
                RootState::Ready(root),
            )
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
        a.start(window, "A".into(), RootState::Ready(root))
            .await
            .unwrap();
        let b_instance = b
            .start(window, "B".into(), RootState::Ready(root))
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
                RootState::Ready(root),
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
}
