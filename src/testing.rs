//! Deterministic Stage 1 adapters for integration tests.

use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use bytes::Bytes;
use tokio::sync::{Notify, mpsc};

use crate::{
    BootstrapRecord, DocumentId, PeerId,
    error::{NetworkError, StorageError},
    network::{NetworkEvent, NetworkTransport},
    storage::{ControlStore, StorageAdapter},
};

#[derive(Default)]
struct StoreState {
    documents: BTreeMap<DocumentId, Vec<u8>>,
    record: Option<BootstrapRecord>,
    failures: HashSet<&'static str>,
    failure_counts: BTreeMap<&'static str, usize>,
    document_failure_counts: BTreeMap<(&'static str, DocumentId), usize>,
    blocked: HashSet<&'static str>,
    blocked_documents: HashSet<(&'static str, DocumentId)>,
    operations: Vec<String>,
    entered: Vec<String>,
    documents_closed: bool,
    control_closed: bool,
}

#[derive(Clone, Default)]
pub struct MemoryStore {
    state: Arc<Mutex<StoreState>>,
    changed: Arc<Notify>,
}

impl MemoryStore {
    #[must_use]
    pub fn documents(&self) -> BTreeMap<DocumentId, Vec<u8>> {
        self.state.lock().unwrap().documents.clone()
    }
    #[must_use]
    pub fn record(&self) -> Option<BootstrapRecord> {
        self.state.lock().unwrap().record.clone()
    }
    #[must_use]
    pub fn operations(&self) -> Vec<String> {
        self.state.lock().unwrap().operations.clone()
    }
    pub fn clear_operations(&self) {
        let mut state = self.state.lock().unwrap();
        state.operations.clear();
        state.entered.clear();
    }
    #[must_use]
    pub fn entered_operations(&self) -> Vec<String> {
        self.state.lock().unwrap().entered.clone()
    }
    #[must_use]
    pub fn documents_closed(&self) -> bool {
        self.state.lock().unwrap().documents_closed
    }
    #[must_use]
    pub fn control_closed(&self) -> bool {
        self.state.lock().unwrap().control_closed
    }
    pub fn fail(&self, operation: &'static str) {
        self.state.lock().unwrap().failures.insert(operation);
    }
    /// Fails the next `count` occurrences of an operation.
    pub fn fail_times(&self, operation: &'static str, count: usize) {
        self.state
            .lock()
            .unwrap()
            .failure_counts
            .insert(operation, count);
    }
    pub fn fail_document_times(&self, operation: &'static str, document: DocumentId, count: usize) {
        self.state
            .lock()
            .unwrap()
            .document_failure_counts
            .insert((operation, document), count);
    }
    pub fn clear_failure(&self, operation: &'static str) {
        self.state.lock().unwrap().failures.remove(operation);
    }
    pub fn block(&self, operation: &'static str) {
        self.state.lock().unwrap().blocked.insert(operation);
    }
    pub fn block_document(&self, operation: &'static str, document: DocumentId) {
        self.state
            .lock()
            .unwrap()
            .blocked_documents
            .insert((operation, document));
    }
    pub fn unblock_document(&self, operation: &'static str, document: DocumentId) {
        self.state
            .lock()
            .unwrap()
            .blocked_documents
            .remove(&(operation, document));
        self.changed.notify_waiters();
    }
    pub async fn wait_for_operation(&self, expected: &str) {
        loop {
            let notified = self.changed.notified();
            if self
                .state
                .lock()
                .unwrap()
                .entered
                .iter()
                .any(|operation| operation == expected)
            {
                return;
            }
            notified.await;
        }
    }
    pub fn unblock(&self, operation: &'static str) {
        self.state.lock().unwrap().blocked.remove(operation);
        self.changed.notify_waiters();
    }
    async fn before(
        &self,
        operation: &'static str,
        document: Option<DocumentId>,
    ) -> Result<(), StorageError> {
        let label = document.map_or_else(|| operation.into(), |id| format!("{operation}:{id}"));
        self.state.lock().unwrap().entered.push(label.clone());
        self.changed.notify_waiters();
        loop {
            let notified = self.changed.notified();
            {
                let mut state = self.state.lock().unwrap();
                if !state.blocked.contains(operation)
                    && document.is_none_or(|id| !state.blocked_documents.contains(&(operation, id)))
                {
                    state.operations.push(label.clone());
                    let closed = if operation.starts_with("control_") {
                        state.control_closed
                    } else {
                        state.documents_closed
                    };
                    if closed && !operation.ends_with("_close") {
                        return Err(StorageError::new(operation, document, "adapter is closed"));
                    }
                    self.changed.notify_waiters();
                    let counted_failure =
                        state
                            .failure_counts
                            .get_mut(operation)
                            .is_some_and(|remaining| {
                                if *remaining == 0 {
                                    false
                                } else {
                                    *remaining -= 1;
                                    true
                                }
                            });
                    let document_failure = document.is_some_and(|id| {
                        state
                            .document_failure_counts
                            .get_mut(&(operation, id))
                            .is_some_and(|remaining| {
                                if *remaining == 0 {
                                    false
                                } else {
                                    *remaining -= 1;
                                    true
                                }
                            })
                    });
                    if state.failures.contains(operation) || counted_failure || document_failure {
                        return Err(StorageError::new(operation, document, "injected failure"));
                    }
                    return Ok(());
                }
            }
            notified.await;
        }
    }
}

#[async_trait]
impl StorageAdapter for MemoryStore {
    async fn list(&self) -> Result<Vec<DocumentId>, StorageError> {
        self.before("list", None).await?;
        Ok(self
            .state
            .lock()
            .unwrap()
            .documents
            .keys()
            .copied()
            .collect())
    }
    async fn load(&self, id: DocumentId) -> Result<Option<Vec<u8>>, StorageError> {
        self.before("load", Some(id)).await?;
        Ok(self.state.lock().unwrap().documents.get(&id).cloned())
    }
    async fn store(&self, id: DocumentId, snapshot: Vec<u8>) -> Result<(), StorageError> {
        self.before("store", Some(id)).await?;
        self.state.lock().unwrap().documents.insert(id, snapshot);
        Ok(())
    }
    async fn remove(&self, id: DocumentId) -> Result<(), StorageError> {
        self.before("remove", Some(id)).await?;
        self.state.lock().unwrap().documents.remove(&id);
        Ok(())
    }
    async fn flush(&self) -> Result<(), StorageError> {
        self.before("document_flush", None).await
    }
    async fn close(&self) -> Result<(), StorageError> {
        self.before("document_close", None).await?;
        self.state.lock().unwrap().documents_closed = true;
        Ok(())
    }
}

#[async_trait]
impl ControlStore for MemoryStore {
    async fn load(&self) -> Result<Option<BootstrapRecord>, StorageError> {
        self.before("control_load", None).await?;
        Ok(self.state.lock().unwrap().record.clone())
    }
    async fn store(&self, record: BootstrapRecord) -> Result<(), StorageError> {
        self.before("control_store", Some(record.root())).await?;
        self.state.lock().unwrap().record = Some(record);
        Ok(())
    }
    async fn flush(&self) -> Result<(), StorageError> {
        self.before("control_flush", None).await
    }
    async fn close(&self) -> Result<(), StorageError> {
        self.before("control_close", None).await?;
        self.state.lock().unwrap().control_closed = true;
        Ok(())
    }
}

struct Pending {
    generation: u64,
    bytes: Bytes,
}
struct LinkState {
    connected: bool,
    generation: u64,
    fail_sends: bool,
    block_sends: bool,
    pending: VecDeque<Pending>,
}

/// One endpoint of a manually delivered authenticated in-memory link.
pub struct MemoryTransport {
    local: PeerId,
    remote: PeerId,
    events: Mutex<Option<mpsc::Receiver<NetworkEvent>>>,
    event_tx: mpsc::Sender<NetworkEvent>,
    remote_event_tx: mpsc::Sender<NetworkEvent>,
    outbound: Arc<Mutex<LinkState>>,
    inbound: Arc<Mutex<LinkState>>,
    changed: Arc<Notify>,
}

impl MemoryTransport {
    pub fn pair(
        a: impl Into<PeerId>,
        b: impl Into<PeerId>,
        capacity: usize,
    ) -> (Arc<Self>, Arc<Self>) {
        let a = a.into();
        let b = b.into();
        let (a_tx, a_rx) = mpsc::channel(capacity.max(1));
        let (b_tx, b_rx) = mpsc::channel(capacity.max(1));
        let ab = Arc::new(Mutex::new(LinkState {
            connected: false,
            generation: 0,
            fail_sends: false,
            block_sends: false,
            pending: VecDeque::new(),
        }));
        let ba = Arc::new(Mutex::new(LinkState {
            connected: false,
            generation: 0,
            fail_sends: false,
            block_sends: false,
            pending: VecDeque::new(),
        }));
        let changed = Arc::new(Notify::new());
        (
            Arc::new(Self {
                local: a.clone(),
                remote: b.clone(),
                events: Mutex::new(Some(a_rx)),
                event_tx: a_tx.clone(),
                remote_event_tx: b_tx.clone(),
                outbound: ab.clone(),
                inbound: ba.clone(),
                changed: changed.clone(),
            }),
            Arc::new(Self {
                local: b,
                remote: a,
                events: Mutex::new(Some(b_rx)),
                event_tx: b_tx,
                remote_event_tx: a_tx,
                outbound: ba,
                inbound: ab,
                changed,
            }),
        )
    }
    #[must_use]
    pub fn pending_len(&self) -> usize {
        self.outbound.lock().unwrap().pending.len()
    }
    pub fn fail_sends(&self, fail: bool) {
        self.outbound.lock().unwrap().fail_sends = fail;
    }
    pub fn block_sends(&self, block: bool) {
        self.outbound.lock().unwrap().block_sends = block;
        if !block {
            self.changed.notify_waiters();
        }
    }
    pub fn discard_pending(&self) {
        self.outbound.lock().unwrap().pending.clear();
    }
    pub async fn connect(&self) {
        for link in [&self.outbound, &self.inbound] {
            let mut link = link.lock().unwrap();
            link.generation += 1;
            link.connected = true;
            link.pending.clear();
        }
        let _ = self
            .event_tx
            .send(NetworkEvent::PeerConnected(self.remote.clone()))
            .await;
        let _ = self
            .remote_event_tx
            .send(NetworkEvent::PeerConnected(self.local.clone()))
            .await;
    }
    pub async fn disconnect(&self) {
        self.outbound.lock().unwrap().connected = false;
        self.inbound.lock().unwrap().connected = false;
        let _ = self
            .event_tx
            .send(NetworkEvent::PeerDisconnected(self.remote.clone()))
            .await;
        let _ = self
            .remote_event_tx
            .send(NetworkEvent::PeerDisconnected(self.local.clone()))
            .await;
    }
    pub async fn deliver_next(&self) -> bool {
        let pending = self.outbound.lock().unwrap().pending.pop_front();
        if let Some(item) = pending {
            let current = self.outbound.lock().unwrap().generation;
            if item.generation == current {
                let _ = self
                    .remote_event_tx
                    .send(NetworkEvent::Message {
                        peer: self.local.clone(),
                        bytes: item.bytes,
                    })
                    .await;
                return true;
            }
        }
        false
    }
    pub async fn deliver_all(&self) -> usize {
        let mut count = 0;
        while self.deliver_next().await {
            count += 1;
        }
        count
    }
}

#[async_trait]
impl NetworkTransport for MemoryTransport {
    fn take_events(&self) -> Result<mpsc::Receiver<NetworkEvent>, NetworkError> {
        self.events
            .lock()
            .unwrap()
            .take()
            .ok_or(NetworkError::EventsAlreadyTaken)
    }
    async fn send(&self, peer: &PeerId, frame: Bytes) -> Result<(), NetworkError> {
        loop {
            let notified = self.changed.notified();
            {
                let mut link = self.outbound.lock().unwrap();
                if peer != &self.remote || !link.connected || link.fail_sends {
                    return Err(NetworkError::Transport {
                        peer: peer.clone(),
                        message: "connection is unavailable".into(),
                    });
                }
                if !link.block_sends {
                    let generation = link.generation;
                    link.pending.push_back(Pending {
                        generation,
                        bytes: frame,
                    });
                    return Ok(());
                }
            }
            notified.await;
        }
    }
    async fn close_peer(&self, peer: &PeerId) -> Result<(), NetworkError> {
        if peer == &self.remote {
            self.disconnect().await;
            Ok(())
        } else {
            Err(NetworkError::Transport {
                peer: peer.clone(),
                message: "unknown peer".into(),
            })
        }
    }
    async fn close(&self) -> Result<(), NetworkError> {
        self.disconnect().await;
        Ok(())
    }
}

#[derive(Default)]
struct HubState {
    events: BTreeMap<PeerId, mpsc::Sender<NetworkEvent>>,
    links: BTreeMap<(PeerId, PeerId), LinkState>,
}

/// Deterministic multi-peer network used for fan-out integration tests.
#[derive(Clone, Default)]
pub struct MemoryNetwork {
    state: Arc<Mutex<HubState>>,
}

pub struct MemoryEndpoint {
    id: PeerId,
    state: Arc<Mutex<HubState>>,
    events: Mutex<Option<mpsc::Receiver<NetworkEvent>>>,
}

impl MemoryNetwork {
    #[must_use]
    pub fn endpoint(&self, id: impl Into<PeerId>, capacity: usize) -> Arc<MemoryEndpoint> {
        let id = id.into();
        let (tx, rx) = mpsc::channel(capacity.max(1));
        self.state.lock().unwrap().events.insert(id.clone(), tx);
        Arc::new(MemoryEndpoint {
            id,
            state: self.state.clone(),
            events: Mutex::new(Some(rx)),
        })
    }
    pub async fn connect(&self, a: &PeerId, b: &PeerId) {
        let (a_events, b_events) = {
            let mut state = self.state.lock().unwrap();
            for key in [(a.clone(), b.clone()), (b.clone(), a.clone())] {
                let link = state.links.entry(key).or_insert(LinkState {
                    connected: false,
                    generation: 0,
                    fail_sends: false,
                    block_sends: false,
                    pending: VecDeque::new(),
                });
                link.generation += 1;
                link.connected = true;
                link.pending.clear();
            }
            (state.events.get(a).cloned(), state.events.get(b).cloned())
        };
        if let Some(tx) = a_events {
            let _ = tx.send(NetworkEvent::PeerConnected(b.clone())).await;
        }
        if let Some(tx) = b_events {
            let _ = tx.send(NetworkEvent::PeerConnected(a.clone())).await;
        }
    }
    pub async fn disconnect(&self, a: &PeerId, b: &PeerId) {
        let (a_events, b_events) = {
            let mut state = self.state.lock().unwrap();
            if let Some(link) = state.links.get_mut(&(a.clone(), b.clone())) {
                link.connected = false;
            }
            if let Some(link) = state.links.get_mut(&(b.clone(), a.clone())) {
                link.connected = false;
            }
            (state.events.get(a).cloned(), state.events.get(b).cloned())
        };
        if let Some(tx) = a_events {
            let _ = tx.send(NetworkEvent::PeerDisconnected(b.clone())).await;
        }
        if let Some(tx) = b_events {
            let _ = tx.send(NetworkEvent::PeerDisconnected(a.clone())).await;
        }
    }
    pub async fn deliver_all(&self) -> usize {
        let deliveries = {
            let mut state = self.state.lock().unwrap();
            let mut deliveries = Vec::new();
            for ((from, to), link) in &mut state.links {
                if link.connected {
                    while let Some(pending) = link.pending.pop_front() {
                        if pending.generation == link.generation {
                            deliveries.push((from.clone(), to.clone(), pending.bytes));
                        }
                    }
                }
            }
            deliveries
        };
        let mut count = 0;
        for (from, to, bytes) in deliveries {
            let tx = self.state.lock().unwrap().events.get(&to).cloned();
            if let Some(tx) = tx {
                let _ = tx.send(NetworkEvent::Message { peer: from, bytes }).await;
                count += 1;
            }
        }
        count
    }
}

#[async_trait]
impl NetworkTransport for MemoryEndpoint {
    fn take_events(&self) -> Result<mpsc::Receiver<NetworkEvent>, NetworkError> {
        self.events
            .lock()
            .unwrap()
            .take()
            .ok_or(NetworkError::EventsAlreadyTaken)
    }
    async fn send(&self, peer: &PeerId, frame: Bytes) -> Result<(), NetworkError> {
        let mut state = self.state.lock().unwrap();
        let link = state
            .links
            .get_mut(&(self.id.clone(), peer.clone()))
            .ok_or_else(|| NetworkError::Transport {
                peer: peer.clone(),
                message: "connection is unavailable".into(),
            })?;
        if !link.connected || link.fail_sends {
            return Err(NetworkError::Transport {
                peer: peer.clone(),
                message: "connection is unavailable".into(),
            });
        }
        let generation = link.generation;
        link.pending.push_back(Pending {
            generation,
            bytes: frame,
        });
        Ok(())
    }
    async fn close_peer(&self, peer: &PeerId) -> Result<(), NetworkError> {
        MemoryNetwork {
            state: self.state.clone(),
        }
        .disconnect(&self.id, peer)
        .await;
        Ok(())
    }
    async fn close(&self) -> Result<(), NetworkError> {
        let peers: Vec<_> = self
            .state
            .lock()
            .unwrap()
            .links
            .keys()
            .filter(|(from, _)| from == &self.id)
            .map(|(_, to)| to.clone())
            .collect();
        let network = MemoryNetwork {
            state: self.state.clone(),
        };
        for peer in peers {
            network.disconnect(&self.id, &peer).await;
        }
        Ok(())
    }
}
