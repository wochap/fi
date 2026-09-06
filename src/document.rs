//! Bounded actors that exclusively own Automerge documents.

use std::{
    any::Any,
    collections::HashMap,
    panic::{AssertUnwindSafe, catch_unwind},
};

use automerge::{
    Automerge, ChangeHash, Patch, PatchLog,
    sync::{Message as SyncMessage, State as SyncState, SyncDoc},
    transaction::Transaction,
};
use tokio::sync::{broadcast, mpsc, oneshot, watch};

use crate::{
    BootstrapStatus, DocumentId, Error, PeerId, Result,
    error::{BootstrapError, LifecycleError},
};

type Owned = Box<dyn Any + Send>;
type ReadJob = Box<dyn FnOnce(&Automerge) -> Owned + Send>;
type ChangeJob = Box<dyn FnOnce(&mut Automerge) -> Result<ChangeEnvelope> + Send>;
type ChangeReply = Result<(Owned, Option<ChangeHash>, Vec<ChangeHash>)>;

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
    HeadsChanged(DocumentId),
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
    Attach(PeerId),
    Detach(PeerId),
    Receive {
        peer: PeerId,
        message: SyncMessage,
        reply: oneshot::Sender<Result<bool>>,
    },
    Snapshot(oneshot::Sender<Vec<u8>>),
    MarkReady,
    Close(oneshot::Sender<()>),
}

/// Cloneable capability for one actor-owned document.
#[derive(Clone)]
pub struct DocHandle {
    id: DocumentId,
    tx: mpsc::Sender<Command>,
    status: watch::Receiver<DocumentStatus>,
    events: broadcast::Sender<DocumentEvent>,
    bootstrap: watch::Receiver<BootstrapStatus>,
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

    /// Runs a synchronous callback on the document actor and returns owned data.
    ///
    /// Borrowed document data cannot escape the actor:
    /// ```compile_fail
    /// async fn escape(handle: fi_repo::DocHandle) {
    ///     let _borrowed = handle.read(|document| document).await.unwrap();
    /// }
    /// ```
    pub async fn read<T, F>(&self, callback: F) -> Result<T>
    where
        T: Send + 'static,
        F: FnOnce(&Automerge) -> T + Send + 'static,
    {
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

    /// Runs a synchronous, nonblocking transaction. Callback errors roll back.
    pub async fn change<T, F>(&self, callback: F) -> Result<ChangeResult<T>>
    where
        T: Send + 'static,
        F: FnOnce(&mut Transaction<'_>) -> Result<T> + Send + 'static,
    {
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

pub(crate) struct ActorHandle {
    pub handle: DocHandle,
    tx: mpsc::Sender<Command>,
}

impl ActorHandle {
    pub async fn attach(&self, peer: PeerId) -> Result<()> {
        self.tx.send(Command::Attach(peer)).await.map_err(|_| {
            LifecycleError::DocumentClosed {
                document: self.handle.id(),
            }
            .into()
        })
    }
    pub async fn detach(&self, peer: PeerId) {
        let _ = self.tx.send(Command::Detach(peer)).await;
    }
    pub async fn receive(&self, peer: PeerId, message: SyncMessage) -> Result<bool> {
        let (tx, rx) = oneshot::channel();
        self.tx
            .send(Command::Receive {
                peer,
                message,
                reply: tx,
            })
            .await
            .map_err(|_| LifecycleError::DocumentClosed {
                document: self.handle.id(),
            })?;
        rx.await.map_err(|_| Error::Actor {
            document: self.handle.id(),
            message: "actor stopped during sync".into(),
        })?
    }
    pub async fn snapshot(&self) -> Result<Vec<u8>> {
        let (tx, rx) = oneshot::channel();
        self.tx
            .send(Command::Snapshot(tx))
            .await
            .map_err(|_| LifecycleError::DocumentClosed {
                document: self.handle.id(),
            })?;
        rx.await.map_err(|_| {
            LifecycleError::DocumentClosed {
                document: self.handle.id(),
            }
            .into()
        })
    }
    pub async fn mark_ready(&self) {
        let _ = self.tx.send(Command::MarkReady).await;
    }
    pub async fn close(&self) {
        let (tx, rx) = oneshot::channel();
        if self.tx.send(Command::Close(tx)).await.is_ok() {
            let _ = rx.await;
        }
    }
}

pub(crate) fn spawn_actor(
    id: DocumentId,
    doc: Automerge,
    initial: DocumentStatus,
    bootstrap: watch::Receiver<BootstrapStatus>,
    mailbox: usize,
    event_capacity: usize,
    output: mpsc::Sender<ActorOutput>,
) -> ActorHandle {
    let (tx, rx) = mpsc::channel(mailbox.max(1));
    let (status_tx, status) = watch::channel(initial);
    let (events, _) = broadcast::channel(event_capacity.max(1));
    let handle = DocHandle {
        id,
        tx: tx.clone(),
        status,
        events: events.clone(),
        bootstrap,
    };
    tokio::spawn(run_actor(id, doc, rx, status_tx, events, output));
    ActorHandle { handle, tx }
}

async fn run_actor(
    id: DocumentId,
    mut doc: Automerge,
    mut commands: mpsc::Receiver<Command>,
    status: watch::Sender<DocumentStatus>,
    events: broadcast::Sender<DocumentEvent>,
    output: mpsc::Sender<ActorOutput>,
) {
    let mut peers = HashMap::<PeerId, SyncState>::new();
    while let Some(command) = commands.recv().await {
        match command {
            Command::Read { job, reply } => match catch_unwind(AssertUnwindSafe(|| job(&doc))) {
                Ok(value) => {
                    let _ = reply.send(value);
                }
                Err(_) => break,
            },
            Command::Change { job, reply } => {
                match catch_unwind(AssertUnwindSafe(|| job(&mut doc))) {
                    Ok(Ok(change)) => {
                        let heads = doc.get_heads();
                        if change.hash.is_some() {
                            let _ = events.send(DocumentEvent {
                                document: id,
                                origin: ChangeOrigin::Local,
                                heads: heads.clone(),
                                patches: change.patches,
                            });
                            pump(&doc, id, &mut peers, &output).await;
                            let _ = output.send(ActorOutput::HeadsChanged(id)).await;
                        }
                        let _ = reply.send(Ok((change.value, change.hash, heads)));
                    }
                    Ok(Err(error)) => {
                        let _ = reply.send(Err(error));
                    }
                    Err(_) => break,
                }
            }
            Command::Attach(peer) => {
                peers.entry(peer.clone()).or_default();
                pump_one(&doc, id, peer, &mut peers, &output).await;
            }
            Command::Detach(peer) => {
                peers.remove(&peer);
            }
            Command::Receive {
                peer,
                message,
                reply,
            } => {
                let before = doc.get_heads();
                let result = if let Some(sync_state) = peers.get_mut(&peer) {
                    let mut log = PatchLog::active();
                    doc.receive_sync_message_log_patches(sync_state, message, &mut log)
                        .map_err(|error| Error::Automerge {
                            document: id,
                            message: error.to_string(),
                        })
                        .map(|()| {
                            let heads = doc.get_heads();
                            let changed = heads != before;
                            if changed {
                                let patches = doc.make_patches(&mut log);
                                let _ = events.send(DocumentEvent {
                                    document: id,
                                    origin: ChangeOrigin::Remote(peer.clone()),
                                    heads,
                                    patches,
                                });
                            }
                            changed
                        })
                } else {
                    Err(Error::Actor {
                        document: id,
                        message: format!("peer {peer} is not attached"),
                    })
                };
                if let Ok(changed) = result {
                    pump_one(&doc, id, peer.clone(), &mut peers, &output).await;
                    if changed {
                        pump(&doc, id, &mut peers, &output).await;
                        let _ = output.send(ActorOutput::HeadsChanged(id)).await;
                    }
                }
                let _ = reply.send(result);
            }
            Command::Snapshot(reply) => {
                let _ = reply.send(doc.save());
            }
            Command::MarkReady => {
                let _ = status.send(DocumentStatus::Ready);
            }
            Command::Close(reply) => {
                let _ = status.send(DocumentStatus::Closed);
                let _ = reply.send(());
                return;
            }
        }
    }
    let _ = status.send(DocumentStatus::Closed);
}

async fn pump(
    doc: &Automerge,
    id: DocumentId,
    peers: &mut HashMap<PeerId, SyncState>,
    output: &mpsc::Sender<ActorOutput>,
) {
    let ids: Vec<_> = peers.keys().cloned().collect();
    for peer in ids {
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
                peer,
                document: id,
                message,
            })
            .await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use automerge::{ROOT, transaction::Transactable};
    use std::sync::{
        Arc, Barrier,
        atomic::{AtomicUsize, Ordering},
    };

    fn actor(capacity: usize) -> (ActorHandle, mpsc::Receiver<ActorOutput>) {
        let (_, bootstrap) = watch::channel(BootstrapStatus::Ready {
            root: DocumentId::new(),
        });
        let (output, rx) = mpsc::channel(32);
        (
            spawn_actor(
                DocumentId::new(),
                Automerge::new(),
                DocumentStatus::Ready,
                bootstrap,
                8,
                capacity,
                output,
            ),
            rx,
        )
    }
    fn put(tx: &mut Transaction<'_>, key: &str, value: i64) -> Result<()> {
        tx.put(ROOT, key, value)
            .map_err(|error| Error::Change(error.to_string()))
    }

    #[tokio::test]
    async fn noop_and_rollback_are_silent_while_changes_are_materialized() {
        let (actor, _output) = actor(8);
        let mut events = actor.handle.subscribe();
        assert!(
            actor
                .handle
                .change(|_| Ok(()))
                .await
                .unwrap()
                .hash
                .is_none()
        );
        assert!(
            actor
                .handle
                .change(|tx| {
                    put(tx, "bad", 1)?;
                    Err::<(), _>(Error::Change("rollback".into()))
                })
                .await
                .is_err()
        );
        assert!(events.try_recv().is_err());
        let changed = actor.handle.change(|tx| put(tx, "good", 2)).await.unwrap();
        assert!(changed.hash.is_some());
        let event = events.recv().await.unwrap();
        assert_eq!(event.origin, ChangeOrigin::Local);
        assert!(!event.patches.is_empty());
    }

    #[tokio::test]
    async fn subscriber_lag_is_visible() {
        let (actor, _output) = actor(1);
        let mut events = actor.handle.subscribe();
        actor.handle.change(|tx| put(tx, "a", 1)).await.unwrap();
        actor.handle.change(|tx| put(tx, "b", 2)).await.unwrap();
        assert!(matches!(
            events.recv().await,
            Err(broadcast::error::RecvError::Lagged(_))
        ));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn separate_actors_progress_and_one_actor_serializes() {
        let (first, _first_output) = actor(8);
        let (second, _second_output) = actor(8);
        let gate = Arc::new(Barrier::new(2));
        let entered = Arc::new(AtomicUsize::new(0));
        let gate_task = gate.clone();
        let entered_task = entered.clone();
        let slow = first.handle.clone();
        let pending = tokio::spawn(async move {
            slow.change(move |_| {
                entered_task.fetch_add(1, Ordering::SeqCst);
                gate_task.wait();
                Ok(())
            })
            .await
        });
        while entered.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
        second.handle.change(|tx| put(tx, "free", 1)).await.unwrap();
        let same = first.handle.clone();
        let queued = tokio::spawn(async move { same.change(|tx| put(tx, "ordered", 1)).await });
        tokio::task::yield_now().await;
        assert!(!queued.is_finished());
        gate.wait();
        pending.await.unwrap().unwrap();
        queued.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn callback_panic_closes_the_affected_handle() {
        let (actor, _output) = actor(8);
        assert!(
            actor
                .handle
                .read::<(), _>(|_| panic!("boom"))
                .await
                .is_err()
        );
        tokio::task::yield_now().await;
        assert_eq!(actor.handle.status(), DocumentStatus::Closed);
    }
}
