use std::sync::Arc;

use automerge::{ROOT, ReadDoc, transaction::Transactable};
use fi_repo::{
    BootstrapStatus, Error, PeerId, Repo, RepoConfig,
    document::{ChangeOrigin, DocumentStatus},
    error::{BootstrapError, ProtocolError},
    network::NetworkTransport,
    protocol::{Codec, Message},
    testing::{MemoryNetwork, MemoryStore, MemoryTransport},
};

fn put(
    tx: &mut automerge::transaction::Transaction<'_>,
    key: &str,
    value: i64,
) -> fi_repo::Result<()> {
    tx.put(ROOT, key, value)
        .map_err(|error| Error::Change(error.to_string()))
}

async fn open_pair() -> (
    Repo,
    Repo,
    Arc<MemoryTransport>,
    Arc<MemoryTransport>,
    MemoryStore,
    MemoryStore,
    MemoryStore,
    MemoryStore,
) {
    let docs_a = MemoryStore::default();
    let ctrl_a = MemoryStore::default();
    let docs_b = MemoryStore::default();
    let ctrl_b = MemoryStore::default();
    let (net_a, net_b) = MemoryTransport::pair("a", "b", 256);
    let a = Repo::open(
        Arc::new(docs_a.clone()),
        Arc::new(ctrl_a.clone()),
        net_a.clone(),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let b = Repo::open(
        Arc::new(docs_b.clone()),
        Arc::new(ctrl_b.clone()),
        net_b.clone(),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    (a, b, net_a, net_b, docs_a, ctrl_a, docs_b, ctrl_b)
}

async fn drive(a: &MemoryTransport, b: &MemoryTransport) {
    let mut idle = 0;
    for _ in 0..500 {
        tokio::task::yield_now().await;
        let delivered = a.deliver_all().await + b.deliver_all().await;
        if delivered == 0 {
            idle += 1;
        } else {
            idle = 0;
        }
        if idle >= 10 {
            return;
        }
    }
    panic!("deterministic network failed to become idle");
}

async fn state(handle: &fi_repo::DocHandle) -> (Vec<automerge::ChangeHash>, String) {
    handle
        .read(|doc| {
            let mut keys: Vec<_> = doc.keys(ROOT).collect();
            keys.sort();
            let values: Vec<_> = keys
                .into_iter()
                .map(|key| {
                    let value = doc.get(ROOT, &key).unwrap();
                    (key, format!("{value:?}"))
                })
                .collect();
            (doc.get_heads(), format!("{values:?}"))
        })
        .await
        .unwrap()
}

#[tokio::test]
async fn bootstrap_gates_writes_and_orders_initialization() {
    let (repo, _, net, _, docs, control, _, _) = open_pair().await;
    assert_eq!(repo.bootstrap_status(), BootstrapStatus::NeedsDecision);
    assert!(matches!(
        repo.create().await,
        Err(Error::Bootstrap(BootstrapError::DecisionRequired))
    ));
    let root = repo.initialize_new().await.unwrap();
    assert_eq!(root.status(), DocumentStatus::Ready);
    assert!(
        matches!(repo.bootstrap_status(), BootstrapStatus::Ready { root: id } if id == root.id())
    );
    let stores: Vec<_> = control
        .operations()
        .into_iter()
        .filter(|entry| entry.starts_with("control_store:"))
        .collect();
    assert_eq!(
        stores,
        vec![
            format!("control_store:{}", root.id()),
            format!("control_store:{}", root.id())
        ]
    );
    assert!(
        docs.operations()
            .iter()
            .any(|entry| entry == &format!("store:{}", root.id()))
    );
    net.discard_pending();
}

#[tokio::test]
async fn document_change_rollback_noop_events_and_cached_handle() {
    let (repo, _, _, _, _, _, _, _) = open_pair().await;
    let root = repo.initialize_new().await.unwrap();
    let again = repo.open_document(root.id()).await.unwrap();
    assert_eq!(root.id(), again.id());
    let mut events = root.subscribe();
    let no_op = root.change(|_| Ok(7)).await.unwrap();
    assert!(no_op.hash.is_none());
    assert!(events.try_recv().is_err());
    let failed = root
        .change(|tx| {
            put(tx, "rolled_back", 1)?;
            Err::<(), _>(Error::Change("stop".into()))
        })
        .await;
    assert!(failed.is_err());
    assert!(events.try_recv().is_err());
    root.change(|tx| put(tx, "kept", 2)).await.unwrap();
    let event = events.recv().await.unwrap();
    assert_eq!(event.origin, ChangeOrigin::Local);
    assert!(!event.patches.is_empty());
    let rolled_back = root
        .read(|doc| doc.get(ROOT, "rolled_back").unwrap().is_none())
        .await
        .unwrap();
    assert!(rolled_back);
}

#[tokio::test]
async fn explicit_join_and_one_way_document_transfer_converge() {
    let (a, b, net_a, net_b, _, _, _, _) = open_pair().await;
    let root_a = a.initialize_new().await.unwrap();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    assert!(
        b.bootstrap_offers()
            .await
            .unwrap()
            .iter()
            .any(|offer| offer.root == root_a.id())
    );
    let root_b = b.join_existing(root_a.id()).await.unwrap();
    assert!(state(&root_b).await.0.is_empty());
    drive(&net_a, &net_b).await;
    assert!(matches!(b.bootstrap_status(), BootstrapStatus::Ready { root } if root == root_a.id()));
    assert_eq!(state(&root_a).await, state(&root_b).await);
    let doc_a = a.create_with(|tx| put(tx, "answer", 42)).await.unwrap();
    drive(&net_a, &net_b).await;
    let doc_b = b.open_document(doc_a.id()).await.unwrap();
    doc_b.ready().await.unwrap();
    assert_eq!(state(&doc_a).await, state(&doc_b).await);
}

#[tokio::test]
async fn concurrent_offline_changes_converge_after_fresh_reconnection() {
    let (a, b, net_a, net_b, _, _, _, _) = open_pair().await;
    let root = a.initialize_new().await.unwrap();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    b.join_existing(root.id()).await.unwrap();
    drive(&net_a, &net_b).await;
    let left = a.create().await.unwrap();
    drive(&net_a, &net_b).await;
    let right = b.open_document(left.id()).await.unwrap();
    net_a.disconnect().await;
    tokio::task::yield_now().await;
    left.change(|tx| put(tx, "left", 1)).await.unwrap();
    right.change(|tx| put(tx, "right", 2)).await.unwrap();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    assert_eq!(state(&left).await, state(&right).await);
}

#[tokio::test]
async fn shutdown_closes_handles_and_repository() {
    let (repo, _, _, _, _, _, _, _) = open_pair().await;
    let root = repo.initialize_new().await.unwrap();
    repo.shutdown().await.unwrap();
    assert_eq!(root.status(), DocumentStatus::Closed);
    assert!(repo.document_ids().await.is_err());
    assert!(root.read(|_| ()).await.is_err());
}

#[tokio::test]
async fn racing_bootstrap_decisions_accept_exactly_one() {
    let (repo, _, _, _, _, _, _, _) = open_pair().await;
    let left = repo.clone();
    let right = repo.clone();
    let offered = fi_repo::DocumentId::new();
    let initialize = tokio::spawn(async move { left.initialize_new().await });
    let join = tokio::spawn(async move { right.join_existing(offered).await });
    let results = [initialize.await.unwrap(), join.await.unwrap()];
    assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|result| matches!(
                result,
                Err(Error::Bootstrap(BootstrapError::DecisionAlreadyMade))
            ))
            .count(),
        1
    );
}

#[tokio::test]
async fn incompatible_roots_are_isolated() {
    let (a, b, net_a, net_b, _, _, _, _) = open_pair().await;
    a.initialize_new().await.unwrap();
    b.initialize_new().await.unwrap();
    let mut errors = a.subscribe_errors();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    assert!(matches!(
        errors.recv().await.unwrap(),
        Error::Bootstrap(BootstrapError::RootMismatch { .. })
    ));
}

#[tokio::test]
async fn non_hello_first_is_a_peer_scoped_protocol_error() {
    let docs = MemoryStore::default();
    let control = MemoryStore::default();
    let (net_repo, raw_peer) = MemoryTransport::pair("repo", "raw", 32);
    let repo = Repo::open(
        Arc::new(docs),
        Arc::new(control),
        net_repo.clone(),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let mut errors = repo.subscribe_errors();
    net_repo.connect().await;
    tokio::task::yield_now().await;
    raw_peer
        .send(
            &PeerId::from("repo"),
            Codec::encode(Message::Announce(fi_repo::DocumentId::new())).unwrap(),
        )
        .await
        .unwrap();
    raw_peer.deliver_all().await;
    tokio::task::yield_now().await;
    assert!(matches!(
        errors.recv().await.unwrap(),
        Error::Protocol(ProtocolError::HelloRequired)
    ));
}

#[tokio::test]
async fn duplicate_inventory_is_idempotent() {
    let docs = MemoryStore::default();
    let control = MemoryStore::default();
    let (net_repo, raw_peer) = MemoryTransport::pair("repo", "raw", 64);
    let repo = Repo::open(
        Arc::new(docs),
        Arc::new(control),
        net_repo.clone(),
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let root = repo.initialize_new().await.unwrap();
    net_repo.connect().await;
    tokio::task::yield_now().await;
    raw_peer
        .send(
            &PeerId::from("repo"),
            Codec::encode(Message::Hello(fi_repo::protocol::BootstrapMode::Ready(
                root.id(),
            )))
            .unwrap(),
        )
        .await
        .unwrap();
    raw_peer.deliver_all().await;
    tokio::task::yield_now().await;
    let unknown = fi_repo::DocumentId::new();
    for _ in 0..2 {
        raw_peer
            .send(
                &PeerId::from("repo"),
                Codec::encode(Message::Inventory(vec![unknown])).unwrap(),
            )
            .await
            .unwrap();
        raw_peer.deliver_all().await;
        tokio::task::yield_now().await;
    }
    let ids = repo.document_ids().await.unwrap();
    assert_eq!(ids.iter().filter(|id| **id == unknown).count(), 1);
}

#[tokio::test]
async fn send_failure_is_reported_and_reconnection_uses_fresh_state() {
    let (a, b, net_a, net_b, _, _, _, _) = open_pair().await;
    let root = a.initialize_new().await.unwrap();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    b.join_existing(root.id()).await.unwrap();
    drive(&net_a, &net_b).await;
    let left = a.create().await.unwrap();
    drive(&net_a, &net_b).await;
    let right = b.open_document(left.id()).await.unwrap();
    let mut errors = a.subscribe_errors();
    net_a.fail_sends(true);
    left.change(|tx| put(tx, "after-failure", 1)).await.unwrap();
    tokio::task::yield_now().await;
    assert!(matches!(
        errors.recv().await.unwrap(),
        Error::Network(fi_repo::error::NetworkError::Transport { .. })
    ));
    net_a.fail_sends(false);
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    assert_eq!(state(&left).await, state(&right).await);
}

async fn drive_hub(network: &MemoryNetwork) {
    let mut idle = 0;
    for _ in 0..1000 {
        tokio::task::yield_now().await;
        let delivered = network.deliver_all().await;
        if delivered == 0 {
            idle += 1;
        } else {
            idle = 0;
        }
        if idle >= 12 {
            return;
        }
    }
    panic!("network did not become idle");
}

#[tokio::test]
async fn three_peer_updates_are_relayed_and_multiple_documents_propagate() {
    let network = MemoryNetwork::default();
    let a_id = PeerId::from("a");
    let b_id = PeerId::from("b");
    let c_id = PeerId::from("c");
    let a_net = network.endpoint(a_id.clone(), 512);
    let b_net = network.endpoint(b_id.clone(), 512);
    let c_net = network.endpoint(c_id.clone(), 512);
    let a = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(MemoryStore::default()),
        a_net,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let b = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(MemoryStore::default()),
        b_net,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let c = Repo::open(
        Arc::new(MemoryStore::default()),
        Arc::new(MemoryStore::default()),
        c_net,
        RepoConfig::default(),
    )
    .await
    .unwrap();
    let root = a.initialize_new().await.unwrap();
    network.connect(&a_id, &b_id).await;
    drive_hub(&network).await;
    b.join_existing(root.id()).await.unwrap();
    drive_hub(&network).await;
    network.connect(&b_id, &c_id).await;
    drive_hub(&network).await;
    c.join_existing(root.id()).await.unwrap();
    drive_hub(&network).await;
    let first = a.create_with(|tx| put(tx, "from-a", 1)).await.unwrap();
    let second = b.create_with(|tx| put(tx, "from-b", 2)).await.unwrap();
    drive_hub(&network).await;
    let first_c = c.open_document(first.id()).await.unwrap();
    let second_c = c.open_document(second.id()).await.unwrap();
    assert_eq!(state(&first).await, state(&first_c).await);
    assert_eq!(state(&second).await, state(&second_c).await);
}

#[tokio::test]
async fn deterministic_disconnect_schedule_eventually_converges() {
    let (a, b, net_a, net_b, _, _, _, _) = open_pair().await;
    let root = a.initialize_new().await.unwrap();
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    b.join_existing(root.id()).await.unwrap();
    drive(&net_a, &net_b).await;
    let left = a.create().await.unwrap();
    drive(&net_a, &net_b).await;
    let right = b.open_document(left.id()).await.unwrap();
    let mut seed = 7_u64;
    for round in 0..24 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        if seed & 3 == 0 {
            net_a.disconnect().await;
        }
        let key = format!("k{round}");
        if seed & 1 == 0 {
            left.change(move |tx| put(tx, &key, round)).await.unwrap();
        } else {
            right.change(move |tx| put(tx, &key, round)).await.unwrap();
        }
        if seed & 3 == 1 {
            net_a.connect().await;
            drive(&net_a, &net_b).await;
        }
    }
    net_a.connect().await;
    drive(&net_a, &net_b).await;
    assert_eq!(state(&left).await, state(&right).await);
}
