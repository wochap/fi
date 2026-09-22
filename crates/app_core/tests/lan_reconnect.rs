//! Reconnect orchestration over real Quinn with in-process discovery: a
//! paired pair must find its way back to one session on its own, desktop focus
//! changes must not drop it, and the devices list must carry a real last-sync
//! time.
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use app_core::{
    AppCore, AppCoreConfig, DeviceId, DiscoveryScope, EndpointSource, FakeDiscoveryProvider,
    InMemorySecureKeyStore, LifecyclePolicy, ManualClock, PairingCandidate, PairingState,
    PeerConnectionState, QuinnTransportConfig, SyncStatus,
};

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis()
        .try_into()
        .unwrap()
}

struct Pair {
    _dirs: (tempfile::TempDir, tempfile::TempDir),
    existing: AppCore,
    joining: AppCore,
    existing_discovery: Arc<FakeDiscoveryProvider>,
    joining_discovery: Arc<FakeDiscoveryProvider>,
}

impl Pair {
    fn existing_id(&self) -> DeviceId {
        self.existing.device_id().unwrap()
    }
    fn joining_id(&self) -> DeviceId {
        self.joining.device_id().unwrap()
    }
    async fn shutdown(self) {
        self.existing.shutdown().await.unwrap();
        self.joining.shutdown().await.unwrap();
    }
}

async fn open(
    directory: &std::path::Path,
    seed: u8,
    policy: LifecyclePolicy,
) -> (AppCore, Arc<FakeDiscoveryProvider>) {
    // Wall-clock based so advertised expiries line up with the endpoint
    // registry's timeline.
    let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(
        now_ms(),
    ))));
    let core = AppCore::open_networked_with_discovery(
        directory,
        Arc::new(InMemorySecureKeyStore::seeded([seed; 32])),
        "127.0.0.1:0".parse().unwrap(),
        AppCoreConfig {
            lifecycle_policy: policy,
            ..AppCoreConfig::default()
        },
        QuinnTransportConfig::default(),
        discovery.clone(),
    )
    .await
    .unwrap();
    (core, discovery)
}

/// Pairs two fresh cores through the real SAS flow and waits until both hold
/// an authenticated session to each other.
async fn paired(seed: u8, policy: LifecyclePolicy) -> Pair {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let (existing, existing_discovery) = open(existing_dir.path(), seed, policy).await;
    let (joining, joining_discovery) = open(joining_dir.path(), seed + 1, policy).await;
    existing.create_new_dataset().await.unwrap();
    existing
        .create_collection("Food".into(), String::new())
        .await
        .unwrap();
    let window = 20_000;
    existing.start_pairing(window).await.unwrap();
    let joining_instance = joining.start_pairing(window).await.unwrap();
    let existing_session = existing
        .connect_pairing_candidate(
            PairingCandidate {
                instance_id: joining_instance,
                endpoint: joining.pairing_addr().unwrap(),
                expires_at_ms: now_ms() + window,
            },
            window,
        )
        .await
        .unwrap();
    let mut joining_state = joining.subscribe_pairing().unwrap();
    let joining_session = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let PairingState::AwaitingConfirmation { session_id, .. } =
                joining_state.borrow().clone()
            {
                break session_id;
            }
            joining_state.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
    let (existing_result, joining_result) = tokio::join!(
        existing.confirm_pairing(existing_session),
        joining.confirm_pairing(joining_session),
    );
    existing_result.unwrap();
    joining_result.unwrap();
    let pair = Pair {
        _dirs: (existing_dir, joining_dir),
        existing,
        joining,
        existing_discovery,
        joining_discovery,
    };
    wait_established(&pair.existing, pair.joining_id()).await;
    wait_established(&pair.joining, pair.existing_id()).await;
    pair
}

fn established(state: Option<&PeerConnectionState>) -> bool {
    matches!(
        state,
        Some(
            PeerConnectionState::Connected
                | PeerConnectionState::Syncing
                | PeerConnectionState::Synced
        )
    )
}

async fn wait_for(
    core: &AppCore,
    peer: DeviceId,
    what: &str,
    predicate: impl Fn(Option<&PeerConnectionState>) -> bool,
) {
    let mut states = core.subscribe_connections().unwrap();
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if predicate(states.borrow_and_update().get(&peer)) {
                return;
            }
            states.changed().await.unwrap();
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "{what}: last state {:?}",
            core.connection_states().get(&peer)
        )
    });
}

async fn wait_established(core: &AppCore, peer: DeviceId) {
    wait_for(core, peer, "session established", established).await;
}

fn has_group_advertisement(discovery: &FakeDiscoveryProvider) -> bool {
    discovery
        .advertisements()
        .iter()
        .any(|advertisement| matches!(advertisement.scope, DiscoveryScope::Group { .. }))
}

// Pins the Wi-Fi-toggle failure: after the session dropped, both sides kept
// their endpoints and sat at Offline forever because nothing redialed. Now the
// reconnect scheduler re-establishes one session without a restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dropped_session_is_reestablished_by_both_sides_without_restart() {
    let pair = paired(61, LifecyclePolicy::KeepNetworkingInBackground).await;
    let existing_cycle = drop_then_reestablish(&pair.existing, pair.joining_id());
    let joining_cycle = drop_then_reestablish(&pair.joining, pair.existing_id());
    pair.existing
        .disconnect_peer(pair.joining_id())
        .await
        .unwrap();
    tokio::join!(existing_cycle, joining_cycle);
    pair.shutdown().await;
}

/// Subscribes now, then resolves once `peer` has been seen disconnected and
/// afterwards established again, so a check that runs before the drop is
/// observed cannot pass vacuously.
fn drop_then_reestablish(
    core: &AppCore,
    peer: DeviceId,
) -> impl std::future::Future<Output = ()> + use<> {
    let mut states = core.subscribe_connections().unwrap();
    async move {
        tokio::time::timeout(Duration::from_secs(15), async {
            let mut dropped = false;
            loop {
                let state = states.borrow_and_update().get(&peer).cloned();
                dropped |= matches!(state, Some(PeerConnectionState::Disconnected));
                if dropped && established(state.as_ref()) {
                    return;
                }
                states.changed().await.unwrap();
            }
        })
        .await
        .expect("session dropped and came back");
    }
}

// Pins the reported orchestration gap: a trusted peer resolved by normal
// discovery was recorded as an endpoint but never dialed unless a secret
// rotation happened to be pending. Both registries are emptied first, so
// the only route back is the discovery upsert.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn discovery_upsert_for_trusted_peer_without_session_dials_it() {
    let pair = paired(63, LifecyclePolicy::KeepNetworkingInBackground).await;
    pair.existing
        .replace_endpoints(pair.joining_id(), EndpointSource::Lan, []);
    pair.joining
        .replace_endpoints(pair.existing_id(), EndpointSource::Lan, []);
    pair.existing
        .disconnect_peer(pair.joining_id())
        .await
        .unwrap();
    wait_for(
        &pair.existing,
        pair.joining_id(),
        "session dropped",
        |state| matches!(state, Some(PeerConnectionState::Disconnected)),
    )
    .await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        !established(pair.existing.connection_states().get(&pair.joining_id())),
        "no route is known, so nothing can reconnect yet"
    );

    let advertisement = pair
        .joining_discovery
        .advertisements()
        .into_iter()
        .find(|advertisement| matches!(advertisement.scope, DiscoveryScope::Group { .. }))
        .expect("joining advertises its group record");
    pair.existing_discovery
        .resolve(&advertisement, [127, 0, 0, 1].into())
        .unwrap();
    wait_established(&pair.existing, pair.joining_id()).await;
    wait_established(&pair.joining, pair.existing_id()).await;
    pair.shutdown().await;
}

// Pins the alt-tab failure: on desktop every focus loss reported `inactive`,
// which stopped discovery and closed every session.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn keep_networking_policy_ignores_background_reports() {
    let pair = paired(65, LifecyclePolicy::KeepNetworkingInBackground).await;
    let peer = pair.joining_id();
    assert!(has_group_advertisement(&pair.existing_discovery));
    let mut states = pair.existing.subscribe_connections().unwrap();
    let recorder = tokio::spawn(async move {
        let mut seen = Vec::new();
        while states.changed().await.is_ok() {
            seen.push(states.borrow_and_update().get(&peer).cloned());
        }
        seen
    });
    pair.existing.set_foreground(true).await.unwrap();
    pair.existing.set_foreground(false).await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(established(pair.existing.connection_states().get(&peer)));
    assert!(has_group_advertisement(&pair.existing_discovery));
    assert_ne!(pair.existing.sync_status(), SyncStatus::Offline);
    recorder.abort();
    let seen = recorder.await.unwrap_or_default();
    assert!(
        !seen
            .iter()
            .any(|state| matches!(state, Some(PeerConnectionState::Disconnected))),
        "no offline transition: {seen:?}"
    );
    // Shutdown is now the only desktop teardown, so it must stop discovery.
    let discovery = pair.existing_discovery.clone();
    pair.shutdown().await;
    assert!(!has_group_advertisement(&discovery));
}

// Pins that the Android behaviour is unchanged and selectable on a desktop
// host: background stops discovery and disconnects peers.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn suspend_policy_stops_discovery_and_disconnects_on_background() {
    let pair = paired(67, LifecyclePolicy::SuspendInBackground).await;
    let peer = pair.joining_id();
    pair.existing.set_foreground(true).await.unwrap();
    assert!(has_group_advertisement(&pair.existing_discovery));
    pair.existing.set_foreground(false).await.unwrap();
    assert_eq!(
        pair.existing.connection_states().get(&peer),
        Some(&PeerConnectionState::Disconnected)
    );
    assert!(!has_group_advertisement(&pair.existing_discovery));
    assert!(
        !pair
            .existing_discovery
            .browsing_scopes()
            .iter()
            .any(|scope| matches!(scope, DiscoveryScope::Group { .. }))
    );
    pair.shutdown().await;
}

// Pins "Last sync never": the timestamp was only ever written, as None, at
// pairing. It must be present whenever the row reports Synced.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn synced_peer_row_carries_a_last_sync_time() {
    let before = now_ms();
    let pair = paired(69, LifecyclePolicy::KeepNetworkingInBackground).await;
    let peer = pair.existing_id();
    wait_for(&pair.joining, peer, "peer synced", |state| {
        matches!(state, Some(PeerConnectionState::Synced))
    })
    .await;
    let record = pair
        .joining
        .trusted_devices()
        .unwrap()
        .into_iter()
        .find(|record| record.device_id == peer)
        .unwrap();
    let last_sync = record.last_sync_ms.expect("a synced peer has a sync time");
    assert!(last_sync >= before);
    assert!(record.last_seen_ms.is_some_and(|seen| seen >= before));
    pair.shutdown().await;
}
