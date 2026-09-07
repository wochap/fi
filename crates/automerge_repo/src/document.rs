//! Bounded actors that exclusively own Automerge documents and persistence state.

use crate::{
    BootstrapStatus, DocumentId, Error, PeerId, Result,
    error::{BootstrapError, LifecycleError, NetworkError, StorageError},
    lifecycle::{CaptureGate, Lifecycle},
    storage::StorageAdapter,
    sync::RelationshipSyncState,
};
use automerge::{
    Automerge, ChangeHash, Patch, PatchLog,
    sync::{Message as SyncMessage, State as SyncState, SyncDoc},
    transaction::{CommitOptions, Transaction},
};
use std::{
    any::Any,
    collections::HashMap,
    future::pending,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    sync::{broadcast, mpsc, oneshot, watch},
    time::{Instant, sleep_until},
};

type Owned = Box<dyn Any + Send>;
type ReadJob = Box<dyn FnOnce(&Automerge) -> Owned + Send>;
type ChangeJob = Box<dyn FnOnce(&mut Automerge) -> Result<ChangeEnvelope> + Send>;
type ChangeReply = Result<(Owned, Option<ChangeHash>, Vec<ChangeHash>)>;
pub(crate) type InitJob = Box<dyn FnOnce(&mut Transaction<'_>) -> Result<()> + Send>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DocumentStatus {
    Loading,
    Ready,
    Closed,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChangeOrigin {
    Local,
    Remote(PeerId),
}
#[derive(Clone, Debug, PartialEq)]
pub struct DocumentEvent {
    pub document: DocumentId,
    pub origin: ChangeOrigin,
    pub heads: Vec<ChangeHash>,
    pub patches: Vec<Patch>,
}
#[derive(Debug)]
pub struct ChangeResult<T> {
    pub value: T,
    pub hash: Option<ChangeHash>,
    pub heads: Vec<ChangeHash>,
}
struct ChangeEnvelope {
    value: Owned,
    hash: Option<ChangeHash>,
    patches: Vec<Patch>,
}

pub(crate) enum ActorOutput {
    Send {
        peer: PeerId,
        document: DocumentId,
        message: SyncMessage,
    },
    DurableHistory(DocumentId),
    PeerWriterFailed(PeerId, NetworkError),
    SyncProgress {
        peer: PeerId,
        document: DocumentId,
        state: Option<RelationshipSyncState>,
    },
}
enum Command {
    Read {
        job: ReadJob,
        reply: oneshot::Sender<Owned>,
    },
    Change {
        job: ChangeJob,
        reply: oneshot::Sender<ChangeReply>,
    },
    Initialize {
        job: Option<InitJob>,
        reply: oneshot::Sender<Result<()>>,
    },
    Attach(PeerId),
    Detach(PeerId),
    Receive {
        peer: PeerId,
        message: SyncMessage,
        reply: oneshot::Sender<Result<bool>>,
    },
    Flush {
        target: u64,
        reply: oneshot::Sender<Result<()>>,
    },
    MarkReady,
    Close(oneshot::Sender<Result<()>>),
}
enum ControlCommand {
    Remove(oneshot::Sender<Result<()>>),
}

#[derive(Clone)]
pub struct DocHandle {
    id: DocumentId,
    tx: mpsc::Sender<Command>,
    status: watch::Receiver<DocumentStatus>,
    events: broadcast::Sender<DocumentEvent>,
    bootstrap: watch::Receiver<BootstrapStatus>,
    lifecycle: Lifecycle,
    removing: Arc<AtomicBool>,
}
impl std::fmt::Debug for DocHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DocHandle")
            .field("id", &self.id)
            .field("status", &self.status())
            .finish()
    }
}
impl DocHandle {
    #[must_use]
    pub const fn id(&self) -> DocumentId {
        self.id
    }
    #[must_use]
    pub fn status(&self) -> DocumentStatus {
        *self.status.borrow()
    }
    #[must_use]
    pub fn subscribe(&self) -> broadcast::Receiver<DocumentEvent> {
        self.events.subscribe()
    }
    fn ensure_open(&self) -> Result<()> {
        self.lifecycle.ensure_open()?;
        if self.removing.load(Ordering::Acquire) {
            return Err(LifecycleError::DocumentClosed { document: self.id }.into());
        }
        if self.status() == DocumentStatus::Closed {
            Err(LifecycleError::DocumentClosed { document: self.id }.into())
        } else {
            Ok(())
        }
    }
    pub async fn ready(&self) -> Result<()> {
        let mut status = self.status.clone();
        loop {
            let current = *status.borrow_and_update();
            match current {
                DocumentStatus::Ready => return Ok(()),
                DocumentStatus::Closed => {
                    return Err(LifecycleError::DocumentClosed { document: self.id }.into());
                }
                DocumentStatus::Loading => status
                    .changed()
                    .await
                    .map_err(|_| LifecycleError::DocumentClosed { document: self.id })?,
            }
        }
    }
    pub async fn read<T, F>(&self, callback: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&Automerge) -> T + Send + 'static,
    {
        self.ensure_open()?;
        let (reply, receive) = oneshot::channel();
        self.tx
            .send(Command::Read {
                job: Box::new(move |doc| Box::new(callback(doc))),
                reply,
            })
            .await
            .map_err(|_| LifecycleError::DocumentClosed { document: self.id })?;
        receive
            .await
            .map_err(|_| Error::Actor {
                document: self.id,
                message: "read callback panicked or actor stopped".into(),
            })?
            .downcast::<T>()
            .map(|value| *value)
            .map_err(|_| Error::Actor {
                document: self.id,
                message: "read response type mismatch".into(),
            })
    }
    pub async fn change<T, F>(&self, callback: F) -> Result<ChangeResult<T>>
    where
        T: Send + 'static,
        F: FnOnce(&mut Transaction<'_>) -> Result<T> + Send + 'static,
    {
        self.ensure_open()?;
        if !self.bootstrap.borrow().is_ready() {
            return Err(BootstrapError::DecisionRequired.into());
        }
        if self.status() != DocumentStatus::Ready {
            return Err(LifecycleError::DocumentNotReady { document: self.id }.into());
        }
        let job =
            Box::new(
                move |doc: &mut Automerge| match doc.transact_and_log_patches(callback) {
                    Ok(mut success) => {
                        let patches = doc.make_patches(&mut success.patch_log);
                        Ok(ChangeEnvelope {
                            value: Box::new(success.result),
                            hash: success.hash,
                            patches,
                        })
                    }
                    Err(failure) => Err(failure.error),
                },
            );
        let (reply, receive) = oneshot::channel();
        self.tx
            .send(Command::Change { job, reply })
            .await
            .map_err(|_| LifecycleError::DocumentClosed { document: self.id })?;
        let (value, hash, heads) = receive.await.map_err(|_| Error::Actor {
            document: self.id,
            message: "change callback panicked or actor stopped".into(),
        })??;
        Ok(ChangeResult {
            value: *value.downcast::<T>().map_err(|_| Error::Actor {
                document: self.id,
                message: "change response type mismatch".into(),
            })?,
            hash,
            heads,
        })
    }
}

#[derive(Clone)]
pub(crate) struct ActorHandle {
    pub handle: DocHandle,
    tx: mpsc::Sender<Command>,
    revision: Arc<AtomicU64>,
    removing: Arc<AtomicBool>,
    control: mpsc::UnboundedSender<ControlCommand>,
}
impl ActorHandle {
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::Acquire)
    }
    async fn send(&self, command: Command) -> Result<()> {
        self.tx.send(command).await.map_err(|_| {
            LifecycleError::DocumentClosed {
                document: self.handle.id(),
            }
            .into()
        })
    }
    pub async fn attach(&self, peer: PeerId) -> Result<()> {
        self.send(Command::Attach(peer)).await
    }
    pub async fn initialize_hidden(&self, job: Option<InitJob>) -> Result<()> {
        let (tx, rx) = oneshot::channel();
        self.send(Command::Initialize { job, reply: tx }).await?;
        rx.await.map_err(|_| Error::Actor {
            document: self.handle.id(),
            message: "actor stopped during hidden initialization".into(),
        })?
    }
    pub async fn detach(&self, peer: PeerId) {
        let _ = self.tx.send(Command::Detach(peer)).await;
    }
    pub async fn receive(&self, peer: PeerId, message: SyncMessage) -> Result<bool> {
        let (tx, rx) = oneshot::channel();
        self.send(Command::Receive {
            peer,
            message,
            reply: tx,
        })
        .await?;
        rx.await.map_err(|_| Error::Actor {
            document: self.handle.id(),
            message: "actor stopped during sync".into(),
        })?
    }
    pub async fn flush(&self, target: u64) -> Result<()> {
        let (tx, rx) = oneshot::channel();
        self.send(Command::Flush { target, reply: tx }).await?;
        rx.await.map_err(|_| {
            Error::Lifecycle(LifecycleError::DocumentClosed {
                document: self.handle.id(),
            })
        })?
    }
    pub async fn mark_ready(&self) {
        let _ = self.tx.send(Command::MarkReady).await;
    }
    pub async fn close(&self) -> Result<()> {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(Command::Close(tx)).await.is_err() {
            return Ok(());
        }
        rx.await.unwrap_or(Ok(()))
    }
    pub async fn begin_remove(&self) -> Result<()> {
        self.removing.store(true, Ordering::Release);
        let (tx, rx) = oneshot::channel();
        self.control.send(ControlCommand::Remove(tx)).map_err(|_| {
            LifecycleError::DocumentClosed {
                document: self.handle.id(),
            }
        })?;
        rx.await.map_err(|_| {
            Error::Lifecycle(LifecycleError::DocumentClosed {
                document: self.handle.id(),
            })
        })?
    }
}

pub(crate) struct ActorConfig {
    pub mailbox: usize,
    pub events: usize,
    pub debounce: Duration,
    pub retry_min: Duration,
    pub retry_max: Duration,
}
#[allow(clippy::too_many_arguments)]
pub(crate) fn spawn_actor(
    id: DocumentId,
    doc: Automerge,
    initial: DocumentStatus,
    bootstrap: watch::Receiver<BootstrapStatus>,
    config: ActorConfig,
    output: mpsc::Sender<ActorOutput>,
    errors: broadcast::Sender<Error>,
    storage: Arc<dyn StorageAdapter>,
    lifecycle: Lifecycle,
    capture_gate: CaptureGate,
) -> ActorHandle {
    let (tx, rx) = mpsc::channel(config.mailbox);
    let (control_tx, control_rx) = mpsc::unbounded_channel();
    let (status_tx, status) = watch::channel(initial);
    let (events, _) = broadcast::channel(config.events);
    let revision = Arc::new(AtomicU64::new(0));
    let removing = Arc::new(AtomicBool::new(false));
    let actor_bootstrap = bootstrap.clone();
    let handle = DocHandle {
        id,
        tx: tx.clone(),
        status,
        events: events.clone(),
        bootstrap,
        lifecycle,
        removing: removing.clone(),
    };
    tokio::spawn(run_actor(
        id,
        doc,
        rx,
        control_rx,
        status_tx,
        events,
        output,
        errors,
        storage,
        revision.clone(),
        capture_gate,
        actor_bootstrap,
        config,
    ));
    ActorHandle {
        handle,
        tx,
        revision,
        removing,
        control: control_tx,
    }
}

struct StoreWork {
    revision: u64,
    snapshot: Vec<u8>,
    barrier: bool,
}
struct StoreCompletion {
    revision: u64,
    result: Result<(), StorageError>,
}
async fn persistence_worker(
    id: DocumentId,
    storage: Arc<dyn StorageAdapter>,
    mut work: mpsc::Receiver<StoreWork>,
    completion: mpsc::Sender<StoreCompletion>,
) {
    while let Some(work) = work.recv().await {
        let mut result = storage.store(id, work.snapshot).await;
        if result.is_ok() && work.barrier {
            result = storage.flush().await;
        }
        if completion
            .send(StoreCompletion {
                revision: work.revision,
                result,
            })
            .await
            .is_err()
        {
            break;
        }
    }
}
async fn deadline(value: Option<Instant>) {
    match value {
        Some(value) => sleep_until(value).await,
        None => pending::<()>().await,
    }
}

#[allow(clippy::possible_missing_else, clippy::too_many_arguments)]
async fn run_actor(
    id: DocumentId,
    mut doc: Automerge,
    mut commands: mpsc::Receiver<Command>,
    mut control: mpsc::UnboundedReceiver<ControlCommand>,
    status: watch::Sender<DocumentStatus>,
    events: broadcast::Sender<DocumentEvent>,
    output: mpsc::Sender<ActorOutput>,
    errors: broadcast::Sender<Error>,
    storage: Arc<dyn StorageAdapter>,
    published_revision: Arc<AtomicU64>,
    capture_gate: CaptureGate,
    bootstrap: watch::Receiver<BootstrapStatus>,
    config: ActorConfig,
) {
    let (work_tx, work_rx) = mpsc::channel(1);
    let (completion_tx, mut completion_rx) = mpsc::channel(1);
    tokio::spawn(persistence_worker(id, storage, work_rx, completion_tx));
    let mut peers = HashMap::<PeerId, SyncState>::new();
    let mut revision = 0_u64;
    let mut persisted_revision = 0_u64;
    let mut in_flight = None::<u64>;
    let mut due = None::<Instant>;
    let mut retry_attempt = 0_u32;
    let mut waiters = Vec::<(u64, oneshot::Sender<Result<()>>)>::new();
    let mut close_reply = None;
    let mut receiver_ended = false;
    let mut removal = false;
    loop {
        if receiver_ended && in_flight.is_none() {
            if removal {
                break;
            } else if persisted_revision < revision {
                let barrier = *status.borrow() == DocumentStatus::Loading;
                submit(&doc, revision, barrier, &work_tx, &mut in_flight).await;
            } else {
                break;
            }
        }
        tokio::select! {
            biased;
            Some(ControlCommand::Remove(reply)) = control.recv(), if !removal => {
                removal = true;
                commands.close();
                reject_queued(&mut commands, id);
                close_reply = Some(reply);
                receiver_ended = true;
                due = None;
            }
            command = commands.recv(), if !receiver_ended => match command {
                Some(Command::Read { job, reply }) => match catch_unwind(AssertUnwindSafe(|| job(&doc))) { Ok(value) => { let _ = reply.send(value); }, Err(_) => { receiver_ended = true; commands.close(); } },
                Some(Command::Change { job, reply }) => { let _capture = capture_gate.read().await; match catch_unwind(AssertUnwindSafe(|| job(&mut doc))) { Ok(Ok(change)) => { let heads = doc.get_heads(); if change.hash.is_some() { revision += 1; published_revision.store(revision, Ordering::Release); due = Some(Instant::now() + config.debounce); retry_attempt = 0; let _ = events.send(DocumentEvent { document: id, origin: ChangeOrigin::Local, heads: heads.clone(), patches: change.patches }); pump(&doc, id, &mut peers, &output).await; } let _ = reply.send(Ok((change.value, change.hash, heads))); }, Ok(Err(error)) => { let _ = reply.send(Err(error)); }, Err(_) => { receiver_ended = true; commands.close(); } } }
                Some(Command::Initialize { job, reply }) => {
                    if !doc.get_heads().is_empty() {
                        let _ = reply.send(Err(Error::Actor { document: id, message: "hidden actor was already initialized".into() }));
                        continue;
                    }
                    doc.empty_commit(CommitOptions::default());
                    let initialized = job.map_or(Ok(()), |job| doc.transact_and_log_patches(job).map(|_| ()).map_err(|failure| failure.error));
                    match initialized {
                        Ok(()) => {
                            revision += 1;
                            published_revision.store(revision, Ordering::Release);
                            waiters.push((revision, reply));
                            due = Some(Instant::now());
                        }
                        Err(error) => { let _ = reply.send(Err(error)); }
                    }
                }
                Some(Command::Attach(peer)) => {
                    peers.entry(peer.clone()).or_default();
                    report_progress(&doc, id, &peer, &peers, &output).await;
                    pump_one(&doc, id, peer, &mut peers, &output).await;
                }
                Some(Command::Detach(peer)) => {
                    peers.remove(&peer);
                    let _ = output.send(ActorOutput::SyncProgress { peer, document: id, state: None }).await;
                }
                Some(Command::Receive { peer, message, reply }) => {
                    let _capture = capture_gate.read().await;
                    let before = doc.get_heads();
                    let result = if let Some(sync_state) = peers.get_mut(&peer) {
                        let mut log = PatchLog::active();
                        doc.receive_sync_message_log_patches(sync_state, message, &mut log)
                            .map_err(|error| Error::Automerge { document: id, message: error.to_string() })
                            .map(|()| {
                                let heads = doc.get_heads();
                                let changed = heads != before;
                                if changed {
                                    let patches = doc.make_patches(&mut log);
                                    let _ = events.send(DocumentEvent { document: id, origin: ChangeOrigin::Remote(peer.clone()), heads, patches });
                                }
                                changed
                            })
                    } else {
                        Err(Error::Actor { document: id, message: format!("peer {peer} is not attached") })
                    };
                    if let Ok(changed) = result {
                        pump_one(&doc, id, peer.clone(), &mut peers, &output).await;
                        if changed {
                            revision += 1;
                            published_revision.store(revision, Ordering::Release);
                            let loading = *status.borrow() == DocumentStatus::Loading;
                            due = Some(Instant::now() + if loading { Duration::ZERO } else { config.debounce });
                            retry_attempt = 0;
                            pump(&doc, id, &mut peers, &output).await;
                            if loading && in_flight.is_none() {
                                due = None;
                                submit(&doc, revision, true, &work_tx, &mut in_flight).await;
                            }
                        }
                        report_progress(&doc, id, &peer, &peers, &output).await;
                    }
                    let _ = reply.send(result);
                }
                Some(Command::Flush { target, reply }) => { if persisted_revision >= target { let _ = reply.send(Ok(())); } else { waiters.push((target, reply)); due = Some(Instant::now()); } }
                Some(Command::MarkReady) => { let _ = status.send(DocumentStatus::Ready); }
                Some(Command::Close(reply)) => { commands.close(); close_reply = Some(reply); }
                None => { receiver_ended = true; due = Some(Instant::now()); }
            },
            Some(completed) = completion_rx.recv(), if in_flight.is_some() => { in_flight = None; match completed.result { Ok(()) => { persisted_revision = persisted_revision.max(completed.revision); retry_attempt = 0; let mut retained = Vec::new(); for (target, reply) in waiters.drain(..) { if target <= persisted_revision { let _ = reply.send(Ok(())); } else { retained.push((target, reply)); } } waiters = retained; if *status.borrow() == DocumentStatus::Loading && !doc.get_heads().is_empty() { let joining_root = matches!(&*bootstrap.borrow(), BootstrapStatus::Joining { root } if *root == id); if !joining_root { let _ = status.send(DocumentStatus::Ready); } let _ = output.send(ActorOutput::DurableHistory(id)).await; } if persisted_revision < revision { due = Some(Instant::now() + config.debounce); } }, Err(source) => { let source = source.with_revision(completed.revision); let _ = errors.send(Error::Persistence { document: id, revision: completed.revision, source: Box::new(source.clone()) }); let mut retained = Vec::new(); for (target, reply) in waiters.drain(..) { if target <= completed.revision { let _ = reply.send(Err(source.clone().into())); } else { retained.push((target, reply)); } } waiters = retained; let multiplier = 1_u32.checked_shl(retry_attempt.min(31)).unwrap_or(u32::MAX); let delay = config.retry_min.checked_mul(multiplier).unwrap_or(config.retry_max).min(config.retry_max); retry_attempt = retry_attempt.saturating_add(1); due = Some(Instant::now() + delay); if receiver_ended { break; } } } }
            () = deadline(due), if in_flight.is_none() => { due = None; if persisted_revision < revision { let barrier = *status.borrow() == DocumentStatus::Loading; submit(&doc, revision, barrier, &work_tx, &mut in_flight).await; } }
        }
        if close_reply.is_some() && commands.is_empty() {
            receiver_ended = true;
        }
    }
    drop(work_tx);
    let final_result = if persisted_revision >= revision {
        Ok(())
    } else {
        Err(
            StorageError::new("store", Some(id), "final persistence attempt failed")
                .with_revision(revision)
                .into(),
        )
    };
    for (_, reply) in waiters {
        let _ = reply.send(final_result.clone());
    }
    let _ = status.send(DocumentStatus::Closed);
    if let Some(reply) = close_reply {
        let _ = reply.send(final_result);
    }
}

fn reject_queued(commands: &mut mpsc::Receiver<Command>, id: DocumentId) {
    let closed = || Error::Lifecycle(LifecycleError::DocumentClosed { document: id });
    while let Ok(command) = commands.try_recv() {
        match command {
            Command::Read { reply, .. } => drop(reply),
            Command::Change { reply, .. } => {
                let _ = reply.send(Err(closed()));
            }
            Command::Initialize { reply, .. } => {
                let _ = reply.send(Err(closed()));
            }
            Command::Receive { reply, .. } => {
                let _ = reply.send(Err(closed()));
            }
            Command::Flush { reply, .. } => {
                let _ = reply.send(Err(closed()));
            }
            Command::Close(reply) => {
                let _ = reply.send(Ok(()));
            }
            Command::Attach(_) | Command::Detach(_) | Command::MarkReady => {}
        }
    }
}

async fn submit(
    doc: &Automerge,
    revision: u64,
    barrier: bool,
    work: &mpsc::Sender<StoreWork>,
    in_flight: &mut Option<u64>,
) {
    let snapshot = doc.save();
    if work
        .send(StoreWork {
            revision,
            snapshot,
            barrier,
        })
        .await
        .is_ok()
    {
        *in_flight = Some(revision);
    }
}
async fn pump(
    doc: &Automerge,
    id: DocumentId,
    peers: &mut HashMap<PeerId, SyncState>,
    output: &mpsc::Sender<ActorOutput>,
) {
    for peer in peers.keys().cloned().collect::<Vec<_>>() {
        pump_one(doc, id, peer, peers, output).await;
    }
}
async fn pump_one(
    doc: &Automerge,
    id: DocumentId,
    peer: PeerId,
    peers: &mut HashMap<PeerId, SyncState>,
    output: &mpsc::Sender<ActorOutput>,
) {
    if let Some(state) = peers.get_mut(&peer)
        && let Some(message) = doc.generate_sync_message(state)
    {
        let _ = output
            .send(ActorOutput::Send {
                peer: peer.clone(),
                document: id,
                message,
            })
            .await;
    }
    report_progress(doc, id, &peer, peers, output).await;
}

fn relationship_state(doc: &Automerge, state: &SyncState) -> RelationshipSyncState {
    let heads = doc.get_heads();
    if state.have_responded
        && !state.in_flight
        && state
            .their_heads
            .as_ref()
            .is_some_and(|remote| *remote == heads)
        && state.last_sent_heads == heads
    {
        RelationshipSyncState::Synced
    } else {
        RelationshipSyncState::Syncing
    }
}

async fn report_progress(
    doc: &Automerge,
    document: DocumentId,
    peer: &PeerId,
    peers: &HashMap<PeerId, SyncState>,
    output: &mpsc::Sender<ActorOutput>,
) {
    if let Some(state) = peers.get(peer) {
        let _ = output
            .send(ActorOutput::SyncProgress {
                peer: peer.clone(),
                document,
                state: Some(relationship_state(doc, state)),
            })
            .await;
    }
}
