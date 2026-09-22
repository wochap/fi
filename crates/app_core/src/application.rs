use std::{
    future::pending,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use automerge_repo::{
    BootstrapStatus, DocHandle, DocumentId, DocumentStatus, PeerId, PeerSyncProgress,
    PeerSyncState, Repo, RepoConfig, network::NetworkTransport,
};
use rand_core::{OsRng, RngCore};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tracing::{error, info, instrument};

use crate::{
    LocalIdentityRecord, ResetIntent,
    adapters::{FileDocumentStore, LocalTransport, SqliteControlStore},
    discovery::DiscoveryGroupSecret,
    error::{AppError, BootstrapError, Result},
    events::{ApplicationState, DataChanged, DomainKind, ErrorEvent, ProjectionState},
    generic::{
        CollectionView, GenericCommand, RecordView, apply_generic_command, decode_generic,
        initialize_generic,
    },
    hlc::{HlcNodeId, HybridLogicalClock, SystemWallTime, WallTime},
    identity::{DeviceId, DeviceIdentity, IdentityError, SecureKeyStore},
    pairing::{
        PairingCandidate, PairingEvent, PairingSessionId, PairingState, ProvisioningData,
        RootCompatibility, RootState,
    },
    pairing_manager::PairingManager,
    projection::{ReadModel, project, reconcile},
    query::{
        CollectionQuery, ComputedFieldDefinition, ComputedFieldId, QueryDefinition, QueryId,
        QueryResult, QueryValidationError, execute_query, validate_query,
    },
    quinn_transport::{QuinnTransport, QuinnTransportConfig},
    records::{GenericRecord, RecordId},
    routing::{ConnectionManager, EndpointRegistry, NetworkEndpoint, PeerConnectionState},
    schema::{
        CollectionSchema, CollectionSchemaId, EnumOption, EnumOptionId, FieldDefinition, FieldId,
    },
    values::FieldValue,
    widget_registry::{ResolvedWidgetQuery, WidgetEvaluation, evaluate_widget},
    widgets::{WidgetDefinition, WidgetId, WidgetUpdate},
};

/// How long an address observed on a live session stays dialable without a
/// fresh advertisement; matches the endpoint installed by `confirm_pairing`.
const OBSERVED_ADDRESS_TTL_MS: u64 = 120_000;

/// Result of [`AppCore::revoke_trusted_device`]. `revoked` reflects the durable
/// record; `rotation_error` is set when the follow-up discovery-secret
/// rotation failed after that record was committed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RevocationOutcome {
    pub revoked: bool,
    pub rotation_error: Option<String>,
}

#[derive(Clone)]
pub struct AppCoreConfig {
    pub command_capacity: usize,
    pub transient_event_capacity: usize,
    pub repo: RepoConfig,
    pub hlc_node_id: Option<HlcNodeId>,
    pub wall_time: Arc<dyn WallTime>,
}

impl std::fmt::Debug for AppCoreConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AppCoreConfig")
            .field("command_capacity", &self.command_capacity)
            .field("transient_event_capacity", &self.transient_event_capacity)
            .field("repo", &self.repo)
            .field("hlc_node_id", &self.hlc_node_id)
            .finish_non_exhaustive()
    }
}

impl Default for AppCoreConfig {
    fn default() -> Self {
        Self {
            command_capacity: 64,
            transient_event_capacity: 128,
            repo: RepoConfig::default(),
            hlc_node_id: None,
            wall_time: Arc::new(SystemWallTime),
        }
    }
}

enum OwnerCommand {
    CreateNew(oneshot::Sender<Result<DocumentId>>),
    Join(DocumentId, oneshot::Sender<Result<()>>),
    Generic(
        Box<GenericCommand>,
        Vec<DomainKind>,
        Vec<CollectionSchemaId>,
        oneshot::Sender<Result<()>>,
    ),
    Shutdown(oneshot::Sender<Result<()>>),
}

struct NetworkComponents {
    identity: Option<Arc<DeviceIdentity>>,
    network: Option<Arc<QuinnTransport>>,
    endpoints: Arc<Mutex<EndpointRegistry>>,
    connections: Option<Arc<ConnectionManager>>,
    pairing: Option<Arc<PairingManager>>,
}

/// Cloneable application handle. Mutable orchestration is confined to one bounded owner task.
#[derive(Clone)]
pub struct AppCore {
    commands: mpsc::Sender<OwnerCommand>,
    lifecycle: watch::Receiver<ApplicationState>,
    projection: watch::Receiver<ProjectionState>,
    data_events: broadcast::Sender<DataChanged>,
    error_events: broadcast::Sender<ErrorEvent>,
    read_model: ReadModel,
    data_dir: Arc<PathBuf>,
    identity: Option<Arc<DeviceIdentity>>,
    network: Option<Arc<QuinnTransport>>,
    endpoints: Arc<Mutex<EndpointRegistry>>,
    connections: Option<Arc<ConnectionManager>>,
    pairing: Option<Arc<PairingManager>>,
    peer_sync: watch::Receiver<std::collections::HashMap<PeerId, PeerSyncProgress>>,
    network_foreground: Arc<AtomicBool>,
}

impl std::fmt::Debug for AppCore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AppCore")
            .field("data_dir", &self.data_dir)
            .field("lifecycle", &self.lifecycle_state())
            .field(
                "device_id",
                &self.identity.as_ref().map(|identity| identity.id()),
            )
            .finish_non_exhaustive()
    }
}

impl AppCore {
    pub async fn open_platform(application_id: &str) -> Result<Self> {
        Self::open(platform_data_dir(application_id)?).await
    }

    pub async fn open(data_dir: impl Into<PathBuf>) -> Result<Self> {
        Self::open_with_config_and_transport(
            data_dir.into(),
            AppCoreConfig::default(),
            LocalTransport::new(),
        )
        .await
    }

    pub async fn open_with_config(
        data_dir: impl Into<PathBuf>,
        config: AppCoreConfig,
    ) -> Result<Self> {
        Self::open_with_config_and_transport(data_dir.into(), config, LocalTransport::new()).await
    }

    pub async fn open_with_transport(
        data_dir: impl Into<PathBuf>,
        transport: Arc<dyn NetworkTransport>,
    ) -> Result<Self> {
        Self::open_with_config_and_transport(data_dir.into(), AppCoreConfig::default(), transport)
            .await
    }

    /// Opens a network-capable core without starting discovery. Trust and endpoints
    /// must be populated explicitly before dialing.
    pub async fn open_networked(
        data_dir: impl Into<PathBuf>,
        key_store: Arc<dyn SecureKeyStore>,
        bind: SocketAddr,
        config: AppCoreConfig,
        network_config: QuinnTransportConfig,
    ) -> Result<Self> {
        let discovery = Arc::new(
            crate::discovery::MdnsDiscovery::with_policy(
                crate::discovery::AddressPolicy::for_bind(bind.ip()),
            )
            .map_err(|error| {
                AppError::Pairing(crate::pairing::PairingError::Transport(error.to_string()))
            })?,
        );
        Self::open_networked_with_discovery(
            data_dir,
            key_store,
            bind,
            config,
            network_config,
            discovery,
        )
        .await
    }

    pub async fn open_networked_with_discovery(
        data_dir: impl Into<PathBuf>,
        key_store: Arc<dyn SecureKeyStore>,
        bind: SocketAddr,
        config: AppCoreConfig,
        network_config: QuinnTransportConfig,
        discovery: Arc<dyn crate::discovery::DiscoveryProvider>,
    ) -> Result<Self> {
        let data_dir = data_dir.into();
        tokio::fs::create_dir_all(&data_dir)
            .await
            .map_err(|error| AppError::Storage(error.to_string()))?;
        let control_store = Arc::new(SqliteControlStore::open(data_dir.join("control.sqlite"))?);
        resume_reset_if_outstanding(&data_dir, &control_store, Some(key_store.as_ref())).await?;
        let identity = Arc::new(DeviceIdentity::load_or_create(key_store.as_ref()).await?);
        let created_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX);
        control_store.store_local_identity(&LocalIdentityRecord {
            device_id: identity.id(),
            public_key: identity.public_key(),
            created_at_ms,
        })?;
        let network = QuinnTransport::bind(
            bind,
            identity.clone(),
            control_store.clone(),
            network_config,
        )?;
        let endpoints = Arc::new(Mutex::new(EndpointRegistry::new(
            crate::discovery::AddressPolicy::for_bind(bind.ip()),
        )));
        let connections = Arc::new(
            ConnectionManager::new(identity.id(), network.clone(), endpoints.clone(), 4)
                .map_err(|message| AppError::Storage(message.into()))?,
        );
        let pairing = PairingManager::new(
            identity.clone(),
            key_store,
            control_store.clone(),
            discovery,
            bind.ip(),
        )?;
        if let Some(requests) = network.take_control_requests() {
            spawn_rotation_control(requests, pairing.clone());
        }
        pairing
            .start_normal_discovery(network.local_addr()?.port())
            .await?;
        Self::open_with_components(
            data_dir,
            config,
            network.clone(),
            control_store,
            NetworkComponents {
                identity: Some(identity),
                network: Some(network),
                endpoints,
                connections: Some(connections),
                pairing: Some(pairing),
            },
        )
        .await
    }

    async fn open_with_config_and_transport(
        data_dir: PathBuf,
        config: AppCoreConfig,
        transport: Arc<dyn NetworkTransport>,
    ) -> Result<Self> {
        if config.command_capacity == 0 || config.transient_event_capacity == 0 {
            return Err(AppError::Storage(
                "application queue capacities must be greater than zero".into(),
            ));
        }
        tokio::fs::create_dir_all(&data_dir)
            .await
            .map_err(|e| AppError::Storage(e.to_string()))?;
        let control_store = Arc::new(SqliteControlStore::open(data_dir.join("control.sqlite"))?);
        resume_reset_if_outstanding(&data_dir, &control_store, None).await?;
        Self::open_with_components(
            data_dir,
            config,
            transport,
            control_store,
            NetworkComponents {
                identity: None,
                network: None,
                endpoints: Arc::new(Mutex::new(EndpointRegistry::default())),
                connections: None,
                pairing: None,
            },
        )
        .await
    }

    async fn open_with_components(
        data_dir: PathBuf,
        config: AppCoreConfig,
        transport: Arc<dyn NetworkTransport>,
        control_store: Arc<SqliteControlStore>,
        network_components: NetworkComponents,
    ) -> Result<Self> {
        if config.command_capacity == 0 || config.transient_event_capacity == 0 {
            return Err(AppError::Storage(
                "application queue capacities must be greater than zero".into(),
            ));
        }
        let node_id = match config.hlc_node_id {
            Some(node_id) => node_id,
            None => {
                load_or_create_hlc_node_id(&data_dir, network_components.identity.as_deref())
                    .await?
            }
        };
        let mut clock = HybridLogicalClock::new(node_id, config.wall_time.clone());
        let document_store =
            Arc::new(FileDocumentStore::open(data_dir.join("automerge/documents")).await?);
        let read_model = ReadModel::open_disposable(data_dir.join("read-model.sqlite"))?;
        let repo = Repo::open(
            document_store,
            control_store,
            transport,
            config.repo.clone(),
        )
        .await?;
        let peer_sync = repo.subscribe_peer_sync();
        if let Some(manager) = network_components.connections.clone() {
            spawn_sync_bridge(peer_sync.clone(), manager);
        }
        if let (Some(pairing), Some(connections), Some(network)) = (
            network_components.pairing.clone(),
            network_components.connections.clone(),
            network_components.network.clone(),
        ) {
            spawn_observed_address_bridge(network.clone(), network_components.endpoints.clone());
            spawn_discovery_bridge(
                pairing,
                network_components.endpoints.clone(),
                connections,
                network,
            );
        }

        let initial = match repo.bootstrap_status() {
            BootstrapStatus::NeedsDecision => ApplicationState::NeedsDecision,
            BootstrapStatus::Creating { .. } => ApplicationState::Creating,
            BootstrapStatus::Joining { root } => ApplicationState::Joining { root },
            BootstrapStatus::Ready { root } => ApplicationState::Ready { root },
            BootstrapStatus::Closed => ApplicationState::Closed,
        };
        let (lifecycle_tx, lifecycle) = watch::channel(initial.clone());
        if let Some(pairing) = network_components.pairing.clone() {
            spawn_pairing_root_state_bridge(lifecycle.clone(), pairing);
        }
        let (projection_tx, projection_rx) = watch::channel(ProjectionState::Unavailable);
        let (data_events, _) = broadcast::channel(config.transient_event_capacity);
        let (error_events, _) = broadcast::channel(config.transient_event_capacity);
        let (commands, command_rx) = mpsc::channel(config.command_capacity);

        let mut root = None;
        if let ApplicationState::Ready { root: root_id } = initial {
            let handle = repo.open_document(root_id).await?;
            if let Some(stamp) = handle
                .read(|doc| {
                    decode_generic(doc)
                        .ok()
                        .and_then(|snapshot| snapshot.max_stamp)
                })
                .await?
            {
                clock.observe(stamp);
            }
            projection_tx.send_replace(ProjectionState::Rebuilding);
            match reconcile(&repo, &handle, &read_model).await {
                Ok(checkpoint) => {
                    projection_tx.send_replace(ProjectionState::Ready { checkpoint });
                    root = Some(handle);
                }
                Err(error) => {
                    projection_tx.send_replace(ProjectionState::Failed {
                        message: error.to_string(),
                    });
                    return Err(error);
                }
            }
        }

        tokio::spawn(owner_loop(
            Owner {
                repo: Some(repo),
                root,
                read_model: read_model.clone(),
                lifecycle: lifecycle_tx,
                projection: projection_tx,
                data_events: data_events.clone(),
                error_events: error_events.clone(),
                clock,
            },
            command_rx,
        ));
        Ok(Self {
            commands,
            lifecycle,
            projection: projection_rx,
            data_events,
            error_events,
            read_model,
            data_dir: Arc::new(data_dir),
            identity: network_components.identity,
            network: network_components.network,
            endpoints: network_components.endpoints,
            connections: network_components.connections,
            pairing: network_components.pairing,
            peer_sync,
            network_foreground: Arc::new(AtomicBool::new(false)),
        })
    }

    #[must_use]
    pub fn lifecycle_state(&self) -> ApplicationState {
        self.lifecycle.borrow().clone()
    }
    #[must_use]
    pub fn projection_state(&self) -> ProjectionState {
        self.projection.borrow().clone()
    }
    #[must_use]
    pub fn subscribe_lifecycle(&self) -> watch::Receiver<ApplicationState> {
        self.lifecycle.clone()
    }
    #[must_use]
    pub fn subscribe_projection(&self) -> watch::Receiver<ProjectionState> {
        self.projection.clone()
    }
    #[must_use]
    pub fn subscribe_data_changed(&self) -> broadcast::Receiver<DataChanged> {
        self.data_events.subscribe()
    }
    #[must_use]
    pub fn subscribe_errors(&self) -> broadcast::Receiver<ErrorEvent> {
        self.error_events.subscribe()
    }
    #[must_use]
    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }
    #[must_use]
    pub fn device_id(&self) -> Option<DeviceId> {
        self.identity.as_ref().map(|identity| identity.id())
    }
    #[must_use]
    pub fn network_addr(&self) -> Option<SocketAddr> {
        self.network
            .as_ref()
            .and_then(|network| network.local_addr().ok())
    }
    #[must_use]
    pub fn subscribe_peer_sync(
        &self,
    ) -> watch::Receiver<std::collections::HashMap<PeerId, PeerSyncProgress>> {
        self.peer_sync.clone()
    }
    #[must_use]
    pub fn subscribe_connections(
        &self,
    ) -> Option<watch::Receiver<std::collections::HashMap<DeviceId, PeerConnectionState>>> {
        self.connections.as_ref().map(|manager| manager.subscribe())
    }
    #[must_use]
    pub fn sync_status(&self) -> crate::routing::SyncStatus {
        let status = self
            .connections
            .as_ref()
            .map_or(crate::routing::SyncStatus::Offline, |manager| {
                manager.sync_status()
            });
        if status == crate::routing::SyncStatus::Offline
            && self.pairing.is_some()
            && self.network_foreground.load(Ordering::Acquire)
        {
            crate::routing::SyncStatus::Searching
        } else {
            status
        }
    }

    pub async fn set_foreground(&self, foreground: bool) -> Result<()> {
        self.network_foreground.store(foreground, Ordering::Release);
        let Some(pairing) = self.pairing.as_ref() else {
            return Ok(());
        };
        if foreground {
            if let Some(port) = self.network_addr().map(|address| address.port()) {
                pairing.start_normal_discovery(port).await?;
            }
        } else {
            pairing.stop_normal_discovery().await?;
            let peers = self.connection_states().into_keys().collect::<Vec<_>>();
            for peer in peers {
                let _ = self.disconnect_peer(peer).await;
                if let Some(connections) = self.connections.as_ref() {
                    connections.set_state(peer, PeerConnectionState::Disconnected);
                }
            }
        }
        Ok(())
    }
    #[must_use]
    pub fn connection_states(&self) -> std::collections::HashMap<DeviceId, PeerConnectionState> {
        self.connections
            .as_ref()
            .map_or_else(std::collections::HashMap::new, |manager| manager.states())
    }
    pub fn replace_endpoints(
        &self,
        peer: DeviceId,
        source: crate::routing::EndpointSource,
        endpoints: impl IntoIterator<Item = NetworkEndpoint>,
    ) {
        if let Ok(mut registry) = self.endpoints.lock() {
            registry.replace_source(peer, source, endpoints);
        }
    }
    pub async fn connect_peer(&self, peer: DeviceId, now_ms: u64) -> Result<u64> {
        self.connections
            .as_ref()
            .ok_or_else(|| AppError::Storage("networking is not enabled".into()))?
            .connect_manual(peer, now_ms)
            .await
            .map_err(|error| AppError::Storage(error.to_string()))
    }
    pub async fn disconnect_peer(&self, peer: DeviceId) -> Result<()> {
        let network = self
            .network
            .as_ref()
            .ok_or_else(|| AppError::Storage("networking is not enabled".into()))?;
        NetworkTransport::close_peer(network.as_ref(), &PeerId::from(peer.to_string()))
            .await
            .map_err(|error| AppError::Repository(error.to_string()))?;
        Ok(())
    }

    pub async fn start_pairing(
        &self,
        duration_ms: u64,
    ) -> Result<crate::discovery::PairingInstanceId> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .start(
                std::time::Duration::from_millis(duration_ms),
                self.local_pairing_name(),
            )
            .await
            .map_err(Into::into)
    }
    pub async fn stop_pairing(&self) -> Result<()> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .stop()
            .await
            .map_err(Into::into)
    }
    pub async fn discovery_secret_for_platform(&self) -> Result<Option<DiscoveryGroupSecret>> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .discovery_secret()
            .await
            .map_err(Into::into)
    }
    #[must_use]
    pub fn pairing_state(&self) -> PairingState {
        self.pairing
            .as_ref()
            .map_or(PairingState::Idle, |pairing| pairing.state())
    }
    #[must_use]
    pub fn pairing_candidates(&self) -> Vec<PairingCandidate> {
        self.pairing
            .as_ref()
            .map_or_else(Vec::new, |pairing| pairing.candidates())
    }
    #[must_use]
    pub fn pairing_addr(&self) -> Option<SocketAddr> {
        self.pairing
            .as_ref()
            .and_then(|pairing| pairing.local_addr().ok())
    }
    pub fn subscribe_pairing(&self) -> Option<watch::Receiver<PairingState>> {
        self.pairing
            .as_ref()
            .map(|pairing| pairing.subscribe_state())
    }
    pub fn subscribe_pairing_candidates(&self) -> Option<watch::Receiver<Vec<PairingCandidate>>> {
        self.pairing
            .as_ref()
            .map(|pairing| pairing.subscribe_candidates())
    }
    pub fn subscribe_pairing_events(&self) -> Option<broadcast::Receiver<PairingEvent>> {
        self.pairing
            .as_ref()
            .map(|pairing| pairing.subscribe_events())
    }
    pub async fn connect_pairing_candidate(
        &self,
        candidate: PairingCandidate,
        timeout_ms: u64,
    ) -> Result<PairingSessionId> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .connect(
                candidate,
                self.local_pairing_name(),
                std::time::Duration::from_millis(timeout_ms),
            )
            .await
            .map_err(Into::into)
    }
    pub async fn confirm_pairing(&self, session: PairingSessionId) -> Result<()> {
        let pairing = self
            .pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?;
        let plan = pairing.confirm(session).await?;
        if plan.compatibility == RootCompatibility::SameRoot {
            pairing.finish_trust(&plan, current_time_ms())?;
            return Ok(());
        }
        if pairing.local_is_provisioner(&plan)? {
            let ApplicationState::Ready { root } = self.lifecycle_state() else {
                return Err(AppError::Pairing(
                    crate::pairing::PairingError::InvalidTransition,
                ));
            };
            let (secret, metadata) = pairing.ensure_discovery_secret(true).await?;
            let identity = self
                .identity
                .as_ref()
                .ok_or_else(|| AppError::Storage("pairing requires identity".into()))?;
            let sync_port = self
                .network_addr()
                .ok_or_else(|| AppError::Storage("pairing requires networking".into()))?
                .port();
            pairing.start_normal_discovery(sync_port).await?;
            pairing.journal(&plan, crate::control::PairingJournalStage::Confirmed, None)?;
            pairing.establish_trust(
                plan.peer_public_key,
                plan.peer_name.clone(),
                current_time_ms(),
            )?;
            pairing.journal(
                &plan,
                crate::control::PairingJournalStage::AwaitingAcknowledgement,
                None,
            )?;
            pairing
                .send_provisioning(
                    &plan,
                    &ProvisioningData {
                        root,
                        discovery_secret: secret,
                        epoch: metadata.epoch,
                        existing_device_id: identity.id(),
                        existing_public_key: identity.public_key(),
                        existing_name: self.local_pairing_name(),
                        sync_port,
                    },
                )
                .await?;
            pairing.finish_trust(&plan, current_time_ms())?;
            pairing.journal(&plan, crate::control::PairingJournalStage::Complete, None)?;
            return Ok(());
        }

        let provision = pairing.receive_provisioning(&plan).await?;
        if provision.existing_device_id != plan.peer_device_id
            || !provision
                .existing_public_key
                .constant_time_eq(&plan.peer_public_key)
            || plan.peer_root_state != RootState::Ready(provision.root)
        {
            return Err(AppError::Pairing(
                crate::pairing::PairingError::Authentication,
            ));
        }
        if !matches!(self.lifecycle_state(), ApplicationState::NeedsDecision) {
            return Err(AppError::Pairing(
                crate::pairing::PairingError::InvalidTransition,
            ));
        }
        pairing.journal(
            &plan,
            crate::control::PairingJournalStage::ProvisioningStored,
            Some(provision.root.to_string()),
        )?;
        pairing
            .install_discovery_secret(
                &provision.discovery_secret,
                crate::control::DiscoveryGroupMetadata {
                    epoch: provision.epoch,
                    updated_at_ms: current_time_ms(),
                },
            )
            .await?;
        let local_sync_port = self
            .network_addr()
            .ok_or_else(|| AppError::Storage("pairing requires networking".into()))?
            .port();
        pairing.start_normal_discovery(local_sync_port).await?;
        pairing.establish_trust(
            plan.peer_public_key,
            plan.peer_name.clone(),
            current_time_ms(),
        )?;
        pairing.journal(
            &plan,
            crate::control::PairingJournalStage::TrustStored,
            Some(provision.root.to_string()),
        )?;
        self.join_existing(provision.root).await?;
        pairing.journal(
            &plan,
            crate::control::PairingJournalStage::RootJoining,
            Some(provision.root.to_string()),
        )?;
        let now = current_time_ms();
        let endpoint = std::net::SocketAddr::new(plan.peer_endpoint.ip(), provision.sync_port);
        self.replace_endpoints(
            plan.peer_device_id,
            crate::routing::EndpointSource::Lan,
            [NetworkEndpoint {
                address: endpoint,
                source: crate::routing::EndpointSource::Lan,
                observed_at_ms: now,
                expires_at_ms: now.saturating_add(120_000),
                interface_scope: None,
                last_success_ms: None,
                failures: 0,
                retry_after_ms: None,
            }],
        );
        self.connect_peer(plan.peer_device_id, now).await?;
        self.wait_for_join_ready(provision.root, std::time::Duration::from_secs(120))
            .await?;
        pairing.acknowledge_provisioning(&plan).await?;
        pairing.finish_trust(&plan, current_time_ms())?;
        pairing.journal(
            &plan,
            crate::control::PairingJournalStage::Complete,
            Some(provision.root.to_string()),
        )?;
        Ok(())
    }
    pub async fn reject_pairing(&self, session: Option<PairingSessionId>) -> Result<()> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .reject(session)
            .await
            .map_err(Into::into)
    }
    pub fn trusted_devices(&self) -> Result<Vec<crate::control::TrustedDeviceRecord>> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .trusted_devices()
            .map_err(Into::into)
    }
    pub fn rename_trusted_device(&self, peer: DeviceId, name: &str) -> Result<bool> {
        self.pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?
            .rename(peer, name)
            .map_err(Into::into)
    }
    /// Revokes `peer` and then rotates the discovery secret.
    ///
    /// Revocation commits durably before rotation is attempted, so a rotation
    /// failure is reported alongside the committed revocation rather than in
    /// place of it. `rotation_error` is retriable via [`Self::rotate_discovery_secret`].
    pub async fn revoke_trusted_device(
        &self,
        peer: DeviceId,
        now_ms: u64,
    ) -> Result<RevocationOutcome> {
        let pairing = self
            .pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?;
        let revoked = pairing.revoke(peer, now_ms)?;
        if !revoked {
            return Ok(RevocationOutcome {
                revoked,
                rotation_error: None,
            });
        }
        let _ = self.disconnect_peer(peer).await;
        self.endpoints
            .lock()
            .map_err(|_| AppError::Storage("endpoint registry lock poisoned".into()))?
            .remove(peer);
        if let Some(connections) = self.connections.as_ref() {
            connections.set_state(peer, PeerConnectionState::Disconnected);
        }
        let rotation_error = self
            .rotate_discovery_secret(now_ms)
            .await
            .err()
            .map(|error| error.to_string());
        Ok(RevocationOutcome {
            revoked,
            rotation_error,
        })
    }

    /// Advances the discovery-secret epoch, retains the previous secret for the
    /// migration window, and distributes the new secret to every remaining
    /// trusted device. Safe to call again after a failed attempt.
    pub async fn rotate_discovery_secret(&self, now_ms: u64) -> Result<u64> {
        let pairing = self
            .pairing
            .as_ref()
            .ok_or_else(|| AppError::Storage("pairing requires networked mode".into()))?;
        let port = self
            .network_addr()
            .ok_or_else(|| AppError::Storage("networking is unavailable".into()))?
            .port();
        let epoch = pairing
            .rotate_discovery_secret(port, now_ms, 7 * 24 * 60 * 60 * 1_000)
            .await?;
        if let Some(network) = self.network.as_ref() {
            for (recipient, frame) in pairing.rotation_update_frames()? {
                match network.exchange_control(recipient, &frame).await {
                    Ok(response) => {
                        let _ = pairing.validate_rotation_ack(&response).await;
                    }
                    Err(_)
                        if self.connections.as_ref().is_some_and(|connections| {
                            !matches!(
                                connections.states().get(&recipient),
                                Some(PeerConnectionState::Failed(_))
                            )
                        }) =>
                    {
                        if let Some(connections) = self.connections.as_ref()
                            && connections.connect_manual(recipient, now_ms).await.is_ok()
                            && let Ok(response) = network.exchange_control(recipient, &frame).await
                        {
                            let _ = pairing.validate_rotation_ack(&response).await;
                        }
                    }
                    Err(_) => {}
                }
            }
        }
        Ok(epoch)
    }

    fn local_pairing_name(&self) -> String {
        self.device_id().map_or_else(
            || "Fi device".into(),
            |device| format!("Fi {}", &device.to_string()[..8]),
        )
    }

    async fn wait_for_join_ready(
        &self,
        root: DocumentId,
        timeout: std::time::Duration,
    ) -> Result<()> {
        let mut lifecycle = self.subscribe_lifecycle();
        let mut projection = self.subscribe_projection();
        tokio::time::timeout(timeout, async move {
            loop {
                let expected = ApplicationState::Ready { root };
                if lifecycle.borrow().clone() == expected
                    && matches!(projection.borrow().clone(), ProjectionState::Ready { .. })
                {
                    return Ok(());
                }
                tokio::select! {
                    changed = lifecycle.changed() => changed.map_err(|_| AppError::OwnerStopped)?,
                    changed = projection.changed() => changed.map_err(|_| AppError::OwnerStopped)?,
                }
            }
        })
        .await
        .map_err(|_| AppError::Pairing(crate::pairing::PairingError::Expired))?
    }

    pub async fn create_new_dataset(&self) -> Result<DocumentId> {
        let root = request(&self.commands, OwnerCommand::CreateNew).await?;
        self.sync_pairing_root_state();
        Ok(root)
    }
    pub async fn join_existing(&self, root: DocumentId) -> Result<()> {
        request(&self.commands, |reply| OwnerCommand::Join(root, reply)).await?;
        self.sync_pairing_root_state();
        Ok(())
    }

    /// Pushes the current lifecycle state into the pairing manager before the
    /// caller returns, so a handshake started right after a bootstrap command
    /// completes cannot observe the previous root state. The lifecycle bridge
    /// spawned at open covers every other transition.
    fn sync_pairing_root_state(&self) {
        if let Some(pairing) = self.pairing.as_ref() {
            pairing.set_root_state(pairing_root_state(&self.lifecycle_state()));
        }
    }

    pub async fn create_collection(
        &self,
        name: String,
        description: String,
    ) -> Result<CollectionSchemaId> {
        let id = CollectionSchemaId::new();
        self.generic(
            GenericCommand::CreateCollection(CollectionSchema {
                id,
                name,
                description,
                fields: vec![],
                deleted: false,
            }),
            vec![DomainKind::Collections, DomainKind::Schemas],
            vec![id],
        )
        .await?;
        Ok(id)
    }
    pub async fn rename_collection(&self, id: CollectionSchemaId, name: String) -> Result<()> {
        self.generic(
            GenericCommand::RenameCollection { id, name },
            vec![DomainKind::Collections, DomainKind::Schemas],
            vec![id],
        )
        .await
    }
    pub async fn delete_collection(&self, id: CollectionSchemaId) -> Result<()> {
        self.generic(
            GenericCommand::DeleteCollection(id),
            vec![
                DomainKind::Collections,
                DomainKind::Schemas,
                DomainKind::Records,
            ],
            vec![id],
        )
        .await
    }
    pub async fn add_field(
        &self,
        collection_id: CollectionSchemaId,
        field: FieldDefinition,
    ) -> Result<()> {
        self.generic(
            GenericCommand::AddField {
                collection_id,
                field,
            },
            vec![DomainKind::Schemas, DomainKind::Records],
            vec![collection_id],
        )
        .await
    }
    pub async fn update_field(
        &self,
        collection_id: CollectionSchemaId,
        field: FieldDefinition,
    ) -> Result<()> {
        self.generic(
            GenericCommand::UpdateField {
                collection_id,
                field,
            },
            vec![DomainKind::Schemas, DomainKind::Records],
            vec![collection_id],
        )
        .await
    }
    pub async fn remove_field(
        &self,
        collection_id: CollectionSchemaId,
        field_id: FieldId,
    ) -> Result<()> {
        self.generic(
            GenericCommand::RemoveField {
                collection_id,
                field_id,
            },
            vec![DomainKind::Schemas, DomainKind::Records],
            vec![collection_id],
        )
        .await
    }
    pub async fn reorder_fields(
        &self,
        collection_id: CollectionSchemaId,
        field_ids: Vec<FieldId>,
    ) -> Result<()> {
        self.generic(
            GenericCommand::ReorderFields {
                collection_id,
                field_ids,
            },
            vec![DomainKind::Schemas],
            vec![collection_id],
        )
        .await
    }
    pub async fn upsert_enum_option(
        &self,
        collection_id: CollectionSchemaId,
        field_id: FieldId,
        option: EnumOption,
    ) -> Result<()> {
        self.generic(
            GenericCommand::UpsertEnumOption {
                collection_id,
                field_id,
                option,
            },
            vec![DomainKind::Schemas, DomainKind::Records],
            vec![collection_id],
        )
        .await
    }
    pub async fn remove_enum_option(
        &self,
        collection_id: CollectionSchemaId,
        field_id: FieldId,
        option_id: EnumOptionId,
    ) -> Result<()> {
        self.generic(
            GenericCommand::RemoveEnumOption {
                collection_id,
                field_id,
                option_id,
            },
            vec![DomainKind::Schemas, DomainKind::Records],
            vec![collection_id],
        )
        .await
    }
    pub async fn create_record(
        &self,
        collection_id: CollectionSchemaId,
        values: std::collections::BTreeMap<FieldId, FieldValue>,
    ) -> Result<RecordId> {
        let id = RecordId::new();
        self.generic(
            GenericCommand::CreateRecord(GenericRecord {
                id,
                collection_id,
                values,
                stamps: std::collections::BTreeMap::new(),
                deleted: false,
            }),
            vec![DomainKind::Records],
            vec![collection_id],
        )
        .await?;
        Ok(id)
    }
    pub async fn update_record_field(
        &self,
        record_id: RecordId,
        collection_id: CollectionSchemaId,
        field_id: FieldId,
        value: FieldValue,
    ) -> Result<()> {
        self.generic(
            GenericCommand::UpdateRecordField {
                record_id,
                field_id,
                value,
            },
            vec![DomainKind::Records],
            vec![collection_id],
        )
        .await
    }
    pub async fn delete_record(
        &self,
        record_id: RecordId,
        collection_id: CollectionSchemaId,
    ) -> Result<()> {
        self.generic(
            GenericCommand::DeleteRecord(record_id),
            vec![DomainKind::Records],
            vec![collection_id],
        )
        .await
    }

    pub async fn create_computed_field(&self, definition: ComputedFieldDefinition) -> Result<()> {
        let collection_id = definition.collection_id;
        self.generic(
            GenericCommand::CreateComputedField(definition),
            vec![DomainKind::ComputedFields],
            vec![collection_id],
        )
        .await
    }
    pub async fn update_computed_field(&self, definition: ComputedFieldDefinition) -> Result<()> {
        let collection_id = definition.collection_id;
        self.generic(
            GenericCommand::UpdateComputedField(definition),
            vec![DomainKind::ComputedFields],
            vec![collection_id],
        )
        .await
    }
    pub async fn remove_computed_field(
        &self,
        collection_id: CollectionSchemaId,
        id: ComputedFieldId,
    ) -> Result<()> {
        self.generic(
            GenericCommand::RemoveComputedField { collection_id, id },
            vec![DomainKind::ComputedFields],
            vec![collection_id],
        )
        .await
    }
    pub async fn reorder_computed_fields(
        &self,
        collection_id: CollectionSchemaId,
        ids: Vec<ComputedFieldId>,
    ) -> Result<()> {
        self.generic(
            GenericCommand::ReorderComputedFields { collection_id, ids },
            vec![DomainKind::ComputedFields],
            vec![collection_id],
        )
        .await
    }
    pub async fn create_query_definition(&self, definition: QueryDefinition) -> Result<()> {
        let collection_id = definition.collection_id;
        self.generic(
            GenericCommand::CreateQuery(definition),
            vec![DomainKind::Queries],
            vec![collection_id],
        )
        .await
    }
    pub async fn update_query_definition(&self, definition: QueryDefinition) -> Result<()> {
        let collection_id = definition.collection_id;
        self.generic(
            GenericCommand::UpdateQuery(definition),
            vec![DomainKind::Queries],
            vec![collection_id],
        )
        .await
    }
    pub async fn remove_query_definition(
        &self,
        collection_id: CollectionSchemaId,
        id: QueryId,
    ) -> Result<()> {
        self.generic(
            GenericCommand::RemoveQuery { collection_id, id },
            vec![DomainKind::Queries],
            vec![collection_id],
        )
        .await
    }
    pub async fn reorder_query_definitions(
        &self,
        collection_id: CollectionSchemaId,
        ids: Vec<QueryId>,
    ) -> Result<()> {
        self.generic(
            GenericCommand::ReorderQueries { collection_id, ids },
            vec![DomainKind::Queries],
            vec![collection_id],
        )
        .await
    }
    pub async fn create_widget(&self, definition: WidgetDefinition) -> Result<()> {
        let collection_id = definition.collection_id;
        self.generic(
            GenericCommand::CreateWidget(definition),
            vec![DomainKind::Widgets],
            vec![collection_id],
        )
        .await
    }
    pub async fn update_widget(&self, update: WidgetUpdate) -> Result<()> {
        let collection_id = update.collection_id;
        self.generic(
            GenericCommand::UpdateWidget(update),
            vec![DomainKind::Widgets],
            vec![collection_id],
        )
        .await
    }
    pub async fn remove_widget(
        &self,
        collection_id: CollectionSchemaId,
        id: WidgetId,
    ) -> Result<()> {
        self.generic(
            GenericCommand::RemoveWidget { collection_id, id },
            vec![DomainKind::Widgets],
            vec![collection_id],
        )
        .await
    }
    pub async fn reorder_widgets(
        &self,
        collection_id: CollectionSchemaId,
        ids: Vec<WidgetId>,
    ) -> Result<()> {
        self.generic(
            GenericCommand::ReorderWidgets { collection_id, ids },
            vec![DomainKind::Widgets],
            vec![collection_id],
        )
        .await
    }

    pub async fn submit_generic(
        &self,
        command: GenericCommand,
        kinds: Vec<DomainKind>,
        collection_ids: Vec<CollectionSchemaId>,
    ) -> Result<()> {
        self.generic(command, kinds, collection_ids).await
    }
    async fn generic(
        &self,
        command: GenericCommand,
        kinds: Vec<DomainKind>,
        collection_ids: Vec<CollectionSchemaId>,
    ) -> Result<()> {
        let (reply, receive) = oneshot::channel();
        self.commands
            .send(OwnerCommand::Generic(
                Box::new(command),
                kinds,
                collection_ids,
                reply,
            ))
            .await
            .map_err(|_| AppError::OwnerStopped)?;
        receive.await.map_err(|_| AppError::OwnerStopped)?
    }

    pub fn collections(&self) -> Result<Vec<CollectionView>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.collections()
    }
    pub fn collection_schema(&self, id: CollectionSchemaId) -> Result<Option<CollectionSchema>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.schema(id)
    }
    pub fn records(&self, collection_id: CollectionSchemaId) -> Result<Vec<RecordView>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.records(collection_id)
    }
    pub fn record(&self, id: RecordId) -> Result<Option<RecordView>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.record(id)
    }
    pub fn computed_fields(
        &self,
        collection_id: CollectionSchemaId,
    ) -> Result<Vec<ComputedFieldDefinition>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.computed_fields(collection_id)
    }
    pub fn query_definitions(
        &self,
        collection_id: CollectionSchemaId,
    ) -> Result<Vec<QueryDefinition>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.query_definitions(collection_id)
    }
    /// Active widgets in deterministic dashboard order.
    pub fn widget_definitions(
        &self,
        collection_id: CollectionSchemaId,
    ) -> Result<Vec<WidgetDefinition>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.widgets(collection_id)
    }
    /// One widget including tombstoned and unsupported definitions, so preserved data can be read
    /// back and edited through safe metadata changes only.
    pub fn widget_definition(
        &self,
        collection_id: CollectionSchemaId,
        id: WidgetId,
    ) -> Result<Option<WidgetDefinition>> {
        ensure_query_ready(self.lifecycle_state())?;
        Ok(self
            .read_model
            .widget(id)?
            .filter(|widget| widget.collection_id == collection_id))
    }
    pub fn widget_diagnostics(&self, id: WidgetId) -> Result<Vec<crate::GenericDiagnostic>> {
        ensure_query_ready(self.lifecycle_state())?;
        self.read_model.entity_diagnostics(&id.to_string())
    }
    pub fn validate_collection_query(
        &self,
        query: &CollectionQuery,
    ) -> std::result::Result<(), QueryValidationError> {
        ensure_query_ready(self.lifecycle_state())
            .map_err(|error| QueryValidationError::new("application", error.to_string()))?;
        let schema = self
            .read_model
            .schema(query.collection_id)
            .map_err(|error| QueryValidationError::new("projection", error.to_string()))?
            .ok_or_else(|| QueryValidationError::new("collection_id", "collection not found"))?;
        let computed = self
            .read_model
            .computed_fields(query.collection_id)
            .map_err(|error| QueryValidationError::new("projection", error.to_string()))?;
        validate_query(query, &schema, &computed)
    }
    pub fn execute_collection_query(
        &self,
        query: &CollectionQuery,
        now_utc_ms: i64,
    ) -> std::result::Result<QueryResult, crate::query::QueryEvaluationError> {
        self.validate_collection_query(query).map_err(|error| {
            crate::query::QueryEvaluationError::InvalidDefinition(error.to_string())
        })?;
        let schema = self
            .read_model
            .schema(query.collection_id)
            .map_err(|error| crate::query::QueryEvaluationError::InvalidRecord(error.to_string()))?
            .ok_or_else(|| {
                crate::query::QueryEvaluationError::InvalidDefinition("collection not found".into())
            })?;
        let computed = self
            .read_model
            .computed_fields(query.collection_id)
            .map_err(|error| {
                crate::query::QueryEvaluationError::InvalidRecord(error.to_string())
            })?;
        let records = self
            .read_model
            .query_candidates(query)
            .map_err(|error| crate::query::QueryEvaluationError::InvalidRecord(error.to_string()))?
            .into_iter()
            .filter(|view| view.valid)
            .map(|view| view.record)
            .collect::<Vec<_>>();
        execute_query(query, &schema, &computed, &records, now_utc_ms)
    }
    pub fn execute_query_definition(
        &self,
        collection_id: CollectionSchemaId,
        id: QueryId,
        now_utc_ms: i64,
    ) -> std::result::Result<QueryResult, crate::query::QueryEvaluationError> {
        let definition = self
            .read_model
            .query_definitions(collection_id)
            .map_err(|error| crate::query::QueryEvaluationError::InvalidRecord(error.to_string()))?
            .into_iter()
            .find(|definition| definition.id == id && !definition.deleted)
            .ok_or_else(|| {
                crate::query::QueryEvaluationError::InvalidDefinition(
                    "query definition not found".into(),
                )
            })?;
        let query = definition.query.query().map_err(|error| {
            crate::query::QueryEvaluationError::InvalidDefinition(error.to_string())
        })?;
        self.execute_collection_query(&query, now_utc_ms)
    }

    /// Evaluates one widget in isolation. Any failure — unsupported type, unavailable or invalid
    /// query, shape mismatch, overflow — is a typed per-widget error, never a dashboard failure.
    pub fn evaluate_widget(
        &self,
        collection_id: CollectionSchemaId,
        id: WidgetId,
        now_utc_ms: i64,
    ) -> Result<WidgetEvaluation> {
        let definition = self.widget_definition(collection_id, id)?.ok_or_else(|| {
            AppError::from(crate::DomainError::NotFound {
                kind: "widget",
                id: id.to_string(),
            })
        })?;
        Ok(self.evaluate_widget_definition(&definition, now_utc_ms, &mut None))
    }

    /// Evaluates every active widget of a collection. Duplicate query references are executed once
    /// per call, so one refresh cycle never repeats identical work. Nothing here is persisted or
    /// synchronized: results are derived from the current projection only.
    pub fn evaluate_widgets(
        &self,
        collection_id: CollectionSchemaId,
        now_utc_ms: i64,
    ) -> Result<Vec<WidgetEvaluation>> {
        let definitions = self.widget_definitions(collection_id)?;
        let mut cache = None;
        Ok(definitions
            .iter()
            .map(|definition| self.evaluate_widget_definition(definition, now_utc_ms, &mut cache))
            .collect())
    }

    fn evaluate_widget_definition(
        &self,
        definition: &WidgetDefinition,
        now_utc_ms: i64,
        cache: &mut Option<(
            QueryId,
            std::result::Result<QueryResult, crate::query::QueryEvaluationError>,
        )>,
    ) -> WidgetEvaluation {
        let stored = self
            .read_model
            .query_definitions(definition.collection_id)
            .ok()
            .and_then(|definitions| {
                definitions
                    .into_iter()
                    .find(|item| item.id == definition.query_id && !item.deleted)
            });
        let decoded = stored.as_ref().map(|item| item.query.query());
        let query = decoded.as_ref().and_then(|result| result.as_ref().ok());
        let resolved = match (stored.is_some(), query) {
            (_, Some(query)) => ResolvedWidgetQuery::Query(query),
            (false, None) => ResolvedWidgetQuery::Missing,
            (true, None) => ResolvedWidgetQuery::Invalid {
                message: decoded
                    .as_ref()
                    .and_then(|result| result.as_ref().err())
                    .map(|error| error.to_string())
                    .unwrap_or_else(|| "widget query is unavailable".into()),
            },
        };
        // Execution is only attempted for a resolvable query, and duplicate references inside one
        // refresh cycle are evaluated once.
        let outcome = match &resolved {
            ResolvedWidgetQuery::Query(query) => match cache {
                Some((cached_id, cached)) if *cached_id == definition.query_id => cached.clone(),
                _ => {
                    let evaluated = self.execute_collection_query(query, now_utc_ms);
                    *cache = Some((definition.query_id, evaluated.clone()));
                    evaluated
                }
            },
            ResolvedWidgetQuery::Missing | ResolvedWidgetQuery::Invalid { .. } => {
                Err(crate::query::QueryEvaluationError::InvalidDefinition(
                    "widget query is unavailable".into(),
                ))
            }
        };
        evaluate_widget(definition, resolved, outcome)
    }
    pub async fn shutdown(&self) -> Result<()> {
        request(&self.commands, OwnerCommand::Shutdown).await
    }
}

fn spawn_sync_bridge(
    mut sync: watch::Receiver<std::collections::HashMap<PeerId, PeerSyncProgress>>,
    manager: Arc<ConnectionManager>,
) {
    tokio::spawn(async move {
        let mut previous = std::collections::HashSet::new();
        loop {
            let snapshot = sync.borrow_and_update().clone();
            let current = snapshot
                .keys()
                .filter_map(|peer| peer.as_str().parse::<DeviceId>().ok())
                .collect::<std::collections::HashSet<_>>();
            for disconnected in previous.difference(&current) {
                manager.set_state(*disconnected, PeerConnectionState::Disconnected);
            }
            for (peer, progress) in snapshot {
                let Ok(device) = peer.as_str().parse::<DeviceId>() else {
                    continue;
                };
                manager.set_state(
                    device,
                    match progress.state {
                        PeerSyncState::Connected => PeerConnectionState::Connected,
                        PeerSyncState::Syncing => PeerConnectionState::Syncing,
                        PeerSyncState::Synced => PeerConnectionState::Synced,
                    },
                );
            }
            previous = current;
            if sync.changed().await.is_err() {
                break;
            }
        }
    });
}

/// The root state a pairing handshake advertises for `state`.
///
/// `Joining` is already rooted: the device has adopted a root and must not be
/// provisioned by a third device mid-join.
fn pairing_root_state(state: &ApplicationState) -> RootState {
    match state {
        ApplicationState::Ready { root } | ApplicationState::Joining { root } => {
            RootState::Ready(*root)
        }
        _ => RootState::NeedsDecision,
    }
}

/// Keeps the pairing manager's advertised root state current. Every bootstrap
/// transition goes through the lifecycle channel, so this is the one update
/// point: a handshake reads the value at the moment it runs rather than the
/// value captured when the window opened.
fn spawn_pairing_root_state_bridge(
    mut lifecycle: watch::Receiver<ApplicationState>,
    pairing: Arc<PairingManager>,
) {
    pairing.set_root_state(pairing_root_state(&lifecycle.borrow_and_update()));
    tokio::spawn(async move {
        while lifecycle.changed().await.is_ok() {
            let state = pairing_root_state(&lifecycle.borrow_and_update());
            pairing.set_root_state(state);
        }
    });
}

fn spawn_discovery_bridge(
    pairing: Arc<PairingManager>,
    endpoints: Arc<Mutex<EndpointRegistry>>,
    connections: Arc<ConnectionManager>,
    network: Arc<QuinnTransport>,
) {
    let mut events = pairing.subscribe_normal_discovery();
    tokio::spawn(async move {
        while let Ok(event) = events.recv().await {
            let crate::pairing_manager::NormalDiscoveryEvent::Upsert {
                peer,
                address,
                expires_at_ms,
            } = event;
            let now = current_time_ms();
            if let Ok(mut endpoints) = endpoints.lock() {
                // Accumulate: a peer with several routable addresses keeps them
                // all for ranking, instead of the last resolved one winning.
                endpoints.upsert(
                    peer,
                    NetworkEndpoint {
                        address,
                        source: crate::routing::EndpointSource::Lan,
                        observed_at_ms: now,
                        expires_at_ms,
                        interface_scope: None,
                        last_success_ms: None,
                        failures: 0,
                        retry_after_ms: None,
                    },
                );
            }
            if let Ok(frames) = pairing.rotation_update_frames()
                && let Some((_, frame)) = frames.into_iter().find(|(device, _)| *device == peer)
                && connections.connect_manual(peer, now).await.is_ok()
                && let Ok(response) = network.exchange_control(peer, &frame).await
            {
                let _ = pairing.validate_rotation_ack(&response).await;
            }
        }
    });
}

/// Records the address each authenticated session was actually reached on, so the
/// demonstrated-reachable address ranks ahead of whatever was advertised.
fn spawn_observed_address_bridge(
    network: Arc<QuinnTransport>,
    endpoints: Arc<Mutex<EndpointRegistry>>,
) {
    let mut observed = network.subscribe_observed_addresses();
    tokio::spawn(async move {
        loop {
            let event = match observed.recv().await {
                Ok(event) => event,
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            };
            let now = current_time_ms();
            tracing::info!(
                event = "peer_address_observed",
                device_id = %event.device,
                address = %event.address,
                direction = ?event.direction,
                "recorded observed peer address"
            );
            if let Ok(mut endpoints) = endpoints.lock() {
                endpoints.upsert(
                    event.device,
                    NetworkEndpoint {
                        address: event.address,
                        source: crate::routing::EndpointSource::Lan,
                        observed_at_ms: now,
                        expires_at_ms: now.saturating_add(OBSERVED_ADDRESS_TTL_MS),
                        interface_scope: None,
                        last_success_ms: Some(now),
                        failures: 0,
                        retry_after_ms: None,
                    },
                );
            }
        }
    });
}

fn spawn_rotation_control(
    mut requests: tokio::sync::mpsc::Receiver<crate::quinn_transport::ControlRequest>,
    pairing: Arc<PairingManager>,
) {
    tokio::spawn(async move {
        while let Some(request) = requests.recv().await {
            let response = pairing
                .accept_rotation_update(request.peer, &request.frame)
                .await
                .map_err(|_| {
                    crate::quinn_transport::QuinnTransportError::Protocol(
                        "discovery control request rejected",
                    )
                });
            let _ = request.response.send(response);
        }
    });
}

fn ensure_query_ready(state: ApplicationState) -> Result<()> {
    match state {
        ApplicationState::Ready { .. } => Ok(()),
        ApplicationState::NeedsDecision | ApplicationState::Creating => {
            Err(BootstrapError::DecisionRequired.into())
        }
        ApplicationState::Joining { .. } => Err(BootstrapError::Joining.into()),
        ApplicationState::ShuttingDown | ApplicationState::Closed => {
            Err(BootstrapError::Closed.into())
        }
    }
}

async fn request<T>(
    sender: &mpsc::Sender<OwnerCommand>,
    build: impl FnOnce(oneshot::Sender<Result<T>>) -> OwnerCommand,
) -> Result<T> {
    let (reply, receive) = oneshot::channel();
    sender
        .send(build(reply))
        .await
        .map_err(|_| AppError::OwnerStopped)?;
    receive.await.map_err(|_| AppError::OwnerStopped)?
}

struct Owner {
    repo: Option<Repo>,
    root: Option<DocHandle>,
    read_model: ReadModel,
    lifecycle: watch::Sender<ApplicationState>,
    projection: watch::Sender<ProjectionState>,
    data_events: broadcast::Sender<DataChanged>,
    error_events: broadcast::Sender<ErrorEvent>,
    clock: HybridLogicalClock,
}

#[instrument(skip_all, fields(component = "app_core_owner"))]
async fn owner_loop(mut owner: Owner, mut commands: mpsc::Receiver<OwnerCommand>) {
    let mut document_events = owner.root.as_ref().map(DocHandle::subscribe);
    let mut bootstrap = owner
        .repo
        .as_ref()
        .expect("owner starts with repo")
        .subscribe_bootstrap();
    loop {
        tokio::select! {
            biased;
            command = commands.recv() => {
                let Some(command) = command else { break };
                match command {
                    OwnerCommand::CreateNew(reply) => { let _ = reply.send(owner.create_new().await); document_events = owner.root.as_ref().map(DocHandle::subscribe); }
                    OwnerCommand::Join(root, reply) => { let _ = reply.send(owner.join(root).await); document_events = owner.root.as_ref().map(DocHandle::subscribe); }
                    OwnerCommand::Generic(command, kinds, collection_ids, reply) => { let _ = reply.send(owner.generic(*command, kinds, collection_ids).await); }
                    OwnerCommand::Shutdown(reply) => { let result = owner.shutdown().await; let _ = reply.send(result); break; }
                }
            }
            event = recv_document(&mut document_events) => {
                match event {
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => { owner.refresh_projection(vec![DomainKind::Collections, DomainKind::Schemas, DomainKind::Records, DomainKind::ComputedFields, DomainKind::Queries, DomainKind::Widgets]).await; },
                    Err(broadcast::error::RecvError::Closed) => { document_events = None; }
                }
            }
            changed = bootstrap.changed() => {
                if changed.is_err() { continue; }
                let bootstrap_state = bootstrap.borrow_and_update().clone();
                if let BootstrapStatus::Ready { root } = bootstrap_state
                    && !matches!(owner.lifecycle.borrow().clone(), ApplicationState::Ready { .. })
                    && let Some(handle) = &owner.root
                    && handle.id() == root
                    && handle.ready().await.is_ok()
                    && owner.refresh_projection(vec![DomainKind::Collections, DomainKind::Schemas, DomainKind::Records, DomainKind::ComputedFields, DomainKind::Queries, DomainKind::Widgets]).await
                {
                    owner.lifecycle.send_replace(ApplicationState::Ready { root });
                }
            }
        }
    }
}

async fn recv_document(
    receiver: &mut Option<broadcast::Receiver<automerge_repo::DocumentEvent>>,
) -> std::result::Result<automerge_repo::DocumentEvent, broadcast::error::RecvError> {
    match receiver {
        Some(receiver) => receiver.recv().await,
        None => pending().await,
    }
}

impl Owner {
    async fn create_new(&mut self) -> Result<DocumentId> {
        if !matches!(
            self.lifecycle.borrow().clone(),
            ApplicationState::NeedsDecision
        ) {
            return Err(BootstrapError::DecisionAlreadyMade.into());
        }
        self.lifecycle.send_replace(ApplicationState::Creating);
        info!(lifecycle = "creating", "application lifecycle transition");
        let repo = self.repo.as_ref().ok_or(BootstrapError::Closed)?;
        let handle = repo.initialize_new().await?;
        handle.change(initialize_generic).await?;
        self.projection.send_replace(ProjectionState::Projecting);
        let checkpoint = project(repo, &handle, &self.read_model).await?;
        self.projection.send_replace(ProjectionState::Ready {
            checkpoint: checkpoint.clone(),
        });
        self.lifecycle
            .send_replace(ApplicationState::Ready { root: handle.id() });
        info!(lifecycle = "ready", root = %handle.id(), checkpoint = %checkpoint.heads, "application lifecycle transition");
        self.root = Some(handle.clone());
        let _ = self.data_events.send(DataChanged {
            kinds: vec![DomainKind::Collections, DomainKind::Schemas],
            collection_ids: vec![],
            checkpoint,
        });
        Ok(handle.id())
    }

    async fn join(&mut self, root: DocumentId) -> Result<()> {
        if !matches!(
            self.lifecycle.borrow().clone(),
            ApplicationState::NeedsDecision
        ) {
            return Err(BootstrapError::DecisionAlreadyMade.into());
        }
        let handle = self
            .repo
            .as_ref()
            .ok_or(BootstrapError::Closed)?
            .join_existing(root)
            .await?;
        self.root = Some(handle);
        self.lifecycle
            .send_replace(ApplicationState::Joining { root });
        self.projection.send_replace(ProjectionState::Unavailable);
        info!(lifecycle = "joining", root = %root, "application lifecycle transition");
        Ok(())
    }

    #[instrument(skip_all, fields(command = command_name(&command)))]
    async fn generic(
        &mut self,
        mut command: GenericCommand,
        kinds: Vec<DomainKind>,
        collection_ids: Vec<CollectionSchemaId>,
    ) -> Result<()> {
        let handle = self
            .root
            .as_ref()
            .ok_or_else(|| match self.lifecycle.borrow().clone() {
                ApplicationState::Joining { .. } => AppError::from(BootstrapError::Joining),
                _ => AppError::from(BootstrapError::DecisionRequired),
            })?;
        if handle.status() != DocumentStatus::Ready {
            return Err(BootstrapError::Joining.into());
        }
        let snapshot = handle.read(decode_generic).await??;
        if let Some(stamp) = snapshot.max_stamp {
            self.clock.observe(stamp);
        }
        command.validate_against(&snapshot)?;
        let stamp = self.clock.tick()?;
        handle
            .change(move |tx| apply_generic_command(tx, &command, stamp))
            .await?;
        self.projection.send_replace(ProjectionState::Projecting);
        let repo = self.repo.as_ref().ok_or(BootstrapError::Closed)?;
        match project(repo, handle, &self.read_model).await {
            Ok(checkpoint) => {
                self.projection.send_replace(ProjectionState::Ready {
                    checkpoint: checkpoint.clone(),
                });
                info!(checkpoint = %checkpoint.heads, "projection committed");
                let _ = self.data_events.send(DataChanged {
                    kinds,
                    collection_ids,
                    checkpoint,
                });
                Ok(())
            }
            Err(failure) => {
                self.report_projection_error(&failure);
                Err(failure)
            }
        }
    }

    async fn refresh_projection(&mut self, kinds: Vec<DomainKind>) -> bool {
        let (Some(repo), Some(handle)) = (&self.repo, &self.root) else {
            return false;
        };
        if handle.status() != DocumentStatus::Ready {
            return false;
        }
        if let Ok(Some(stamp)) = handle
            .read(|doc| {
                decode_generic(doc)
                    .ok()
                    .and_then(|snapshot| snapshot.max_stamp)
            })
            .await
        {
            self.clock.observe(stamp);
        }
        let before = self.read_model.checkpoint().ok().flatten();
        self.projection.send_replace(ProjectionState::Projecting);
        match reconcile(repo, handle, &self.read_model).await {
            Ok(checkpoint) => {
                self.projection.send_replace(ProjectionState::Ready {
                    checkpoint: checkpoint.clone(),
                });
                if before.as_ref() != Some(&checkpoint) {
                    let _ = self.data_events.send(DataChanged {
                        kinds,
                        collection_ids: vec![],
                        checkpoint,
                    });
                }
                true
            }
            Err(failure) => {
                self.report_projection_error(&failure);
                false
            }
        }
    }

    fn report_projection_error(&self, failure: &AppError) {
        let message = failure.to_string();
        error!(operation = "projection", error = %message, "application operation failed");
        self.projection.send_replace(ProjectionState::Failed {
            message: message.clone(),
        });
        let _ = self.error_events.send(ErrorEvent {
            operation: "projection",
            message,
        });
    }

    async fn shutdown(&mut self) -> Result<()> {
        self.lifecycle.send_replace(ApplicationState::ShuttingDown);
        info!(
            lifecycle = "shutting_down",
            "application lifecycle transition"
        );
        if let (Some(repo), Some(handle)) = (&self.repo, &self.root) {
            let _ = project(repo, handle, &self.read_model).await;
        }
        let result = match self.repo.take() {
            Some(repo) => repo.shutdown().await.map_err(AppError::from),
            None => Ok(()),
        };
        self.projection.send_replace(ProjectionState::Closed);
        self.lifecycle.send_replace(ApplicationState::Closed);
        result
    }
}

fn command_name(command: &GenericCommand) -> &'static str {
    match command {
        GenericCommand::CreateCollection(_) => "create_collection",
        GenericCommand::RenameCollection { .. } => "rename_collection",
        GenericCommand::DeleteCollection(_) => "delete_collection",
        GenericCommand::AddField { .. } => "add_field",
        GenericCommand::UpdateField { .. } => "update_field",
        GenericCommand::RemoveField { .. } => "remove_field",
        GenericCommand::ReorderFields { .. } => "reorder_fields",
        GenericCommand::UpsertEnumOption { .. } => "upsert_enum_option",
        GenericCommand::RemoveEnumOption { .. } => "remove_enum_option",
        GenericCommand::CreateRecord(_) => "create_record",
        GenericCommand::UpdateRecordField { .. } => "update_record_field",
        GenericCommand::DeleteRecord(_) => "delete_record",
        GenericCommand::CreateComputedField(_) => "create_computed_field",
        GenericCommand::UpdateComputedField(_) => "update_computed_field",
        GenericCommand::RemoveComputedField { .. } => "remove_computed_field",
        GenericCommand::ReorderComputedFields { .. } => "reorder_computed_fields",
        GenericCommand::CreateQuery(_) => "create_query",
        GenericCommand::UpdateQuery(_) => "update_query",
        GenericCommand::RemoveQuery { .. } => "remove_query",
        GenericCommand::ReorderQueries { .. } => "reorder_queries",
        GenericCommand::CreateWidget(_) => "create_widget",
        GenericCommand::UpdateWidget(_) => "update_widget",
        GenericCommand::RemoveWidget { .. } => "remove_widget",
        GenericCommand::ReorderWidgets { .. } => "reorder_widgets",
    }
}

/// Deliberately abandons this installation's local copy of its root and
/// returns the directory to a `NeedsDecision` state, keeping the device
/// identity. Runs against a closed data directory: no `AppCore` may be live
/// for `data_dir`.
///
/// Crash-safe by write-ahead intent: the marker is committed to
/// `control.sqlite` before any destructive step, and every opener finishes an
/// outstanding reset before bootstrap validation runs. `key_store` is `None`
/// for a local (non-networked) installation, which holds no secrets.
pub async fn reset_dataset(
    data_dir: impl AsRef<Path>,
    key_store: Option<&dyn SecureKeyStore>,
) -> Result<()> {
    let data_dir = data_dir.as_ref();
    tokio::fs::create_dir_all(data_dir)
        .await
        .map_err(|error| AppError::Storage(error.to_string()))?;
    let control_store = SqliteControlStore::open(data_dir.join("control.sqlite"))?;
    control_store.store_reset_intent(ResetIntent {
        requested_at_ms: current_time_ms(),
    })?;
    info!(event = "dataset_reset_started", data_dir = %data_dir.display());
    run_reset_steps(data_dir, &control_store, key_store).await
}

/// Open-time hook: completes an interrupted reset before the document store,
/// read model, or `Repo` are opened, so a half-deleted dataset is never
/// validated (or classified for recovery) as if it were intact.
async fn resume_reset_if_outstanding(
    data_dir: &Path,
    control_store: &SqliteControlStore,
    key_store: Option<&dyn SecureKeyStore>,
) -> Result<()> {
    if control_store.load_reset_intent()?.is_none() {
        return Ok(());
    }
    info!(event = "dataset_reset_resumed", data_dir = %data_dir.display());
    run_reset_steps(data_dir, control_store, key_store).await
}

/// Destructive steps in D3 order. Each step treats an absent target as
/// success; any other failure returns immediately with the intent still set so
/// the next open resumes from here. The final control-store transaction is the
/// only step that clears the intent.
async fn run_reset_steps(
    data_dir: &Path,
    control_store: &SqliteControlStore,
    key_store: Option<&dyn SecureKeyStore>,
) -> Result<()> {
    if let Some(key_store) = key_store {
        key_store
            .remove_discovery_group_secret()
            .await
            .map_err(IdentityError::from)?;
        key_store
            .remove_previous_discovery_group_secret()
            .await
            .map_err(IdentityError::from)?;
    }
    remove_dir_if_present(&data_dir.join("automerge/documents")).await?;
    for name in [
        "read-model.sqlite",
        "read-model.sqlite-wal",
        "read-model.sqlite-shm",
    ] {
        remove_file_if_present(&data_dir.join(name)).await?;
    }
    control_store.complete_reset()?;
    info!(event = "dataset_reset_completed", data_dir = %data_dir.display());
    Ok(())
}

async fn remove_dir_if_present(path: &Path) -> Result<()> {
    match tokio::fs::remove_dir_all(path).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(AppError::Storage(format!(
            "could not remove {}: {error}",
            path.display()
        ))),
    }
}

async fn remove_file_if_present(path: &Path) -> Result<()> {
    match tokio::fs::remove_file(path).await {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(AppError::Storage(format!(
            "could not remove {}: {error}",
            path.display()
        ))),
    }
}

async fn load_or_create_hlc_node_id(
    data_dir: &Path,
    identity: Option<&DeviceIdentity>,
) -> Result<HlcNodeId> {
    if let Some(identity) = identity {
        return Ok(HlcNodeId(*identity.id().as_bytes()));
    }
    let path = data_dir.join("hlc-node-id");
    match tokio::fs::read_to_string(&path).await {
        Ok(encoded) => {
            let bytes = hex::decode(encoded.trim())
                .map_err(|_| AppError::Storage("durable HLC node identity is malformed".into()))?;
            return Ok(HlcNodeId(bytes.try_into().map_err(|_| {
                AppError::Storage("durable HLC node identity is malformed".into())
            })?));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(AppError::Storage(error.to_string())),
    }
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    tokio::fs::write(&path, hex::encode(bytes))
        .await
        .map_err(|error| AppError::Storage(error.to_string()))?;
    Ok(HlcNodeId(bytes))
}

fn current_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

/// Resolves a conventional per-platform application-data directory.
pub fn platform_data_dir(application_id: &str) -> Result<PathBuf> {
    if application_id.is_empty() || application_id.contains(['/', '\\']) {
        return Err(AppError::Storage(
            "application id must be one path component".into(),
        ));
    }
    #[cfg(target_os = "windows")]
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(target_os = "macos")]
    let base = std::env::var_os("HOME")
        .map(|path| PathBuf::from(path).join("Library/Application Support"));
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|path| PathBuf::from(path).join(".local/share")));
    base.map(|path| path.join(application_id)).ok_or_else(|| {
        AppError::Storage("platform application-data directory is unavailable".into())
    })
}
