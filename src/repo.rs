//! Repository coordinator, bootstrap lifecycle, and peer routing.

use std::{
    collections::{BTreeSet, HashMap},
    sync::Arc,
};

use automerge::{
    Automerge,
    transaction::{CommitOptions, Transaction},
};
use tokio::sync::{broadcast, mpsc, oneshot, watch};

use crate::{
    BootstrapOffer, BootstrapRecord, BootstrapStatus, DocHandle, DocumentId, Error, PeerId, Result,
    bootstrap::BootstrapStatus::*,
    document::{ActorHandle, ActorOutput, DocumentStatus, spawn_actor},
    error::{BootstrapError, LifecycleError, ProtocolError, StorageError},
    network::{NetworkEvent, NetworkTransport},
    protocol::{BootstrapMode, Codec, Message},
    storage::{ControlStore, StorageAdapter},
};

#[derive(Clone, Debug)]
pub struct RepoConfig {
    /// Coordinator command and actor-output queue capacity.
    pub coordinator_capacity: usize,
    /// Capacity of each independent document actor mailbox.
    pub document_capacity: usize,
    /// Retained change events per document.
    pub event_capacity: usize,
    /// Retained asynchronous repository errors.
    pub error_capacity: usize,
}
impl Default for RepoConfig {
    fn default() -> Self {
        Self {
            coordinator_capacity: 128,
            document_capacity: 64,
            event_capacity: 128,
            error_capacity: 128,
        }
    }
}

type InitJob = Box<dyn FnOnce(&mut Transaction<'_>) -> Result<()> + Send>;
enum Command {
    DocumentIds(oneshot::Sender<Result<Vec<DocumentId>>>),
    Get(DocumentId, oneshot::Sender<Result<Option<DocHandle>>>),
    Open(DocumentId, oneshot::Sender<Result<DocHandle>>),
    Initialize(oneshot::Sender<Result<DocHandle>>),
    Join(DocumentId, oneshot::Sender<Result<DocHandle>>),
    Create(Option<InitJob>, oneshot::Sender<Result<DocHandle>>),
    Offers(oneshot::Sender<Result<Vec<BootstrapOffer>>>),
    Flush(oneshot::Sender<Result<()>>),
    Shutdown(oneshot::Sender<Result<()>>),
}

/// Cloneable handle to the single repository coordinator.
#[derive(Clone)]
pub struct Repo {
    tx: mpsc::Sender<Command>,
    bootstrap: watch::Receiver<BootstrapStatus>,
    offers: watch::Receiver<Vec<BootstrapOffer>>,
    errors: broadcast::Sender<Error>,
}

impl std::fmt::Debug for Repo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Repo")
            .field("bootstrap", &self.bootstrap_status())
            .finish_non_exhaustive()
    }
}

impl Repo {
    /// Opens stored documents strictly and starts the coordinator and network
    /// event reader. The transport event receiver is consumed exactly once.
    pub async fn open(
        storage: Arc<dyn StorageAdapter>,
        control: Arc<dyn ControlStore>,
        transport: Arc<dyn NetworkTransport>,
        config: RepoConfig,
    ) -> Result<Self> {
        let ids = storage.list().await?;
        let record = control.load().await?;
        if record.is_none() && !ids.is_empty() {
            return Err(StorageError::new(
                "open",
                None,
                "documents exist without a bootstrap record",
            )
            .into());
        }
        let initial = record
            .clone()
            .map(BootstrapStatus::from)
            .unwrap_or(NeedsDecision);
        let (bootstrap_tx, bootstrap) = watch::channel(initial);
        let (offers_tx, offers) = watch::channel(Vec::new());
        let (errors, _) = broadcast::channel(config.error_capacity.max(1));
        let (actor_tx, actor_rx) = mpsc::channel(config.coordinator_capacity.max(1));
        let mut actors = HashMap::new();
        for id in ids {
            let bytes = storage.load(id).await?.ok_or_else(|| {
                StorageError::new("load", Some(id), "listed snapshot disappeared")
            })?;
            let doc = Automerge::load(&bytes).map_err(|error| Error::Automerge {
                document: id,
                message: error.to_string(),
            })?;
            actors.insert(
                id,
                spawn_actor(
                    id,
                    doc,
                    DocumentStatus::Ready,
                    bootstrap.clone(),
                    config.document_capacity,
                    config.event_capacity,
                    actor_tx.clone(),
                ),
            );
        }
        let events = transport.take_events()?;
        let (tx, commands) = mpsc::channel(config.coordinator_capacity.max(1));
        let coordinator = Coordinator {
            storage,
            control,
            transport,
            config,
            actors,
            peers: HashMap::new(),
            status_tx: bootstrap_tx,
            offers_tx,
            errors: errors.clone(),
            actor_tx,
            closed: false,
        };
        tokio::spawn(coordinator.run(commands, events, actor_rx));
        Ok(Self {
            tx,
            bootstrap,
            offers,
            errors,
        })
    }

    #[must_use]
    /// Returns the latest retained bootstrap status.
    pub fn bootstrap_status(&self) -> BootstrapStatus {
        self.bootstrap.borrow().clone()
    }
    #[must_use]
    /// Watches live bootstrap transitions.
    pub fn subscribe_bootstrap(&self) -> watch::Receiver<BootstrapStatus> {
        self.bootstrap.clone()
    }
    #[must_use]
    /// Watches the retained set of roots offered by authenticated peers.
    pub fn subscribe_offers(&self) -> watch::Receiver<Vec<BootstrapOffer>> {
        self.offers.clone()
    }
    #[must_use]
    /// Subscribes to typed asynchronous persistence, network, and protocol errors.
    pub fn subscribe_errors(&self) -> broadcast::Receiver<Error> {
        self.errors.subscribe()
    }
    /// Returns retained bootstrap offers in deterministic order.
    pub async fn bootstrap_offers(&self) -> Result<Vec<BootstrapOffer>> {
        request(&self.tx, Command::Offers).await
    }
    /// Lists every known document ID in deterministic order.
    pub async fn document_ids(&self) -> Result<Vec<DocumentId>> {
        request(&self.tx, Command::DocumentIds).await
    }
    /// Returns a cached document handle, without fabricating a placeholder.
    pub async fn get(&self, id: DocumentId) -> Result<Option<DocHandle>> {
        request(&self.tx, |reply| Command::Get(id, reply)).await
    }
    /// Opens a stored document or returns `Error::NotFound`.
    pub async fn open_document(&self, id: DocumentId) -> Result<DocHandle> {
        request(&self.tx, |reply| Command::Open(id, reply)).await
    }
    /// Makes this repository the first ready device and returns its root.
    pub async fn initialize_new(&self) -> Result<DocHandle> {
        request(&self.tx, Command::Initialize).await
    }
    /// Explicitly accepts a root offer and begins root-only synchronization.
    pub async fn join_existing(&self, root: DocumentId) -> Result<DocHandle> {
        request(&self.tx, |reply| Command::Join(root, reply)).await
    }
    /// Creates an empty document with explicit synchronizable history.
    pub async fn create(&self) -> Result<DocHandle> {
        request(&self.tx, |reply| Command::Create(None, reply)).await
    }
    /// Creates a document and atomically applies its initializer before sharing.
    pub async fn create_with<F>(&self, initialize: F) -> Result<DocHandle>
    where
        F: FnOnce(&mut Transaction<'_>) -> Result<()> + Send + 'static,
    {
        request(&self.tx, |reply| {
            Command::Create(Some(Box::new(initialize)), reply)
        })
        .await
    }
    /// Stores complete snapshots and invokes both adapter barriers.
    pub async fn flush(&self) -> Result<()> {
        request(&self.tx, Command::Flush).await
    }
    /// Stops admission, flushes and closes actors, transport, and stores.
    pub async fn shutdown(&self) -> Result<()> {
        request(&self.tx, Command::Shutdown).await
    }
}

trait MakeCommand<T> {
    fn make(self, reply: oneshot::Sender<Result<T>>) -> Command;
}
impl<T, F: FnOnce(oneshot::Sender<Result<T>>) -> Command> MakeCommand<T> for F {
    fn make(self, reply: oneshot::Sender<Result<T>>) -> Command {
        self(reply)
    }
}
async fn request<T>(tx: &mpsc::Sender<Command>, command: impl MakeCommand<T>) -> Result<T> {
    let (reply, receive) = oneshot::channel();
    tx.send(command.make(reply))
        .await
        .map_err(|_| LifecycleError::RepositoryClosed)?;
    receive
        .await
        .map_err(|_| LifecycleError::RepositoryClosed)?
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Eligibility {
    None,
    RootOnly(DocumentId),
    Full,
}
struct PeerState {
    hello: bool,
    remote: Option<BootstrapMode>,
    eligibility: Eligibility,
}
struct Coordinator {
    storage: Arc<dyn StorageAdapter>,
    control: Arc<dyn ControlStore>,
    transport: Arc<dyn NetworkTransport>,
    config: RepoConfig,
    actors: HashMap<DocumentId, ActorHandle>,
    peers: HashMap<PeerId, PeerState>,
    status_tx: watch::Sender<BootstrapStatus>,
    offers_tx: watch::Sender<Vec<BootstrapOffer>>,
    errors: broadcast::Sender<Error>,
    actor_tx: mpsc::Sender<ActorOutput>,
    closed: bool,
}

impl Coordinator {
    async fn run(
        mut self,
        mut commands: mpsc::Receiver<Command>,
        mut events: mpsc::Receiver<NetworkEvent>,
        mut actor_output: mpsc::Receiver<ActorOutput>,
    ) {
        loop {
            tokio::select! {
                Some(command) = commands.recv() => { if self.handle_command(command).await { break; } },
                Some(event) = events.recv(), if !self.closed => self.handle_network(event).await,
                Some(output) = actor_output.recv(), if !self.closed => self.handle_actor_output(output).await,
                else => break,
            }
        }
    }

    fn status(&self) -> BootstrapStatus {
        self.status_tx.borrow().clone()
    }
    fn ensure_open(&self) -> Result<()> {
        if self.closed {
            Err(LifecycleError::RepositoryClosed.into())
        } else {
            Ok(())
        }
    }
    fn ensure_ready(&self) -> Result<DocumentId> {
        self.ensure_open()?;
        match self.status() {
            Ready { root } => Ok(root),
            _ => Err(BootstrapError::DecisionRequired.into()),
        }
    }

    async fn handle_command(&mut self, command: Command) -> bool {
        match command {
            Command::DocumentIds(reply) => {
                let _ = reply.send(self.ensure_open().map(|()| {
                    let mut ids: Vec<_> = self.actors.keys().copied().collect();
                    ids.sort();
                    ids
                }));
            }
            Command::Get(id, reply) => {
                let result = self
                    .ensure_open()
                    .map(|()| self.actors.get(&id).map(|actor| actor.handle.clone()));
                let _ = reply.send(result);
            }
            Command::Open(id, reply) => {
                let _ = reply.send(self.open_document(id).await);
            }
            Command::Offers(reply) => {
                let _ = reply.send(self.ensure_open().map(|()| self.offers_tx.borrow().clone()));
            }
            Command::Initialize(reply) => {
                let _ = reply.send(self.initialize().await);
            }
            Command::Join(root, reply) => {
                let _ = reply.send(self.join(root).await);
            }
            Command::Create(job, reply) => {
                let _ = reply.send(self.create(job).await);
            }
            Command::Flush(reply) => {
                let _ = reply.send(self.flush_all().await);
            }
            Command::Shutdown(reply) => {
                let result = self.shutdown_all().await;
                let _ = reply.send(result);
                return true;
            }
        }
        false
    }

    async fn open_document(&mut self, id: DocumentId) -> Result<DocHandle> {
        self.ensure_open()?;
        if let Some(actor) = self.actors.get(&id) {
            return Ok(actor.handle.clone());
        }
        let bytes = self.storage.load(id).await?.ok_or(Error::NotFound(id))?;
        let doc = Automerge::load(&bytes).map_err(|error| Error::Automerge {
            document: id,
            message: error.to_string(),
        })?;
        let actor = self.spawn(id, doc, DocumentStatus::Ready);
        let handle = actor.handle.clone();
        self.actors.insert(id, actor);
        self.attach_eligible(id).await;
        Ok(handle)
    }

    async fn initialize(&mut self) -> Result<DocHandle> {
        self.ensure_open()?;
        if self.status() != NeedsDecision {
            return Err(BootstrapError::DecisionAlreadyMade.into());
        }
        let root = DocumentId::new();
        self.status_tx.send_replace(Creating { root });
        self.control
            .store(BootstrapRecord::Creating { root })
            .await?;
        let mut doc = Automerge::new();
        doc.empty_commit(CommitOptions::default());
        let snapshot = doc.save();
        self.storage.store(root, snapshot).await?;
        self.control.store(BootstrapRecord::Ready { root }).await?;
        let actor = self.spawn(root, doc, DocumentStatus::Ready);
        let handle = actor.handle.clone();
        self.actors.insert(root, actor);
        self.status_tx.send_replace(Ready { root });
        self.offers_tx.send_replace(Vec::new());
        self.broadcast_bootstrap().await;
        Ok(handle)
    }

    async fn join(&mut self, root: DocumentId) -> Result<DocHandle> {
        self.ensure_open()?;
        if self.status() != NeedsDecision {
            return Err(BootstrapError::DecisionAlreadyMade.into());
        }
        self.control
            .store(BootstrapRecord::Joining { root })
            .await?;
        self.status_tx.send_replace(Joining { root });
        let actor = self.spawn(root, Automerge::new(), DocumentStatus::Loading);
        let handle = actor.handle.clone();
        self.actors.insert(root, actor);
        self.offers_tx.send_replace(Vec::new());
        self.broadcast_bootstrap().await;
        self.reconsider_all().await;
        Ok(handle)
    }

    async fn create(&mut self, initialize: Option<InitJob>) -> Result<DocHandle> {
        self.ensure_ready()?;
        let id = DocumentId::new();
        let mut doc = Automerge::new();
        doc.empty_commit(CommitOptions::default());
        if let Some(job) = initialize {
            doc.transact_and_log_patches(job)
                .map_err(|failure| failure.error)?;
        }
        self.storage.store(id, doc.save()).await?;
        let actor = self.spawn(id, doc, DocumentStatus::Ready);
        let handle = actor.handle.clone();
        self.actors.insert(id, actor);
        self.announce(id).await;
        self.attach_eligible(id).await;
        Ok(handle)
    }

    fn spawn(&self, id: DocumentId, doc: Automerge, status: DocumentStatus) -> ActorHandle {
        spawn_actor(
            id,
            doc,
            status,
            self.status_tx.subscribe(),
            self.config.document_capacity,
            self.config.event_capacity,
            self.actor_tx.clone(),
        )
    }

    async fn flush_all(&mut self) -> Result<()> {
        self.ensure_open()?;
        for (id, actor) in &self.actors {
            self.storage.store(*id, actor.snapshot().await?).await?;
        }
        self.storage.flush().await?;
        self.control.flush().await?;
        Ok(())
    }
    async fn shutdown_all(&mut self) -> Result<()> {
        self.ensure_open()?;
        self.flush_all().await?;
        self.closed = true;
        self.status_tx.send_replace(Closed);
        for actor in self.actors.values() {
            actor.close().await;
        }
        self.transport.close().await?;
        self.storage.close().await?;
        self.control.close().await?;
        Ok(())
    }

    async fn handle_network(&mut self, event: NetworkEvent) {
        match event {
            NetworkEvent::PeerConnected(peer) => {
                self.detach_peer(&peer).await;
                self.peers.insert(
                    peer.clone(),
                    PeerState {
                        hello: false,
                        remote: None,
                        eligibility: Eligibility::None,
                    },
                );
                self.send(&peer, Message::Hello(mode(&self.status()))).await;
            }
            NetworkEvent::PeerDisconnected(peer) => {
                self.detach_peer(&peer).await;
                self.peers.remove(&peer);
                self.refresh_offers();
            }
            NetworkEvent::Message { peer, bytes } => match Codec::decode_exact(&bytes) {
                Ok(message) => self.handle_message(peer, message).await,
                Err(error) => self.protocol_failure(peer, error).await,
            },
        }
    }

    async fn handle_message(&mut self, peer: PeerId, message: Message) {
        let Some(state) = self.peers.get(&peer) else {
            self.protocol_failure(peer, ProtocolError::HelloRequired)
                .await;
            return;
        };
        if !state.hello && !matches!(message, Message::Hello(_)) {
            self.protocol_failure(peer, ProtocolError::HelloRequired)
                .await;
            return;
        }
        if state.hello && matches!(message, Message::Hello(_)) {
            self.protocol_failure(peer, ProtocolError::DuplicateHello)
                .await;
            return;
        }
        match message {
            Message::Hello(remote) => {
                if let Some(state) = self.peers.get_mut(&peer) {
                    state.hello = true;
                    state.remote = Some(remote);
                }
                self.reconsider(peer).await;
            }
            Message::BootstrapState(remote) => {
                if let Some(state) = self.peers.get_mut(&peer) {
                    state.remote = Some(remote);
                }
                self.reconsider(peer).await;
            }
            Message::Inventory(ids) => {
                if self
                    .peers
                    .get(&peer)
                    .is_some_and(|p| p.eligibility == Eligibility::Full)
                {
                    for id in BTreeSet::from_iter(ids) {
                        if !self.actors.contains_key(&id) {
                            let actor = self.spawn(id, Automerge::new(), DocumentStatus::Loading);
                            self.actors.insert(id, actor);
                        }
                        if let Some(actor) = self.actors.get(&id) {
                            let _ = actor.attach(peer.clone()).await;
                        }
                    }
                }
            }
            Message::Announce(id) => {
                if self.eligible(&peer, id) {
                    if !self.actors.contains_key(&id) {
                        let actor = self.spawn(id, Automerge::new(), DocumentStatus::Loading);
                        self.actors.insert(id, actor);
                    }
                    if let Some(actor) = self.actors.get(&id) {
                        let _ = actor.attach(peer).await;
                    }
                }
            }
            Message::Sync { document, message } => {
                if !self.eligible(&peer, document) {
                    return;
                }
                if !self.actors.contains_key(&document) {
                    let actor = self.spawn(document, Automerge::new(), DocumentStatus::Loading);
                    self.actors.insert(document, actor);
                    if let Some(actor) = self.actors.get(&document) {
                        let _ = actor.attach(peer.clone()).await;
                    }
                }
                if let Some(actor) = self.actors.get(&document)
                    && let Err(error) = actor.receive(peer.clone(), message).await
                {
                    let _ = self.errors.send(error);
                }
            }
        }
    }

    fn eligible(&self, peer: &PeerId, id: DocumentId) -> bool {
        match self.peers.get(peer).map(|p| p.eligibility) {
            Some(Eligibility::Full) => true,
            Some(Eligibility::RootOnly(root)) => root == id,
            _ => false,
        }
    }

    async fn reconsider_all(&mut self) {
        let peers: Vec<_> = self.peers.keys().cloned().collect();
        for peer in peers {
            self.reconsider(peer).await;
        }
    }
    async fn reconsider(&mut self, peer: PeerId) {
        let Some(remote) = self.peers.get(&peer).and_then(|p| p.remote) else {
            return;
        };
        let local = self.status();
        if let (Some(local_root), Some(remote_root)) = (local.root(), mode_root(remote))
            && local_root != remote_root
        {
            let _ = self.errors.send(
                BootstrapError::RootMismatch {
                    peer: peer.clone(),
                    local: local_root,
                    remote: remote_root,
                }
                .into(),
            );
            self.detach_peer(&peer).await;
            self.peers.remove(&peer);
            let _ = self.transport.close_peer(&peer).await;
            self.refresh_offers();
            return;
        }
        let eligibility = match (local.clone(), remote) {
            (NeedsDecision, BootstrapMode::Ready(_)) => {
                self.refresh_offers();
                Eligibility::None
            }
            (Ready { root: local }, BootstrapMode::Ready(remote)) if local == remote => {
                Eligibility::Full
            }
            (Joining { root: local }, BootstrapMode::Ready(remote)) if local == remote => {
                Eligibility::RootOnly(local)
            }
            (Ready { root: local }, BootstrapMode::Joining(remote)) if local == remote => {
                Eligibility::RootOnly(local)
            }
            _ => Eligibility::None,
        };
        if let Some(state) = self.peers.get_mut(&peer) {
            state.eligibility = eligibility;
        }
        match eligibility {
            Eligibility::Full => {
                self.send_inventory(&peer).await;
                let ids: Vec<_> = self.actors.keys().copied().collect();
                for id in ids {
                    if let Some(actor) = self.actors.get(&id) {
                        let _ = actor.attach(peer.clone()).await;
                    }
                }
            }
            Eligibility::RootOnly(root) => {
                if let Some(actor) = self.actors.get(&root) {
                    let _ = actor.attach(peer).await;
                }
            }
            Eligibility::None => {}
        }
    }

    fn refresh_offers(&self) {
        if self.status() != NeedsDecision {
            self.offers_tx.send_replace(Vec::new());
            return;
        }
        let mut offers: Vec<_> = self
            .peers
            .iter()
            .filter_map(|(peer, state)| match state.remote {
                Some(BootstrapMode::Ready(root)) => Some(BootstrapOffer {
                    peer: peer.clone(),
                    root,
                }),
                _ => None,
            })
            .collect();
        offers.sort_by(|a, b| (&a.root, &a.peer).cmp(&(&b.root, &b.peer)));
        self.offers_tx.send_replace(offers);
    }
    async fn handle_actor_output(&mut self, output: ActorOutput) {
        match output {
            ActorOutput::Send {
                peer,
                document,
                message,
            } => self.send(&peer, Message::Sync { document, message }).await,
            ActorOutput::HeadsChanged(id) => self.persist_ready(id).await,
        }
    }
    async fn persist_ready(&mut self, id: DocumentId) {
        let Some(actor) = self.actors.get(&id) else {
            return;
        };
        let snapshot = match actor.snapshot().await {
            Ok(value) => value,
            Err(error) => {
                let _ = self.errors.send(error);
                return;
            }
        };
        if let Err(error) = self.storage.store(id, snapshot).await {
            let _ = self.errors.send(error.into());
            return;
        }
        if actor.handle.status() == DocumentStatus::Loading {
            actor.mark_ready().await;
            if matches!(self.status(), Joining { root } if root == id) {
                if let Err(error) = self
                    .control
                    .store(BootstrapRecord::Ready { root: id })
                    .await
                {
                    let _ = self.errors.send(error.into());
                    return;
                }
                self.status_tx.send_replace(Ready { root: id });
                self.broadcast_bootstrap().await;
                self.reconsider_all().await;
            } else {
                self.attach_eligible(id).await;
                self.announce(id).await;
            }
        }
    }
    async fn attach_eligible(&self, id: DocumentId) {
        if let Some(actor) = self.actors.get(&id) {
            for (peer, state) in &self.peers {
                if matches!(state.eligibility, Eligibility::Full)
                    || matches!(state.eligibility, Eligibility::RootOnly(root) if root == id)
                {
                    let _ = actor.attach(peer.clone()).await;
                }
            }
        }
    }
    async fn detach_peer(&self, peer: &PeerId) {
        for actor in self.actors.values() {
            actor.detach(peer.clone()).await;
        }
    }
    async fn announce(&mut self, id: DocumentId) {
        let peers: Vec<_> = self
            .peers
            .iter()
            .filter(|(_, state)| state.eligibility == Eligibility::Full)
            .map(|(peer, _)| peer.clone())
            .collect();
        for peer in peers {
            self.send(&peer, Message::Announce(id)).await;
        }
    }
    async fn send_inventory(&mut self, peer: &PeerId) {
        let mut ids: Vec<_> = self
            .actors
            .iter()
            .filter(|(_, actor)| actor.handle.status() == DocumentStatus::Ready)
            .map(|(id, _)| *id)
            .collect();
        ids.sort();
        self.send(peer, Message::Inventory(ids)).await;
    }
    async fn broadcast_bootstrap(&mut self) {
        let peers: Vec<_> = self.peers.keys().cloned().collect();
        for peer in peers {
            self.send(&peer, Message::BootstrapState(mode(&self.status())))
                .await;
        }
    }
    async fn send(&mut self, peer: &PeerId, message: Message) {
        match Codec::encode(message).map_err(Error::from) {
            Ok(frame) => {
                if let Err(error) = self.transport.send(peer, frame).await {
                    let _ = self.errors.send(error.into());
                    self.detach_peer(peer).await;
                    if let Some(state) = self.peers.get_mut(peer) {
                        state.eligibility = Eligibility::None;
                    }
                }
            }
            Err(error) => {
                let _ = self.errors.send(error);
            }
        }
    }
    async fn protocol_failure(&mut self, peer: PeerId, error: ProtocolError) {
        let _ = self.errors.send(error.into());
        self.detach_peer(&peer).await;
        self.peers.remove(&peer);
        let _ = self.transport.close_peer(&peer).await;
        self.refresh_offers();
    }
}

fn mode(status: &BootstrapStatus) -> BootstrapMode {
    match status {
        NeedsDecision | Creating { .. } | Closed => BootstrapMode::Uninitialized,
        Joining { root } => BootstrapMode::Joining(*root),
        Ready { root } => BootstrapMode::Ready(*root),
    }
}
const fn mode_root(mode: BootstrapMode) -> Option<DocumentId> {
    match mode {
        BootstrapMode::Joining(root) | BootstrapMode::Ready(root) => Some(root),
        BootstrapMode::Uninitialized => None,
    }
}
