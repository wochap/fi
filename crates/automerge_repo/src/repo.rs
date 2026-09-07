//! Repository coordinator, bootstrap lifecycle, and peer routing.

use std::{
    collections::{BTreeSet, HashMap},
    sync::Arc,
    time::Duration,
};

use automerge::{
    Automerge,
    transaction::{CommitOptions, Transaction},
};
use bytes::Bytes;
use tokio::sync::{RwLock, broadcast, mpsc, oneshot, watch};

use crate::{
    BootstrapOffer, BootstrapRecord, BootstrapStatus, DocHandle, DocumentId, Error, PeerId, Result,
    bootstrap::BootstrapStatus::*,
    document::{ActorConfig, ActorHandle, ActorOutput, DocumentStatus, InitJob, spawn_actor},
    error::{BootstrapError, Failure, FailurePhase, LifecycleError, ProtocolError, StorageError},
    lifecycle::{CaptureGate, Lifecycle},
    network::{NetworkEvent, NetworkTransport},
    protocol::{BootstrapMode, Codec, Message},
    storage::{ControlStore, StorageAdapter},
    sync::{PeerSyncProgress, PeerSyncState, RelationshipSyncState},
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
    /// Delay used to coalesce automatic snapshots after a head change.
    pub persistence_debounce: Duration,
    /// Initial retry delay after an automatic snapshot failure.
    pub persistence_retry_min: Duration,
    /// Maximum exponential automatic snapshot retry delay.
    pub persistence_retry_max: Duration,
    /// Capacity of each authenticated peer's private writer queue.
    pub peer_writer_capacity: usize,
}
impl Default for RepoConfig {
    fn default() -> Self {
        Self {
            coordinator_capacity: 128,
            document_capacity: 64,
            event_capacity: 128,
            error_capacity: 128,
            persistence_debounce: Duration::from_millis(50),
            persistence_retry_min: Duration::from_millis(100),
            persistence_retry_max: Duration::from_secs(5),
            peer_writer_capacity: 64,
        }
    }
}

impl RepoConfig {
    fn validate(&self) -> Result<()> {
        if self.coordinator_capacity == 0
            || self.document_capacity == 0
            || self.event_capacity == 0
            || self.error_capacity == 0
            || self.peer_writer_capacity == 0
        {
            return Err(Error::Config(
                "all queue capacities must be greater than zero".into(),
            ));
        }
        if self.persistence_retry_min.is_zero() {
            return Err(Error::Config(
                "persistence_retry_min must be greater than zero".into(),
            ));
        }
        if self.persistence_retry_min > self.persistence_retry_max {
            return Err(Error::Config(
                "persistence_retry_min must not exceed persistence_retry_max".into(),
            ));
        }
        Ok(())
    }
}

fn actor_config(config: &RepoConfig) -> ActorConfig {
    ActorConfig {
        mailbox: config.document_capacity,
        events: config.event_capacity,
        debounce: config.persistence_debounce,
        retry_min: config.persistence_retry_min,
        retry_max: config.persistence_retry_max,
    }
}

enum Command {
    DocumentIds(oneshot::Sender<Result<Vec<DocumentId>>>),
    Get(DocumentId, oneshot::Sender<Result<Option<DocHandle>>>),
    Open(DocumentId, oneshot::Sender<Result<DocHandle>>),
    Initialize(oneshot::Sender<Result<DocHandle>>),
    Join(DocumentId, oneshot::Sender<Result<DocHandle>>),
    Create(Option<InitJob>, oneshot::Sender<Result<DocHandle>>),
    Offers(oneshot::Sender<Result<Vec<BootstrapOffer>>>),
    Flush(oneshot::Sender<Result<()>>),
    Remove(DocumentId, oneshot::Sender<Result<()>>),
    Shutdown(oneshot::Sender<Result<()>>),
}

/// Cloneable handle to the single repository coordinator.
#[derive(Clone)]
pub struct Repo {
    tx: mpsc::Sender<Command>,
    bootstrap: watch::Receiver<BootstrapStatus>,
    offers: watch::Receiver<Vec<BootstrapOffer>>,
    peer_sync: watch::Receiver<HashMap<PeerId, PeerSyncProgress>>,
    errors: broadcast::Sender<Error>,
    lifecycle: Lifecycle,
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
        config.validate()?;
        let ids = storage.list().await?;
        let mut record = control.load().await?;
        if record.is_none() && !ids.is_empty() {
            return Err(BootstrapError::OrphanedDocuments { documents: ids }.into());
        }
        // Validate every listed object before taking the network receiver. This
        // prevents corrupt or inconsistent local state from consuming events.
        let mut documents = HashMap::new();
        for id in &ids {
            let bytes = storage.load(*id).await?.ok_or_else(|| {
                StorageError::new("load", Some(*id), "listed snapshot disappeared")
            })?;
            let doc = Automerge::load(&bytes).map_err(|error| Error::Automerge {
                document: *id,
                message: error.to_string(),
            })?;
            documents.insert(*id, doc);
        }
        if let Some(current) = record.clone() {
            let root = current.root();
            match current {
                BootstrapRecord::Ready { .. } => {
                    if !documents.contains_key(&root) {
                        return Err(BootstrapError::Inconsistent {
                            root,
                            message: "Ready root snapshot is missing".into(),
                        }
                        .into());
                    }
                }
                BootstrapRecord::Creating { .. } => {
                    if documents.keys().any(|id| *id != root) {
                        return Err(BootstrapError::Inconsistent {
                            root,
                            message: "Creating contains conflicting documents".into(),
                        }
                        .into());
                    }
                    if let Some(doc) = documents.get(&root) {
                        if doc.get_heads().is_empty() {
                            return Err(BootstrapError::Inconsistent {
                                root,
                                message: "Creating root has empty history".into(),
                            }
                            .into());
                        }
                    } else {
                        let mut doc = Automerge::new();
                        doc.empty_commit(CommitOptions::default());
                        storage.store(root, doc.save()).await?;
                        storage.flush().await?;
                        documents.insert(root, doc);
                    }
                    control.store(BootstrapRecord::Ready { root }).await?;
                    control.flush().await?;
                    record = Some(BootstrapRecord::Ready { root });
                }
                BootstrapRecord::Joining { .. } => {
                    if documents.keys().any(|id| *id != root) {
                        return Err(BootstrapError::Inconsistent {
                            root,
                            message: "Joining contains conflicting documents".into(),
                        }
                        .into());
                    }
                    if documents
                        .get(&root)
                        .is_some_and(|doc| !doc.get_heads().is_empty())
                    {
                        control.store(BootstrapRecord::Ready { root }).await?;
                        control.flush().await?;
                        record = Some(BootstrapRecord::Ready { root });
                    } else {
                        documents.entry(root).or_insert_with(Automerge::new);
                    }
                }
            }
        }
        let initial = record
            .clone()
            .map(BootstrapStatus::from)
            .unwrap_or(NeedsDecision);
        let lifecycle = Lifecycle::new();
        let capture_gate: CaptureGate = Arc::new(RwLock::new(()));
        let (bootstrap_tx, bootstrap) = watch::channel(initial.clone());
        let (offers_tx, offers) = watch::channel(Vec::new());
        let (peer_sync_tx, peer_sync) = watch::channel(HashMap::new());
        let (errors, _) = broadcast::channel(config.error_capacity.max(1));
        let (actor_tx, actor_rx) = mpsc::channel(config.coordinator_capacity.max(1));
        let mut actors = HashMap::new();
        for (id, doc) in documents {
            let document_status = if matches!(initial, Joining { root } if root == id) {
                DocumentStatus::Loading
            } else {
                DocumentStatus::Ready
            };
            actors.insert(
                id,
                spawn_actor(
                    id,
                    doc,
                    document_status,
                    bootstrap.clone(),
                    actor_config(&config),
                    actor_tx.clone(),
                    errors.clone(),
                    storage.clone(),
                    lifecycle.clone(),
                    capture_gate.clone(),
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
            peer_sync_tx,
            relationships: HashMap::new(),
            errors: errors.clone(),
            actor_tx,
            lifecycle: lifecycle.clone(),
            capture_gate,
            control_dirty: false,
        };
        tokio::spawn(coordinator.run(commands, events, actor_rx));
        Ok(Self {
            tx,
            bootstrap,
            offers,
            peer_sync,
            errors,
            lifecycle,
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
    /// Watches retained whole-repository synchronization progress per authenticated peer.
    pub fn subscribe_peer_sync(&self) -> watch::Receiver<HashMap<PeerId, PeerSyncProgress>> {
        self.peer_sync.clone()
    }
    #[must_use]
    /// Returns the latest retained synchronization snapshot.
    pub fn peer_sync_progress(&self) -> HashMap<PeerId, PeerSyncProgress> {
        self.peer_sync.borrow().clone()
    }
    #[must_use]
    /// Subscribes to typed asynchronous persistence, network, and protocol errors.
    pub fn subscribe_errors(&self) -> broadcast::Receiver<Error> {
        self.errors.subscribe()
    }
    /// Returns retained bootstrap offers in deterministic order.
    pub async fn bootstrap_offers(&self) -> Result<Vec<BootstrapOffer>> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, Command::Offers).await
    }
    /// Lists every known document ID in deterministic order.
    pub async fn document_ids(&self) -> Result<Vec<DocumentId>> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, Command::DocumentIds).await
    }
    /// Returns a cached document handle, without fabricating a placeholder.
    pub async fn get(&self, id: DocumentId) -> Result<Option<DocHandle>> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, |reply| Command::Get(id, reply)).await
    }
    /// Opens a stored document or returns `Error::NotFound`.
    pub async fn open_document(&self, id: DocumentId) -> Result<DocHandle> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, |reply| Command::Open(id, reply)).await
    }
    /// Makes this repository the first ready device and returns its root.
    pub async fn initialize_new(&self) -> Result<DocHandle> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, Command::Initialize).await
    }
    /// Explicitly accepts a root offer and begins root-only synchronization.
    pub async fn join_existing(&self, root: DocumentId) -> Result<DocHandle> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, |reply| Command::Join(root, reply)).await
    }
    /// Creates an empty document with explicit synchronizable history.
    pub async fn create(&self) -> Result<DocHandle> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, |reply| Command::Create(None, reply)).await
    }
    /// Creates a document and atomically applies its initializer before sharing.
    pub async fn create_with<F>(&self, initialize: F) -> Result<DocHandle>
    where
        F: FnOnce(&mut Transaction<'_>) -> Result<()> + Send + 'static,
    {
        self.lifecycle.ensure_open()?;
        request(&self.tx, |reply| {
            Command::Create(Some(Box::new(initialize)), reply)
        })
        .await
    }
    /// Captures all actor revisions at one linearization point and aggregates
    /// document and applicable storage/control barrier failures.
    pub async fn flush(&self) -> Result<()> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, Command::Flush).await
    }
    /// Atomically stops admission, drains accepted work, best-effort flushes,
    /// closes every subsystem, and returns all phase-tagged failures.
    pub async fn shutdown(self) -> Result<()> {
        self.lifecycle.begin_shutdown()?;
        request(&self.tx, Command::Shutdown).await
    }
    /// Durably removes one non-root local snapshot without protocol deletion.
    pub async fn remove_local(&self, id: DocumentId) -> Result<()> {
        self.lifecycle.ensure_open()?;
        request(&self.tx, |reply| Command::Remove(id, reply)).await
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
    writer: mpsc::Sender<Bytes>,
    writer_task: tokio::task::JoinHandle<()>,
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
    peer_sync_tx: watch::Sender<HashMap<PeerId, PeerSyncProgress>>,
    relationships: HashMap<(PeerId, DocumentId), RelationshipSyncState>,
    errors: broadcast::Sender<Error>,
    actor_tx: mpsc::Sender<ActorOutput>,
    lifecycle: Lifecycle,
    capture_gate: CaptureGate,
    control_dirty: bool,
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
                Some(command) = commands.recv() => {
                    if let Command::Shutdown(reply) = command {
                        commands.close();
                        while let Some(accepted) = commands.recv().await {
                            let _ = self.handle_command(accepted).await;
                        }
                        let result = self.shutdown_all().await;
                        let _ = reply.send(result);
                        break;
                    }
                    if self.handle_command(command).await { break; }
                },
                Some(event) = events.recv(), if self.lifecycle.ensure_open().is_ok() => self.handle_network(event).await,
                Some(output) = actor_output.recv() => self.handle_actor_output(output).await,
                else => break,
            }
        }
    }

    fn status(&self) -> BootstrapStatus {
        self.status_tx.borrow().clone()
    }
    fn ensure_open(&self) -> Result<()> {
        if self.status() == Closed {
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
            Command::Remove(id, reply) => {
                let _ = reply.send(self.remove_local(id).await);
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
        self.control_dirty = true;
        self.control.flush().await?;
        self.control_dirty = false;
        let actor = self.spawn(root, Automerge::new(), DocumentStatus::Loading);
        if let Err(primary) = actor.initialize_hidden(None).await {
            let _ = actor.begin_remove().await;
            return Err(self.creation_failure(root, primary).await);
        }
        self.control.store(BootstrapRecord::Ready { root }).await?;
        self.control_dirty = true;
        self.control.flush().await?;
        self.control_dirty = false;
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
        self.control_dirty = true;
        self.control.flush().await?;
        self.control_dirty = false;
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
        let actor = self.spawn(id, Automerge::new(), DocumentStatus::Loading);
        if let Err(primary) = actor.initialize_hidden(initialize).await {
            let _ = actor.begin_remove().await;
            return Err(self.creation_failure(id, primary).await);
        }
        let handle = actor.handle.clone();
        self.actors.insert(id, actor);
        self.announce(id).await;
        self.attach_eligible(id).await;
        Ok(handle)
    }

    async fn creation_failure(&self, id: DocumentId, primary: Error) -> Error {
        let mut cleanup = Vec::new();
        if let Err(error) = self.storage.remove(id).await {
            cleanup.push(Failure {
                phase: FailurePhase::CleanupRemove,
                document: Some(id),
                revision: None,
                message: error.to_string(),
            });
        }
        if let Err(error) = self.storage.flush().await {
            cleanup.push(Failure {
                phase: FailurePhase::DocumentFlush,
                document: Some(id),
                revision: None,
                message: error.to_string(),
            });
        }
        Error::Creation {
            document: id,
            primary: Box::new(primary),
            cleanup,
        }
    }

    async fn remove_local(&mut self, id: DocumentId) -> Result<()> {
        let root = self.ensure_ready()?;
        if id == root {
            return Err(Error::Removal {
                document: id,
                reason: "the bootstrap root cannot be removed".into(),
            });
        }
        if !self.peers.is_empty() {
            return Err(Error::Removal {
                document: id,
                reason: "an authenticated peer session is connected".into(),
            });
        }
        let actor = self.actors.remove(&id).ok_or(Error::NotFound(id))?;
        // Closing waits for the actor's one ordered persistence worker, ensuring
        // no late store can recreate a successfully removed snapshot.
        let _ = actor.begin_remove().await;
        self.storage.remove(id).await?;
        self.storage.flush().await?;
        Ok(())
    }

    fn spawn(&self, id: DocumentId, doc: Automerge, status: DocumentStatus) -> ActorHandle {
        spawn_actor(
            id,
            doc,
            status,
            self.status_tx.subscribe(),
            actor_config(&self.config),
            self.actor_tx.clone(),
            self.errors.clone(),
            self.storage.clone(),
            self.lifecycle.clone(),
            self.capture_gate.clone(),
        )
    }

    async fn flush_all(&mut self) -> Result<()> {
        // Acquiring the exclusive side is the repository-wide flush
        // linearization point. Actors publish each new revision while holding
        // the shared side of this same gate.
        let targets = {
            let _capture = self.capture_gate.write().await;
            self.actors
                .iter()
                .map(|(id, actor)| (*id, actor.clone(), actor.revision()))
                .collect::<Vec<_>>()
        };
        let mut joins = tokio::task::JoinSet::new();
        for (id, actor, target) in targets {
            joins.spawn(async move { (id, target, actor.flush(target).await) });
        }
        let mut failures = Vec::new();
        while let Some(joined) = joins.join_next().await {
            match joined {
                Ok((_, _, Ok(()))) => {}
                Ok((id, revision, Err(error))) => failures.push(Failure {
                    phase: FailurePhase::DocumentStore,
                    document: Some(id),
                    revision: Some(revision),
                    message: error.to_string(),
                }),
                Err(error) => failures.push(Failure {
                    phase: FailurePhase::DocumentStore,
                    document: None,
                    revision: None,
                    message: error.to_string(),
                }),
            }
        }
        if let Err(error) = self.storage.flush().await {
            failures.push(Failure {
                phase: FailurePhase::DocumentFlush,
                document: error.document,
                revision: error.revision,
                message: error.to_string(),
            });
        }
        if self.control_dirty {
            match self.control.flush().await {
                Ok(()) => self.control_dirty = false,
                Err(error) => failures.push(Failure {
                    phase: FailurePhase::ControlFlush,
                    document: error.document,
                    revision: error.revision,
                    message: error.to_string(),
                }),
            }
        }
        failures.sort_by_key(|failure| (failure.phase, failure.document, failure.revision));
        if failures.is_empty() {
            Ok(())
        } else {
            Err(Error::Flush(failures))
        }
    }
    async fn shutdown_all(&mut self) -> Result<()> {
        let mut failures = match self.flush_all().await {
            Ok(()) => Vec::new(),
            Err(Error::Flush(items)) => items,
            Err(error) => vec![Failure {
                phase: FailurePhase::DocumentFlush,
                document: None,
                revision: None,
                message: error.to_string(),
            }],
        };
        self.status_tx.send_replace(Closed);
        for (id, actor) in &self.actors {
            if let Err(error) = actor.close().await {
                failures.push(Failure {
                    phase: FailurePhase::DocumentClose,
                    document: Some(*id),
                    revision: Some(actor.revision()),
                    message: error.to_string(),
                });
            }
        }
        for (_, state) in self.peers.drain() {
            state.writer_task.abort();
        }
        if let Err(error) = self.transport.close().await {
            failures.push(Failure {
                phase: FailurePhase::TransportClose,
                document: None,
                revision: None,
                message: error.to_string(),
            });
        }
        if let Err(error) = self.storage.flush().await {
            failures.push(Failure {
                phase: FailurePhase::DocumentFlush,
                document: error.document,
                revision: error.revision,
                message: error.to_string(),
            });
        }
        if let Err(error) = self.storage.close().await {
            failures.push(Failure {
                phase: FailurePhase::DocumentClose,
                document: error.document,
                revision: error.revision,
                message: error.to_string(),
            });
        }
        if let Err(error) = self.control.flush().await {
            failures.push(Failure {
                phase: FailurePhase::ControlFlush,
                document: error.document,
                revision: error.revision,
                message: error.to_string(),
            });
        }
        if let Err(error) = self.control.close().await {
            failures.push(Failure {
                phase: FailurePhase::ControlClose,
                document: error.document,
                revision: error.revision,
                message: error.to_string(),
            });
        }
        self.lifecycle.close();
        failures.sort_by_key(|failure| (failure.phase, failure.document, failure.revision));
        if failures.is_empty() {
            Ok(())
        } else {
            Err(Error::Shutdown(failures))
        }
    }

    async fn handle_network(&mut self, event: NetworkEvent) {
        match event {
            NetworkEvent::PeerConnected(peer) => {
                self.clear_peer_progress(&peer);
                self.detach_peer(&peer).await;
                if let Some(previous) = self.peers.remove(&peer) {
                    previous.writer_task.abort();
                }
                let (writer, mut frames) = mpsc::channel(self.config.peer_writer_capacity);
                let transport = self.transport.clone();
                let writer_peer = peer.clone();
                let output = self.actor_tx.clone();
                let writer_task = tokio::spawn(async move {
                    while let Some(frame) = frames.recv().await {
                        if let Err(error) = transport.send(&writer_peer, frame).await {
                            let _ = output
                                .send(ActorOutput::PeerWriterFailed(writer_peer.clone(), error))
                                .await;
                            return;
                        }
                    }
                });
                self.peers.insert(
                    peer.clone(),
                    PeerState {
                        hello: false,
                        remote: None,
                        eligibility: Eligibility::None,
                        writer,
                        writer_task,
                    },
                );
                self.peer_sync_tx.send_modify(|progress| {
                    progress.insert(
                        peer.clone(),
                        PeerSyncProgress {
                            peer: peer.clone(),
                            state: PeerSyncState::Connected,
                            documents: 0,
                            syncing_documents: Vec::new(),
                        },
                    );
                });
                self.send(&peer, Message::Hello(mode(&self.status()))).await;
            }
            NetworkEvent::PeerDisconnected(peer) => {
                self.detach_peer(&peer).await;
                if let Some(state) = self.peers.remove(&peer) {
                    state.writer_task.abort();
                }
                self.refresh_offers();
                self.clear_peer_progress(&peer);
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
            if let Some(state) = self.peers.remove(&peer) {
                state.writer_task.abort();
            }
            let _ = self.transport.close_peer(&peer).await;
            self.refresh_offers();
            self.clear_peer_progress(&peer);
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
            ActorOutput::DurableHistory(id) => self.persist_ready(id).await,
            ActorOutput::PeerWriterFailed(peer, error) => {
                let _ = self.errors.send(error.into());
                self.detach_peer(&peer).await;
                if let Some(state) = self.peers.remove(&peer) {
                    state.writer_task.abort();
                }
                self.refresh_offers();
                self.clear_peer_progress(&peer);
            }
            ActorOutput::SyncProgress {
                peer,
                document,
                state,
            } => {
                match state {
                    Some(state) => {
                        self.relationships.insert((peer.clone(), document), state);
                    }
                    None => {
                        self.relationships.remove(&(peer.clone(), document));
                    }
                }
                self.refresh_peer_progress(&peer);
            }
        }
    }
    async fn persist_ready(&mut self, id: DocumentId) {
        let Some(actor) = self.actors.get(&id) else {
            return;
        };
        if matches!(self.status(), Joining { root } if root == id) {
            if let Err(error) = self
                .control
                .store(BootstrapRecord::Ready { root: id })
                .await
            {
                let _ = self.errors.send(error.into());
                return;
            }
            self.control_dirty = true;
            if let Err(error) = self.control.flush().await {
                let _ = self.errors.send(error.into());
                return;
            }
            self.control_dirty = false;
            actor.mark_ready().await;
            self.status_tx.send_replace(Ready { root: id });
            self.broadcast_bootstrap().await;
            self.reconsider_all().await;
        } else {
            actor.mark_ready().await;
            self.attach_eligible(id).await;
            self.announce(id).await;
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
    fn clear_peer_progress(&mut self, peer: &PeerId) {
        self.relationships
            .retain(|(candidate, _), _| candidate != peer);
        self.peer_sync_tx.send_modify(|progress| {
            progress.remove(peer);
        });
    }

    fn refresh_peer_progress(&self, peer: &PeerId) {
        if !self.peers.contains_key(peer) {
            return;
        }
        let mut relationships: Vec<_> = self
            .relationships
            .iter()
            .filter(|((candidate, _), _)| candidate == peer)
            .map(|((_, document), state)| (*document, *state))
            .collect();
        relationships.sort_by_key(|(document, _)| *document);
        let syncing_documents = relationships
            .iter()
            .filter(|(_, state)| *state == RelationshipSyncState::Syncing)
            .map(|(document, _)| *document)
            .collect::<Vec<_>>();
        let state = if relationships.is_empty() {
            PeerSyncState::Connected
        } else if syncing_documents.is_empty() {
            PeerSyncState::Synced
        } else {
            PeerSyncState::Syncing
        };
        let value = PeerSyncProgress {
            peer: peer.clone(),
            state,
            documents: relationships.len(),
            syncing_documents,
        };
        self.peer_sync_tx.send_modify(|progress| {
            progress.insert(peer.clone(), value);
        });
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
                let queued = self
                    .peers
                    .get(peer)
                    .map(|state| state.writer.try_send(frame));
                if !matches!(queued, Some(Ok(()))) {
                    let error = crate::error::NetworkError::Transport {
                        peer: peer.clone(),
                        message: "peer writer queue is full or closed".into(),
                    };
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
        if let Some(state) = self.peers.remove(&peer) {
            state.writer_task.abort();
        }
        let _ = self.transport.close_peer(&peer).await;
        self.refresh_offers();
        self.clear_peer_progress(&peer);
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
