use std::{path::Path, sync::Arc, time::Duration};

use automerge::{ChangeHash, ROOT, ReadDoc, hydrate, transaction::Transactable};
use automerge_repo::{
    BootstrapStatus, ChangeOrigin, DocHandle, DocumentEvent, DocumentId, DocumentStatus, Error,
    FilesystemStorage, PeerId, PeerSyncState, Repo, RepoConfig,
    testing::{MemoryNetwork, MemoryStore, MemoryTransport},
};
use tokio::sync::broadcast;

const MAX_DELIVERY_ROUNDS: usize = 1_000;
const REQUIRED_IDLE_ROUNDS: usize = 12;
const EVENT_TIMEOUT: Duration = Duration::from_secs(1);

fn put(
    tx: &mut automerge::transaction::Transaction<'_>,
    key: &str,
    value: i64,
) -> automerge_repo::Result<()> {
    tx.put(ROOT, key, value)
        .map_err(|error| Error::Change(error.to_string()))
}

async fn wait_for_peer_state(repo: &Repo, peer: &PeerId, expected: PeerSyncState) {
    for _ in 0..MAX_DELIVERY_ROUNDS {
        if repo
            .peer_sync_progress()
            .get(peer)
            .is_some_and(|value| value.state == expected)
        {
            return;
        }
        tokio::task::yield_now().await;
    }
    panic!(
        "peer {peer} did not reach {expected:?}: {:?}",
        repo.peer_sync_progress()
    );
}

#[derive(Debug, PartialEq)]
struct Snapshot {
    heads: Vec<ChangeHash>,
    value: hydrate::Value,
}

async fn snapshot(handle: &DocHandle) -> Snapshot {
    handle
        .read(|doc| {
            let mut heads = doc.get_heads();
            heads.sort_unstable();
            Snapshot {
                heads,
                value: doc.hydrate(None),
            }
        })
        .await
        .unwrap()
}

async fn assert_value(handle: &DocHandle, key: &str, expected: i64) {
    let key = key.to_owned();
    assert_eq!(
        handle
            .read(move |doc| {
                doc.get(ROOT, key)
                    .unwrap()
                    .and_then(|(value, _)| value.to_i64())
            })
            .await
            .unwrap(),
        Some(expected)
    );
}

async fn drive_pair(a: &MemoryTransport, b: &MemoryTransport) {
    let mut idle = 0;
    for _ in 0..MAX_DELIVERY_ROUNDS {
        tokio::task::yield_now().await;
        if a.deliver_all().await + b.deliver_all().await == 0 {
            idle += 1;
            if idle >= REQUIRED_IDLE_ROUNDS {
                return;
            }
        } else {
            idle = 0;
        }
    }
    panic!("pair transport did not become quiescent");
}

async fn drive_network(network: &MemoryNetwork) {
    let mut idle = 0;
    for _ in 0..MAX_DELIVERY_ROUNDS {
        tokio::task::yield_now().await;
        if network.deliver_all().await == 0 {
            idle += 1;
            if idle >= REQUIRED_IDLE_ROUNDS {
                return;
            }
        } else {
            idle = 0;
        }
    }
    panic!("memory network did not become quiescent");
}

async fn drive_network_until_ready(network: &MemoryNetwork, repo: &Repo, handle: &DocHandle) {
    for _ in 0..MAX_DELIVERY_ROUNDS {
        network.deliver_all().await;
        tokio::task::yield_now().await;
        if handle.status() == DocumentStatus::Ready {
            return;
        }
        if handle
            .read(|doc| !doc.get_heads().is_empty())
            .await
            .unwrap()
        {
            repo.flush().await.unwrap();
        }
    }
    panic!("document did not become ready within the delivery bound");
}

async fn drive_network_until_document(
    network: &MemoryNetwork,
    repo: &Repo,
    id: DocumentId,
) -> DocHandle {
    for _ in 0..MAX_DELIVERY_ROUNDS {
        network.deliver_all().await;
        tokio::task::yield_now().await;
        if let Some(handle) = repo.get(id).await.unwrap() {
            drive_network_until_ready(network, repo, &handle).await;
            return handle;
        }
    }
    panic!("repository did not discover {id} within the delivery bound");
}

async fn drive_network_until_converged(
    network: &MemoryNetwork,
    left: &DocHandle,
    right: &DocHandle,
) {
    for _ in 0..MAX_DELIVERY_ROUNDS {
        network.deliver_all().await;
        tokio::task::yield_now().await;
        if snapshot(left).await == snapshot(right).await {
            drive_network(network).await;
            return;
        }
    }
    panic!("documents did not converge within the delivery bound");
}

async fn receive_event(receiver: &mut broadcast::Receiver<DocumentEvent>) -> DocumentEvent {
    tokio::time::timeout(EVENT_TIMEOUT, receiver.recv())
        .await
        .expect("timed out waiting for document event")
        .expect("document event channel closed")
}

struct ReadyPair {
    a: Repo,
    b: Repo,
    net_a: Arc<MemoryTransport>,
    net_b: Arc<MemoryTransport>,
    root_a: DocHandle,
}

async fn ready_pair() -> ReadyPair {
    let (net_a, net_b) = MemoryTransport::pair("acceptance-a", "acceptance-b", 512);
    let a = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(MemoryStore::default()),
        net_a.clone(),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let b = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(MemoryStore::default()),
        net_b.clone(),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let root_a = a.initialize_new().await.unwrap();
    net_a.connect().await;
    drive_pair(&net_a, &net_b).await;
    let root_b = b.join_existing(root_a.id()).await.unwrap();
    drive_pair(&net_a, &net_b).await;
    root_b.ready().await.unwrap();
    assert_eq!(snapshot(&root_a).await, snapshot(&root_b).await);
    ReadyPair {
        a,
        b,
        net_a,
        net_b,
        root_a,
    }
}

async fn open_filesystem_repo(
    path: &Path,
    transport: Arc<dyn automerge_repo::network::NetworkTransport>,
) -> Repo {
    let storage = FilesystemStorage::open(path).await.unwrap();
    Repo::open(
        Arc::new(storage.clone()),
        Arc::new(storage),
        transport,
        RepoConfig::default(),
    )
    .await
    .unwrap()
}

#[tokio::test]
async fn filesystem_repository_survives_flush_shutdown_and_reopen() {
    let directory = tempfile::tempdir().unwrap();
    let (first_transport, _) = MemoryTransport::pair("persistence-a", "unused-a", 64);
    let first = open_filesystem_repo(directory.path(), first_transport).await;
    let root = first.initialize_new().await.unwrap();
    let document = first.create_with(|tx| put(tx, "created", 1)).await.unwrap();
    document.change(|tx| put(tx, "mutated", 2)).await.unwrap();
    first.flush().await.unwrap();

    let root_id = root.id();
    let document_id = document.id();
    let root_before = snapshot(&root).await;
    let document_before = snapshot(&document).await;
    let ids_before = first.document_ids().await.unwrap();
    first.shutdown().await.unwrap();

    let (second_transport, _) = MemoryTransport::pair("persistence-b", "unused-b", 64);
    let reopened = open_filesystem_repo(directory.path(), second_transport).await;
    assert_eq!(
        reopened.bootstrap_status(),
        BootstrapStatus::Ready { root: root_id }
    );
    assert_eq!(reopened.document_ids().await.unwrap(), ids_before);
    let reopened_root = reopened.open_document(root_id).await.unwrap();
    let reopened_document = reopened.open_document(document_id).await.unwrap();
    assert_eq!(reopened_root.status(), DocumentStatus::Ready);
    assert_eq!(reopened_document.status(), DocumentStatus::Ready);
    assert_eq!(snapshot(&reopened_root).await, root_before);
    assert_eq!(snapshot(&reopened_document).await, document_before);
    assert_value(&reopened_document, "created", 1).await;
    assert_value(&reopened_document, "mutated", 2).await;
    reopened.shutdown().await.unwrap();
}

#[tokio::test]
async fn online_forward_reverse_sync_and_change_events() {
    let pair = ready_pair().await;
    let document_a = pair.a.create().await.unwrap();
    drive_pair(&pair.net_a, &pair.net_b).await;
    let document_b = pair.b.open_document(document_a.id()).await.unwrap();
    document_b.ready().await.unwrap();

    let mut local_events = document_a.subscribe();
    let mut remote_events = document_b.subscribe();
    let change = document_a.change(|tx| put(tx, "from-a", 10)).await.unwrap();
    let local = receive_event(&mut local_events).await;
    assert_eq!(local.document, document_a.id());
    assert_eq!(local.origin, ChangeOrigin::Local);
    assert_eq!(local.heads, change.heads);
    assert!(!local.patches.is_empty());

    drive_pair(&pair.net_a, &pair.net_b).await;
    let remote = receive_event(&mut remote_events).await;
    assert_eq!(remote.document, document_b.id());
    assert_eq!(
        remote.origin,
        ChangeOrigin::Remote(PeerId::from("acceptance-a"))
    );
    assert_eq!(remote.heads, snapshot(&document_b).await.heads);
    assert!(!remote.patches.is_empty());
    assert_eq!(snapshot(&document_a).await, snapshot(&document_b).await);

    document_b.change(|tx| put(tx, "from-b", 20)).await.unwrap();
    drive_pair(&pair.net_a, &pair.net_b).await;
    assert_eq!(snapshot(&document_a).await, snapshot(&document_b).await);
    assert_value(&document_a, "from-a", 10).await;
    assert_value(&document_a, "from-b", 20).await;
}

#[tokio::test]
async fn concurrent_offline_mutations_converge_after_reconnection() {
    let pair = ready_pair().await;
    let document_a = pair.a.create().await.unwrap();
    drive_pair(&pair.net_a, &pair.net_b).await;
    let document_b = pair.b.open_document(document_a.id()).await.unwrap();
    document_b.ready().await.unwrap();

    pair.net_a.disconnect().await;
    tokio::task::yield_now().await;
    document_a
        .change(|tx| put(tx, "offline-a", 30))
        .await
        .unwrap();
    document_b
        .change(|tx| put(tx, "offline-b", 40))
        .await
        .unwrap();
    pair.net_a.connect().await;
    drive_pair(&pair.net_a, &pair.net_b).await;

    assert_eq!(snapshot(&document_a).await, snapshot(&document_b).await);
    for document in [&document_a, &document_b] {
        assert_value(document, "offline-a", 30).await;
        assert_value(document, "offline-b", 40).await;
    }
}

#[tokio::test]
async fn initial_inventory_live_announcement_and_repeated_connection_are_idempotent() {
    let pair = ready_pair().await;
    pair.net_a.disconnect().await;
    tokio::task::yield_now().await;

    let mut initial = Vec::new();
    for index in 0..3 {
        let document = pair
            .a
            .create_with(move |tx| put(tx, "index", index))
            .await
            .unwrap();
        initial.push(document);
    }
    pair.net_a.connect().await;
    drive_pair(&pair.net_a, &pair.net_b).await;
    for document_a in &initial {
        let document_b = pair.b.open_document(document_a.id()).await.unwrap();
        document_b.ready().await.unwrap();
        assert_eq!(snapshot(document_a).await, snapshot(&document_b).await);
    }

    let fourth_a = pair.a.create_with(|tx| put(tx, "index", 3)).await.unwrap();
    drive_pair(&pair.net_a, &pair.net_b).await;
    let fourth_b = pair.b.open_document(fourth_a.id()).await.unwrap();
    fourth_b.ready().await.unwrap();
    assert_eq!(snapshot(&fourth_a).await, snapshot(&fourth_b).await);

    let before_repeated_inventory = snapshot(&fourth_b).await;
    pair.net_a.connect().await;
    drive_pair(&pair.net_a, &pair.net_b).await;
    let ids = pair.b.document_ids().await.unwrap();
    for expected in initial
        .iter()
        .map(DocHandle::id)
        .chain([fourth_a.id(), pair.root_a.id()])
    {
        assert_eq!(ids.iter().filter(|id| **id == expected).count(), 1);
    }
    assert_eq!(snapshot(&fourth_b).await, before_repeated_inventory);
}

#[tokio::test]
async fn repository_restart_uses_retained_snapshots_and_fresh_session_state() {
    let directory_b = tempfile::tempdir().unwrap();
    let network = MemoryNetwork::default();
    let peer_a = PeerId::from("restart-a");
    let peer_b = PeerId::from("restart-b");
    let endpoint_a = network.endpoint(peer_a.clone(), 512);
    let endpoint_b = network.endpoint(peer_b.clone(), 512);
    let repo_a = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(MemoryStore::default()),
        endpoint_a,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let repo_b = open_filesystem_repo(directory_b.path(), endpoint_b).await;

    let root_a = repo_a.initialize_new().await.unwrap();
    network.connect(&peer_a, &peer_b).await;
    drive_network(&network).await;
    let root_b = repo_b.join_existing(root_a.id()).await.unwrap();
    drive_network_until_ready(&network, &repo_b, &root_b).await;
    let document_a = repo_a
        .create_with(|tx| put(tx, "before-restart", 50))
        .await
        .unwrap();
    let document_b = drive_network_until_document(&network, &repo_b, document_a.id()).await;
    assert_eq!(snapshot(&document_a).await, snapshot(&document_b).await);
    repo_b.flush().await.unwrap();

    document_a
        .change(|tx| put(tx, "queued-old-session", 60))
        .await
        .unwrap();
    tokio::task::yield_now().await;
    network.disconnect(&peer_a, &peer_b).await;
    repo_b.shutdown().await.unwrap();
    document_a
        .change(|tx| put(tx, "while-b-offline", 70))
        .await
        .unwrap();

    let replacement_endpoint_b = network.endpoint(peer_b.clone(), 512);
    let replacement_b = open_filesystem_repo(directory_b.path(), replacement_endpoint_b).await;
    assert_eq!(
        replacement_b.bootstrap_status(),
        BootstrapStatus::Ready { root: root_a.id() }
    );
    let replacement_document_b = replacement_b.open_document(document_a.id()).await.unwrap();
    replacement_document_b
        .change(|tx| put(tx, "from-restarted-b", 80))
        .await
        .unwrap();
    network.connect(&peer_a, &peer_b).await;
    drive_network_until_converged(&network, &document_a, &replacement_document_b).await;

    assert_eq!(
        snapshot(&document_a).await,
        snapshot(&replacement_document_b).await
    );
    for (key, value) in [
        ("before-restart", 50),
        ("queued-old-session", 60),
        ("while-b-offline", 70),
        ("from-restarted-b", 80),
    ] {
        assert_value(&document_a, key, value).await;
        assert_value(&replacement_document_b, key, value).await;
    }
}

#[tokio::test]
async fn peer_sync_progress_is_retained_aggregated_and_fresh_per_connection() {
    let pair = ready_pair().await;
    let peer_b = PeerId::from("acceptance-b");
    wait_for_peer_state(&pair.a, &peer_b, PeerSyncState::Synced).await;
    let late = pair.a.subscribe_peer_sync();
    assert_eq!(
        late.borrow().get(&peer_b).unwrap().state,
        PeerSyncState::Synced
    );

    pair.root_a
        .change(|tx| put(tx, "regresses", 1))
        .await
        .unwrap();
    wait_for_peer_state(&pair.a, &peer_b, PeerSyncState::Syncing).await;
    drive_pair(&pair.net_a, &pair.net_b).await;
    wait_for_peer_state(&pair.a, &peer_b, PeerSyncState::Synced).await;

    let second = pair.a.create_with(|tx| put(tx, "second", 2)).await.unwrap();
    drive_pair(&pair.net_a, &pair.net_b).await;
    pair.b
        .open_document(second.id())
        .await
        .unwrap()
        .ready()
        .await
        .unwrap();
    wait_for_peer_state(&pair.a, &peer_b, PeerSyncState::Synced).await;
    assert_eq!(pair.a.peer_sync_progress()[&peer_b].documents, 2);

    pair.net_a.disconnect().await;
    for _ in 0..MAX_DELIVERY_ROUNDS {
        if !pair.a.peer_sync_progress().contains_key(&peer_b) {
            break;
        }
        tokio::task::yield_now().await;
    }
    assert!(!pair.a.peer_sync_progress().contains_key(&peer_b));
    pair.net_a.connect().await;
    drive_pair(&pair.net_a, &pair.net_b).await;
    wait_for_peer_state(&pair.a, &peer_b, PeerSyncState::Synced).await;
}
