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
    InMemorySecureKeyStore, LifecyclePolicy, ManualClock, NetworkPreferences, PairingCandidate,
    PairingState, PeerConnectionState, QuinnTransportConfig, SyncStatus, reset_dataset,
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
    existing_keys: Arc<InMemorySecureKeyStore>,
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
    open_with_keys(
        directory,
        Arc::new(InMemorySecureKeyStore::seeded([seed; 32])),
        policy,
    )
    .await
}

async fn open_with_keys(
    directory: &std::path::Path,
    keys: Arc<InMemorySecureKeyStore>,
    policy: LifecyclePolicy,
) -> (AppCore, Arc<FakeDiscoveryProvider>) {
    // Wall-clock based so advertised expiries line up with the endpoint
    // registry's timeline.
    let discovery = Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(
        now_ms(),
    ))));
    let core = AppCore::open_networked_with_discovery(
        directory,
        keys,
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
    let existing_keys = Arc::new(InMemorySecureKeyStore::seeded([seed; 32]));
    let (existing, existing_discovery) =
        open_with_keys(existing_dir.path(), existing_keys.clone(), policy).await;
    let (joining, joining_discovery) = open(joining_dir.path(), seed + 1, policy).await;
    pair_cores(&existing, &joining).await;
    let pair = Pair {
        _dirs: (existing_dir, joining_dir),
        existing,
        joining,
        existing_discovery,
        joining_discovery,
        existing_keys,
    };
    wait_established(&pair.existing, pair.joining_id()).await;
    wait_established(&pair.joining, pair.existing_id()).await;
    pair
}

/// Runs the SAS pairing flow between an existing dataset and a fresh core.
async fn pair_cores(existing: &AppCore, joining: &AppCore) {
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
// Pins that the name the UI shows for this device is the one a peer
// receives in the pairing hello and records on the trust entry.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn local_device_name_matches_the_name_sent_in_the_hello() {
    let pair = paired(70, LifecyclePolicy::KeepNetworkingInBackground).await;
    let seen_by_joining = pair
        .joining
        .trusted_devices()
        .unwrap()
        .into_iter()
        .find(|record| record.device_id == pair.existing_id())
        .unwrap();
    assert_eq!(
        seen_by_joining.friendly_name,
        pair.existing.local_device_name()
    );
    let seen_by_existing = pair
        .existing
        .trusted_devices()
        .unwrap()
        .into_iter()
        .find(|record| record.device_id == pair.joining_id())
        .unwrap();
    assert_eq!(
        seen_by_existing.friendly_name,
        pair.joining.local_device_name()
    );
    pair.shutdown().await;
}

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

const OFF: NetworkPreferences = NetworkPreferences {
    discoverable: false,
    sync_enabled: false,
};

fn browses_group(discovery: &FakeDiscoveryProvider) -> bool {
    discovery
        .browsing_scopes()
        .iter()
        .any(|scope| matches!(scope, DiscoveryScope::Group { .. }))
}

/// Watches `core` for `window` and fails if it ever dials or holds a session.
async fn assert_never_dials(core: &AppCore, window: Duration) {
    let mut states = core.subscribe_connections().unwrap();
    let watch = async {
        loop {
            for state in states.borrow_and_update().values() {
                assert!(
                    !established(Some(state))
                        && !matches!(
                            state,
                            PeerConnectionState::Connecting { .. }
                                | PeerConnectionState::Authenticating { .. }
                        ),
                    "unexpected state while paused: {state:?}"
                );
            }
            if states.changed().await.is_err() {
                std::future::pending::<()>().await;
            }
        }
    };
    let _ = tokio::time::timeout(window, watch).await;
}

// Pins "never briefly on": both preferences are applied before networking
// starts at open.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn reopened_core_applies_stored_preferences_before_networking() {
    let pair = paired(71, LifecyclePolicy::KeepNetworkingInBackground).await;
    let Pair {
        _dirs: (existing_dir, joining_dir),
        existing,
        joining,
        existing_discovery,
        existing_keys,
        ..
    } = pair;
    let existing_id = existing.device_id().unwrap();
    existing.set_discoverable(false).await.unwrap();
    joining.set_sync_enabled(false).await.unwrap();
    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();

    let (existing, existing_discovery_after) = open_with_keys(
        existing_dir.path(),
        existing_keys.clone(),
        LifecyclePolicy::KeepNetworkingInBackground,
    )
    .await;
    existing.set_foreground(true).await.unwrap();
    assert!(!existing.network_preferences().discoverable);
    assert!(!has_group_advertisement(&existing_discovery_after));
    assert!(!browses_group(&existing_discovery_after));
    drop(existing_discovery);
    // The group secret survived the restart, so turning discovery back on
    // advertises at once: the absence above was the preference, not a
    // missing secret.
    existing.set_discoverable(true).await.unwrap();
    assert!(has_group_advertisement(&existing_discovery_after));
    existing.set_discoverable(false).await.unwrap();
    assert!(!has_group_advertisement(&existing_discovery_after));

    let (joining, _) = open(
        joining_dir.path(),
        72,
        LifecyclePolicy::KeepNetworkingInBackground,
    )
    .await;
    joining.set_foreground(true).await.unwrap();
    assert!(!joining.network_preferences().sync_enabled);
    assert_eq!(joining.sync_status(), SyncStatus::Paused);
    // The existing side is reachable at its current port, so only the pause
    // can keep the joining side from dialing it.
    let now = now_ms();
    joining.replace_endpoints(
        existing_id,
        EndpointSource::Lan,
        [app_core::NetworkEndpoint {
            address: existing.network_addr().unwrap(),
            source: EndpointSource::Lan,
            observed_at_ms: now,
            expires_at_ms: now + 60_000,
            interface_scope: None,
            last_success_ms: None,
            failures: 0,
            retry_after_ms: None,
        }],
    );
    assert_never_dials(&joining, Duration::from_millis(800)).await;
    assert_eq!(joining.sync_status(), SyncStatus::Paused);
    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}

// Android: returning to the foreground while paused restarts discovery (it
// is on) but dials no peer, and inbound connections stay refused.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn foreground_return_while_paused_dials_nothing_and_refuses_inbound() {
    let pair = paired(73, LifecyclePolicy::SuspendInBackground).await;
    let peer = pair.existing_id();
    pair.joining.set_foreground(true).await.unwrap();
    pair.joining.set_sync_enabled(false).await.unwrap();
    pair.joining.set_foreground(false).await.unwrap();
    pair.joining.set_foreground(true).await.unwrap();
    assert!(has_group_advertisement(&pair.joining_discovery));
    assert_never_dials(&pair.joining, Duration::from_millis(800)).await;
    assert!(!established(pair.joining.connection_states().get(&peer)));
    assert!(
        pair.existing
            .connect_peer(pair.joining_id(), now_ms())
            .await
            .is_err(),
        "the paused side refuses inbound connections"
    );
    assert!(!established(
        pair.existing.connection_states().get(&pair.joining_id())
    ));
    assert_eq!(pair.joining.sync_status(), SyncStatus::Paused);
    pair.shutdown().await;
}

// Desktop: the pause overrides the keep-alive policy, and resuming reconnects
// from known endpoints without waiting for a discovery announcement.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pause_closes_live_session_under_keep_alive_and_resume_reconnects() {
    let pair = paired(75, LifecyclePolicy::KeepNetworkingInBackground).await;
    let peer = pair.joining_id();
    pair.existing.set_sync_enabled(false).await.unwrap();
    wait_for(
        &pair.joining,
        pair.existing_id(),
        "session closed",
        |state| !established(state),
    )
    .await;
    pair.existing.set_foreground(true).await.unwrap();
    pair.existing.set_foreground(false).await.unwrap();
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert!(!established(pair.existing.connection_states().get(&peer)));
    assert!(!established(
        pair.joining.connection_states().get(&pair.existing_id())
    ));
    assert_eq!(pair.existing.sync_status(), SyncStatus::Paused);

    pair.existing.set_sync_enabled(true).await.unwrap();
    wait_established(&pair.existing, peer).await;
    wait_established(&pair.joining, pair.existing_id()).await;
    assert_ne!(pair.existing.sync_status(), SyncStatus::Paused);
    pair.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn preferences_survive_dataset_reset() {
    let directory = tempfile::tempdir().unwrap();
    let (core, _) = open(
        directory.path(),
        77,
        LifecyclePolicy::KeepNetworkingInBackground,
    )
    .await;
    core.create_new_dataset().await.unwrap();
    core.set_discoverable(false).await.unwrap();
    core.set_sync_enabled(false).await.unwrap();
    core.shutdown().await.unwrap();
    reset_dataset(
        directory.path(),
        Some(&InMemorySecureKeyStore::seeded([77; 32])),
    )
    .await
    .unwrap();
    let (core, discovery) = open(
        directory.path(),
        77,
        LifecyclePolicy::KeepNetworkingInBackground,
    )
    .await;
    assert_eq!(core.network_preferences(), OFF);
    assert!(!has_group_advertisement(&discovery));
    core.shutdown().await.unwrap();
}

// Explicit pairing is not governed by either preference, and completing it
// turns neither back on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pairing_with_both_preferences_off_completes_and_leaves_them_off() {
    let existing_dir = tempfile::tempdir().unwrap();
    let joining_dir = tempfile::tempdir().unwrap();
    let policy = LifecyclePolicy::KeepNetworkingInBackground;
    let (existing, existing_discovery) = open(existing_dir.path(), 79, policy).await;
    let (joining, joining_discovery) = open(joining_dir.path(), 80, policy).await;
    for core in [&existing, &joining] {
        core.set_discoverable(false).await.unwrap();
        core.set_sync_enabled(false).await.unwrap();
    }
    pair_cores(&existing, &joining).await;
    for core in [&existing, &joining] {
        assert_eq!(core.network_preferences(), OFF);
        assert_eq!(core.trusted_devices().unwrap().len(), 1);
        assert_eq!(core.sync_status(), SyncStatus::Paused);
    }
    assert!(matches!(
        joining.lifecycle_state(),
        app_core::ApplicationState::Ready { .. }
    ));
    assert!(!has_group_advertisement(&existing_discovery));
    assert!(!has_group_advertisement(&joining_discovery));
    assert_never_dials(&joining, Duration::from_millis(500)).await;
    existing.shutdown().await.unwrap();
    joining.shutdown().await.unwrap();
}
