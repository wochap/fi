//! Device-oriented endpoint selection and bounded connection orchestration.

use std::{
    cmp::Reverse,
    collections::{BTreeMap, HashMap},
    net::SocketAddr,
    sync::{
        Arc, Mutex, Weak,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

use async_trait::async_trait;
use tokio::sync::{Notify, Semaphore, watch};

use crate::{
    discovery::{AddressPolicy, Clock},
    identity::DeviceId,
};

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum EndpointSource {
    Lan,
    Tailscale,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NetworkEndpoint {
    pub address: SocketAddr,
    pub source: EndpointSource,
    pub observed_at_ms: u64,
    pub expires_at_ms: u64,
    pub interface_scope: Option<u32>,
    pub last_success_ms: Option<u64>,
    pub failures: u8,
    pub retry_after_ms: Option<u64>,
}

impl NetworkEndpoint {
    #[must_use]
    pub fn is_eligible(&self, now_ms: u64) -> bool {
        self.expires_at_ms > now_ms && self.retry_after_ms.is_none_or(|retry| retry <= now_ms)
    }

    pub fn record_failure(&mut self, now_ms: u64, minimum_ms: u64, maximum_ms: u64) {
        self.failures = self.failures.saturating_add(1).min(31);
        let shift = u32::from(self.failures.saturating_sub(1)).min(20);
        let delay = minimum_ms.saturating_mul(1_u64 << shift).min(maximum_ms);
        self.retry_after_ms = Some(now_ms.saturating_add(delay));
    }

    pub fn record_success(&mut self, now_ms: u64) {
        self.last_success_ms = Some(now_ms);
        self.failures = 0;
        self.retry_after_ms = None;
    }
}

/// Known endpoints per device, filtered by what the local socket can reach.
#[derive(Debug, Default)]
pub struct EndpointRegistry {
    policy: AddressPolicy,
    endpoints: BTreeMap<DeviceId, Vec<NetworkEndpoint>>,
}

impl EndpointRegistry {
    #[must_use]
    pub fn new(policy: AddressPolicy) -> Self {
        Self {
            policy,
            endpoints: BTreeMap::new(),
        }
    }
    #[must_use]
    pub const fn policy(&self) -> AddressPolicy {
        self.policy
    }
    pub fn remove(&mut self, device: DeviceId) {
        self.endpoints.remove(&device);
    }
    pub fn replace_source(
        &mut self,
        device: DeviceId,
        source: EndpointSource,
        replacements: impl IntoIterator<Item = NetworkEndpoint>,
    ) {
        let current = self.endpoints.entry(device).or_default();
        current.retain(|endpoint| endpoint.source != source);
        current.extend(
            replacements
                .into_iter()
                .filter(|endpoint| endpoint.source == source),
        );
    }

    /// Adds or refreshes one endpoint, keeping success/failure history for an
    /// address already known, and drops expired siblings from the same source.
    pub fn upsert(&mut self, device: DeviceId, endpoint: NetworkEndpoint) {
        let current = self.endpoints.entry(device).or_default();
        let now = endpoint.observed_at_ms;
        current
            .retain(|existing| existing.source != endpoint.source || existing.expires_at_ms > now);
        if let Some(existing) = current.iter_mut().find(|existing| {
            existing.address == endpoint.address && existing.source == endpoint.source
        }) {
            existing.observed_at_ms = endpoint.observed_at_ms;
            existing.expires_at_ms = existing.expires_at_ms.max(endpoint.expires_at_ms);
            existing.interface_scope = endpoint.interface_scope.or(existing.interface_scope);
            if endpoint.last_success_ms > existing.last_success_ms {
                existing.record_success(endpoint.last_success_ms.unwrap_or(now));
            }
        } else {
            current.push(endpoint);
        }
    }

    #[must_use]
    pub fn ranked(&self, device: DeviceId, now_ms: u64) -> Vec<NetworkEndpoint> {
        rank_endpoints_with_policy(
            self.endpoints
                .get(&device)
                .map(Vec::as_slice)
                .unwrap_or_default(),
            &self.policy,
            now_ms,
        )
    }

    /// Every device with at least one recorded endpoint, expired or not.
    #[must_use]
    pub fn devices(&self) -> Vec<DeviceId> {
        self.endpoints.keys().copied().collect()
    }

    /// Earliest time at or after `not_before_ms` when some reachable endpoint
    /// of `device` is both out of backoff and unexpired. `None` means waiting
    /// cannot help: every endpoint expires before its backoff ends, so only a
    /// fresh discovery can make the device dialable again.
    #[must_use]
    pub fn next_eligible_ms(&self, device: DeviceId, not_before_ms: u64) -> Option<u64> {
        self.endpoints
            .get(&device)?
            .iter()
            .filter(|endpoint| self.policy.admits_peer_address(endpoint.address.ip()))
            .filter_map(|endpoint| {
                let at = not_before_ms.max(endpoint.retry_after_ms.unwrap_or(0));
                (at < endpoint.expires_at_ms).then_some(at)
            })
            .min()
    }

    pub fn endpoint_mut(
        &mut self,
        device: DeviceId,
        address: SocketAddr,
    ) -> Option<&mut NetworkEndpoint> {
        self.endpoints
            .get_mut(&device)?
            .iter_mut()
            .find(|endpoint| endpoint.address == address)
    }
}

/// Ranks with the default policy (transport bound to `0.0.0.0`).
#[must_use]
pub fn rank_endpoints(endpoints: &[NetworkEndpoint], now_ms: u64) -> Vec<NetworkEndpoint> {
    rank_endpoints_with_policy(endpoints, &AddressPolicy::default(), now_ms)
}

/// Deterministic, side-effect-free ranking. An address the local socket cannot
/// reach is never returned, so it can never outrank a reachable one and an
/// all-unreachable set yields no endpoint.
#[must_use]
pub fn rank_endpoints_with_policy(
    endpoints: &[NetworkEndpoint],
    policy: &AddressPolicy,
    now_ms: u64,
) -> Vec<NetworkEndpoint> {
    let mut ranked: Vec<_> = endpoints
        .iter()
        .filter(|endpoint| {
            endpoint.is_eligible(now_ms) && policy.admits_peer_address(endpoint.address.ip())
        })
        .cloned()
        .collect();
    ranked.sort_by_key(|endpoint| {
        (
            endpoint.source,
            Reverse(endpoint.last_success_ms.unwrap_or(0)),
            endpoint.failures,
            AddressPolicy::rank(endpoint.address.ip()),
            Reverse(endpoint.observed_at_ms),
            endpoint.address,
            endpoint.interface_scope,
        )
    });
    ranked
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum ConnectionFailure {
    #[error("no eligible endpoint")]
    NoRoute,
    #[error("route failed: {0}")]
    Route(String),
    #[error("TLS failed: {0}")]
    Tls(String),
    #[error("trust failed: {0}")]
    Trust(String),
    #[error("stream failed: {0}")]
    Stream(String),
    #[error("transport failed: {0}")]
    Transport(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PeerConnectionState {
    Disconnected,
    Connecting { endpoint: SocketAddr },
    Authenticating { endpoint: SocketAddr },
    Connected,
    Syncing,
    Synced,
    Failed(ConnectionFailure),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SyncStatus {
    Offline,
    Searching,
    Connected,
    Syncing,
    Synced,
    Error,
}

impl ConnectionFailure {
    /// True for failures that a later attempt on the same or a newly
    /// discovered route can fix. A rejected key or certificate cannot be fixed
    /// by retrying, so those are not transient.
    #[must_use]
    pub const fn is_transient(&self) -> bool {
        matches!(
            self,
            Self::NoRoute | Self::Route(_) | Self::Transport(_) | Self::Stream(_)
        )
    }
}

/// Global status across peers. A route-level failure reads as `Searching`
/// because orchestration keeps retrying it with backoff and discovery may
/// supply a fresh address at any time: a phone in a pocket must not turn the
/// desktop chip red. Trust and TLS failures stay `Error`.
#[must_use]
pub fn aggregate_sync_status(states: &HashMap<DeviceId, PeerConnectionState>) -> SyncStatus {
    if states.is_empty()
        || states
            .values()
            .all(|state| matches!(state, PeerConnectionState::Disconnected))
    {
        SyncStatus::Offline
    } else if states.values().any(
        |state| matches!(state, PeerConnectionState::Failed(failure) if !failure.is_transient()),
    ) {
        SyncStatus::Error
    } else if states.values().any(|state| {
        matches!(
            state,
            PeerConnectionState::Connecting { .. }
                | PeerConnectionState::Authenticating { .. }
                | PeerConnectionState::Failed(_)
        )
    }) {
        SyncStatus::Searching
    } else if states
        .values()
        .any(|state| matches!(state, PeerConnectionState::Syncing))
    {
        SyncStatus::Syncing
    } else if states
        .values()
        .any(|state| matches!(state, PeerConnectionState::Connected))
    {
        SyncStatus::Connected
    } else {
        SyncStatus::Synced
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectionDirection {
    Inbound,
    Outbound,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SessionCandidate {
    pub direction: ConnectionDirection,
    pub generation: u64,
}

#[must_use]
pub fn is_preferred_initiator(local: DeviceId, remote: DeviceId) -> bool {
    local < remote
}

#[must_use]
pub fn choose_session(
    local: DeviceId,
    remote: DeviceId,
    left: SessionCandidate,
    right: SessionCandidate,
) -> SessionCandidate {
    let preferred = if is_preferred_initiator(local, remote) {
        ConnectionDirection::Outbound
    } else {
        ConnectionDirection::Inbound
    };
    [left, right]
        .into_iter()
        .max_by_key(|candidate| (candidate.direction == preferred, candidate.generation))
        .expect("two candidates")
}

#[async_trait]
pub trait PeerConnector: Send + Sync + 'static {
    async fn connect(
        &self,
        peer: DeviceId,
        endpoint: NetworkEndpoint,
    ) -> Result<u64, ConnectionFailure>;
}

/// Timing of automatic dials. Constructor parameters rather than app config:
/// no platform needs a different value yet.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DialTiming {
    /// Upper bound on one endpoint dial. Without it a stale address left over
    /// from before a Wi-Fi toggle waits for QUIC's idle timeout before the
    /// next, freshly discovered endpoint is tried.
    pub dial_timeout_ms: u64,
    /// How long the non-preferred side waits for the preferred initiator to
    /// reach it before dialing itself. Above one LAN handshake with slack, so
    /// duplicate sessions stay rare, but finite, so an absent or backgrounded
    /// preferred side cannot leave both devices offline.
    pub non_preferred_delay_ms: u64,
}

impl Default for DialTiming {
    fn default() -> Self {
        Self {
            dial_timeout_ms: 5_000,
            non_preferred_delay_ms: 1_500,
        }
    }
}

/// Wall-clock milliseconds, the same timeline endpoint expiry is recorded on.
struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX)
    }
}

/// Drives dials to trusted peers: on request (discovery, foreground resume,
/// explicit calls) and on its own retry schedule after a failure or a lost
/// session, until the peer's endpoints expire.
pub struct ConnectionManager {
    local: DeviceId,
    connector: Arc<dyn PeerConnector>,
    registry: Arc<Mutex<EndpointRegistry>>,
    attempts: Arc<Semaphore>,
    states: watch::Sender<HashMap<DeviceId, PeerConnectionState>>,
    retry_min_ms: u64,
    retry_max_ms: u64,
    timing: DialTiming,
    clock: Arc<dyn Clock>,
    /// Attempts in flight per peer, including a non-preferred side's wait.
    /// Distinct from the global semaphore: this one makes a burst of triggers
    /// for one peer collapse into a single attempt.
    in_flight: Arc<Mutex<HashMap<DeviceId, usize>>>,
    /// Earliest time the scheduler may retry a peer regardless of endpoint
    /// backoff; set after a lost session or a failed attempt so neither can
    /// turn into an immediate redial loop.
    not_before: Mutex<HashMap<DeviceId, u64>>,
    /// Set while the platform has suspended networking (Android background).
    suspended: AtomicBool,
    closed: AtomicBool,
    /// Re-evaluates the schedule when something other than a state change
    /// makes a peer dialable, such as an attempt releasing its claim.
    wake: Arc<Notify>,
    this: Weak<Self>,
}

impl ConnectionManager {
    pub fn new(
        local: DeviceId,
        connector: Arc<dyn PeerConnector>,
        registry: Arc<Mutex<EndpointRegistry>>,
        max_concurrent_attempts: usize,
    ) -> Result<Arc<Self>, &'static str> {
        Self::with_timing(
            local,
            connector,
            registry,
            max_concurrent_attempts,
            DialTiming::default(),
            Arc::new(SystemClock),
        )
    }

    /// Builds the manager and, inside a Tokio runtime, starts its reconnect
    /// scheduler. The scheduler holds only a weak reference and stops on
    /// [`Self::close`].
    pub fn with_timing(
        local: DeviceId,
        connector: Arc<dyn PeerConnector>,
        registry: Arc<Mutex<EndpointRegistry>>,
        max_concurrent_attempts: usize,
        timing: DialTiming,
        clock: Arc<dyn Clock>,
    ) -> Result<Arc<Self>, &'static str> {
        if max_concurrent_attempts == 0 {
            return Err("connection capacity must be greater than zero");
        }
        let (states, _) = watch::channel(HashMap::new());
        let manager = Arc::new_cyclic(|this| Self {
            local,
            connector,
            registry,
            attempts: Arc::new(Semaphore::new(max_concurrent_attempts)),
            states,
            retry_min_ms: 250,
            retry_max_ms: 30_000,
            timing,
            clock,
            in_flight: Arc::new(Mutex::new(HashMap::new())),
            not_before: Mutex::new(HashMap::new()),
            suspended: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            wake: Arc::new(Notify::new()),
            this: this.clone(),
        });
        if tokio::runtime::Handle::try_current().is_ok() {
            tokio::spawn(run_scheduler(
                Arc::downgrade(&manager),
                manager.states.subscribe(),
                manager.wake.clone(),
            ));
        }
        Ok(manager)
    }

    #[must_use]
    pub fn subscribe(&self) -> watch::Receiver<HashMap<DeviceId, PeerConnectionState>> {
        self.states.subscribe()
    }

    #[must_use]
    pub fn sync_status(&self) -> SyncStatus {
        aggregate_sync_status(&self.states.borrow())
    }

    pub fn set_state(&self, peer: DeviceId, state: PeerConnectionState) {
        log_transition(peer, &state);
        self.states.send_modify(|states| {
            states.insert(peer, state);
        });
    }

    #[must_use]
    pub fn states(&self) -> HashMap<DeviceId, PeerConnectionState> {
        self.states.borrow().clone()
    }

    /// Stops automatic dialing while the platform keeps networking off, and
    /// lets it resume afterwards. Explicit `connect_*` calls still work.
    pub fn set_suspended(&self, suspended: bool) {
        self.suspended.store(suspended, Ordering::Release);
        self.wake.notify_one();
    }

    /// Stops the scheduler and refuses further attempts. Called on shutdown so
    /// a replaced core does not keep dialing on a closed transport.
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.attempts.close();
        self.wake.notify_one();
    }

    fn automatic_dialing_allowed(&self) -> bool {
        !self.closed.load(Ordering::Acquire) && !self.suspended.load(Ordering::Acquire)
    }

    fn has_live_session(&self, peer: DeviceId) -> bool {
        self.states.borrow().get(&peer).is_some_and(is_live)
    }

    /// Asks for a connection to `peer` without waiting for it. A no-op when
    /// the peer already has a live session or an attempt in flight. The
    /// preferred initiator dials at once; the other side dials after
    /// `non_preferred_delay_ms` unless a session appeared meanwhile. When
    /// every known endpoint is still backed off, the scheduler dials once the
    /// earliest backoff ends instead.
    pub fn request_connect(&self, peer: DeviceId, now_ms: u64) {
        if !self.automatic_dialing_allowed() || self.has_live_session(peer) {
            return;
        }
        let dialable = self
            .registry
            .lock()
            .is_ok_and(|registry| !registry.ranked(peer, now_ms).is_empty());
        if dialable {
            self.start_attempt(peer);
        } else {
            self.wake.notify_one();
        }
    }

    /// Foreground-resume pass: dials every peer that has an eligible endpoint
    /// and no live session, without waiting for discovery to re-resolve it.
    pub fn reconnect_known_peers(&self, now_ms: u64) {
        let devices = self
            .registry
            .lock()
            .map(|registry| {
                registry
                    .devices()
                    .into_iter()
                    .filter(|device| !registry.ranked(*device, now_ms).is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        for peer in devices {
            if let Ok(mut not_before) = self.not_before.lock() {
                not_before.remove(&peer);
            }
            self.request_connect(peer, now_ms);
        }
    }

    /// Spawns one automatic attempt unless one is already in flight for the
    /// peer. Returns whether an attempt was started.
    fn start_attempt(&self, peer: DeviceId) -> bool {
        let Some(this) = self.this.upgrade() else {
            return false;
        };
        let Some(claim) = self.claim(peer, true) else {
            return false;
        };
        let delay = (!is_preferred_initiator(self.local, peer))
            .then(|| Duration::from_millis(self.timing.non_preferred_delay_ms));
        tokio::spawn(async move {
            let _claim = claim;
            if let Some(delay) = delay {
                tokio::time::sleep(delay).await;
                // The preferred initiator reached us while we waited.
                if this.has_live_session(peer) || !this.automatic_dialing_allowed() {
                    return;
                }
            }
            let now = this.clock.now_ms();
            let _ = this.dial(peer, now).await;
        });
        true
    }

    /// Registers an attempt for `peer`. An exclusive claim fails when another
    /// attempt is already in flight; a shared one (explicit dials) always
    /// succeeds but still keeps automatic attempts away.
    fn claim(&self, peer: DeviceId, exclusive: bool) -> Option<AttemptClaim> {
        let mut in_flight = self.in_flight.lock().ok()?;
        let count = in_flight.entry(peer).or_default();
        if exclusive && *count > 0 {
            return None;
        }
        *count += 1;
        Some(AttemptClaim {
            peer,
            in_flight: self.in_flight.clone(),
            wake: self.wake.clone(),
        })
    }

    pub async fn connect_preferred(
        &self,
        peer: DeviceId,
        now_ms: u64,
    ) -> Result<u64, ConnectionFailure> {
        if !is_preferred_initiator(self.local, peer) {
            return Err(ConnectionFailure::NoRoute);
        }
        self.connect_manual(peer, now_ms).await
    }

    /// Dials now, regardless of preference or backoff of automatic attempts.
    /// While it runs, discovery and the scheduler do not start another
    /// attempt for the same peer.
    pub async fn connect_manual(
        &self,
        peer: DeviceId,
        now_ms: u64,
    ) -> Result<u64, ConnectionFailure> {
        let _claim = self.claim(peer, false);
        self.dial(peer, now_ms).await
    }

    /// Walks the ranked endpoints once. Attempt states never overwrite a live
    /// session the sync bridge has already reported, so a redundant dial that
    /// fails does not mark a synced peer as failed.
    async fn dial(&self, peer: DeviceId, now_ms: u64) -> Result<u64, ConnectionFailure> {
        let _permit = self
            .attempts
            .acquire()
            .await
            .map_err(|_| ConnectionFailure::Transport("connection manager closed".into()))?;
        let started = tokio::time::Instant::now();
        let elapsed_now =
            || now_ms.saturating_add(started.elapsed().as_millis().try_into().unwrap_or(u64::MAX));
        let endpoints = self
            .registry
            .lock()
            .map_err(|_| ConnectionFailure::Transport("endpoint registry lock poisoned".into()))?
            .ranked(peer, now_ms);
        let mut last = ConnectionFailure::NoRoute;
        for endpoint in endpoints {
            self.set_attempt_state(
                peer,
                PeerConnectionState::Connecting {
                    endpoint: endpoint.address,
                },
            );
            self.set_attempt_state(
                peer,
                PeerConnectionState::Authenticating {
                    endpoint: endpoint.address,
                },
            );
            let timeout = Duration::from_millis(self.timing.dial_timeout_ms);
            let result =
                tokio::time::timeout(timeout, self.connector.connect(peer, endpoint.clone()))
                    .await
                    .unwrap_or_else(|_| {
                        Err(ConnectionFailure::Route(format!(
                            "dial timed out after {} ms",
                            self.timing.dial_timeout_ms
                        )))
                    });
            match result {
                Ok(generation) => {
                    if let Ok(mut registry) = self.registry.lock()
                        && let Some(route) = registry.endpoint_mut(peer, endpoint.address)
                    {
                        route.record_success(elapsed_now());
                    }
                    if let Ok(mut not_before) = self.not_before.lock() {
                        not_before.remove(&peer);
                    }
                    self.set_attempt_state(peer, PeerConnectionState::Connected);
                    return Ok(generation);
                }
                Err(error) => {
                    if let Ok(mut registry) = self.registry.lock()
                        && let Some(route) = registry.endpoint_mut(peer, endpoint.address)
                    {
                        route.record_failure(elapsed_now(), self.retry_min_ms, self.retry_max_ms);
                    }
                    last = error;
                }
            }
        }
        if let Ok(mut not_before) = self.not_before.lock() {
            not_before.insert(peer, elapsed_now().saturating_add(self.retry_min_ms));
        }
        self.set_attempt_state(peer, PeerConnectionState::Failed(last.clone()));
        Err(last)
    }

    fn set_attempt_state(&self, peer: DeviceId, state: PeerConnectionState) {
        let applied = self.states.send_if_modified(|states| {
            if states.get(&peer).is_some_and(is_established) {
                return false;
            }
            states.insert(peer, state.clone());
            true
        });
        if applied {
            log_transition(peer, &state);
        }
    }

    /// One scheduler pass: notes lost sessions, starts every retry that is
    /// due, and returns when the next one will be.
    fn schedule(
        &self,
        previous: &HashMap<DeviceId, PeerConnectionState>,
        current: &HashMap<DeviceId, PeerConnectionState>,
        now: u64,
    ) -> Option<u64> {
        let Ok(mut not_before) = self.not_before.lock() else {
            return None;
        };
        for (peer, state) in current {
            let lost = matches!(state, PeerConnectionState::Disconnected)
                && previous
                    .get(peer)
                    .is_some_and(|before| !matches!(before, PeerConnectionState::Disconnected));
            if lost {
                not_before.insert(*peer, now.saturating_add(self.retry_min_ms));
            }
        }
        if !self.automatic_dialing_allowed() {
            return None;
        }
        let candidates = current
            .iter()
            .filter(|(_, state)| match state {
                PeerConnectionState::Disconnected => true,
                PeerConnectionState::Failed(failure) => failure.is_transient(),
                _ => false,
            })
            .map(|(peer, _)| (*peer, now.max(not_before.get(peer).copied().unwrap_or(0))))
            .collect::<Vec<_>>();
        drop(not_before);
        let registry = self.registry.lock().ok()?;
        let due = candidates
            .into_iter()
            .filter_map(|(peer, not_before)| {
                registry
                    .next_eligible_ms(peer, not_before)
                    .map(|at| (peer, at))
            })
            .collect::<Vec<_>>();
        drop(registry);
        let mut next = None::<u64>;
        for (peer, at) in due {
            if at <= now {
                // A peer already in flight is re-evaluated when its claim drops.
                self.start_attempt(peer);
            } else {
                next = Some(next.map_or(at, |earliest| earliest.min(at)));
            }
        }
        next
    }
}

/// Holds a peer's in-flight slot; releasing it wakes the scheduler so a
/// retry that came due while the attempt ran is not missed.
struct AttemptClaim {
    peer: DeviceId,
    in_flight: Arc<Mutex<HashMap<DeviceId, usize>>>,
    wake: Arc<Notify>,
}

impl Drop for AttemptClaim {
    fn drop(&mut self) {
        if let Ok(mut in_flight) = self.in_flight.lock()
            && let Some(count) = in_flight.get_mut(&self.peer)
        {
            *count = count.saturating_sub(1);
            if *count == 0 {
                in_flight.remove(&self.peer);
            }
        }
        self.wake.notify_one();
    }
}

/// Wakes on a state change, an explicit nudge, or the earliest due retry,
/// never on a fixed tick, so an idle or unreachable set of peers costs no CPU.
async fn run_scheduler(
    manager: Weak<ConnectionManager>,
    mut states: watch::Receiver<HashMap<DeviceId, PeerConnectionState>>,
    wake: Arc<Notify>,
) {
    let mut previous = states.borrow_and_update().clone();
    loop {
        let (next, now) = {
            let Some(manager) = manager.upgrade() else {
                return;
            };
            if manager.closed.load(Ordering::Acquire) {
                return;
            }
            let current = states.borrow_and_update().clone();
            let now = manager.clock.now_ms();
            let next = manager.schedule(&previous, &current, now);
            previous = current;
            (next, now)
        };
        let sleep = async {
            match next {
                Some(at) => tokio::time::sleep(Duration::from_millis(at.saturating_sub(now))).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            changed = states.changed() => if changed.is_err() { return; },
            () = wake.notified() => {}
            () = sleep => {}
        }
    }
}

/// A session exists or is being set up, so no new attempt should start.
fn is_live(state: &PeerConnectionState) -> bool {
    matches!(
        state,
        PeerConnectionState::Connecting { .. }
            | PeerConnectionState::Authenticating { .. }
            | PeerConnectionState::Connected
            | PeerConnectionState::Syncing
            | PeerConnectionState::Synced
    )
}

/// A session is authenticated and reported by the sync bridge.
fn is_established(state: &PeerConnectionState) -> bool {
    matches!(
        state,
        PeerConnectionState::Connected | PeerConnectionState::Syncing | PeerConnectionState::Synced
    )
}

fn log_transition(peer: DeviceId, state: &PeerConnectionState) {
    tracing::info!(
        event = "peer_connection_state",
        device_id = %peer,
        state = connection_state_name(state),
        "peer connection state transition"
    );
}

fn connection_state_name(state: &PeerConnectionState) -> &'static str {
    match state {
        PeerConnectionState::Disconnected => "offline",
        PeerConnectionState::Connecting { .. } | PeerConnectionState::Authenticating { .. } => {
            "searching"
        }
        PeerConnectionState::Connected => "connected",
        PeerConnectionState::Syncing => "syncing",
        PeerConnectionState::Synced => "synced",
        PeerConnectionState::Failed(_) => "error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn endpoint(source: EndpointSource, port: u16) -> NetworkEndpoint {
        NetworkEndpoint {
            address: ([10, 0, 0, 1], port).into(),
            source,
            observed_at_ms: 5,
            expires_at_ms: 100,
            interface_scope: None,
            last_success_ms: None,
            failures: 0,
            retry_after_ms: None,
        }
    }

    #[test]
    fn ranking_is_lan_first_expiring_and_success_aware() {
        let mut old_lan = endpoint(EndpointSource::Lan, 1);
        old_lan.last_success_ms = Some(10);
        let fresh_lan = endpoint(EndpointSource::Lan, 2);
        let tailscale = endpoint(EndpointSource::Tailscale, 3);
        let mut expired = endpoint(EndpointSource::Lan, 4);
        expired.expires_at_ms = 9;
        let ranked = rank_endpoints(&[tailscale, fresh_lan, expired, old_lan], 10);
        assert_eq!(
            ranked
                .iter()
                .map(|item| item.address.port())
                .collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
    }

    #[test]
    fn unreachable_addresses_never_rank_and_all_unreachable_yields_none() {
        let mut loopback = endpoint(EndpointSource::Lan, 1);
        loopback.address = ([127, 0, 0, 1], 1).into();
        loopback.last_success_ms = Some(9);
        let mut ipv6 = endpoint(EndpointSource::Lan, 2);
        ipv6.address = "[fdaa::1]:2".parse().unwrap();
        let routable = endpoint(EndpointSource::Lan, 3);
        let ranked = rank_endpoints(&[loopback.clone(), ipv6.clone(), routable], 10);
        assert_eq!(
            ranked
                .iter()
                .map(|item| item.address.port())
                .collect::<Vec<_>>(),
            vec![3],
            "a recently successful loopback must not outrank the routable address"
        );
        assert!(rank_endpoints(&[loopback.clone(), ipv6], 10).is_empty());
        // The same loopback endpoint is reachable when the local socket is on loopback.
        let policy = AddressPolicy::for_bind([127, 0, 0, 1].into());
        assert_eq!(
            rank_endpoints_with_policy(&[loopback], &policy, 10).len(),
            1
        );
    }

    #[test]
    fn registry_upsert_accumulates_addresses_and_keeps_history() {
        let device = DeviceId::from_public_key(&[3; 32]);
        let mut registry = EndpointRegistry::default();
        let first = endpoint(EndpointSource::Lan, 1);
        let mut second = endpoint(EndpointSource::Lan, 2);
        second.address = ([192, 168, 0, 7], 2).into();
        registry.upsert(device, first.clone());
        registry.upsert(device, second.clone());
        assert_eq!(
            registry.ranked(device, 10).len(),
            2,
            "upsert must not replace"
        );
        registry
            .endpoint_mut(device, second.address)
            .unwrap()
            .record_failure(10, 10, 100);
        let mut refreshed = second.clone();
        refreshed.observed_at_ms = 11;
        refreshed.expires_at_ms = 200;
        registry.upsert(device, refreshed);
        let kept = registry.endpoint_mut(device, second.address).unwrap();
        assert_eq!(kept.failures, 1, "history survives a refresh");
        assert_eq!(kept.expires_at_ms, 200);
        // An observed successful connection ranks first on the next dial.
        let mut observed = endpoint(EndpointSource::Lan, 1);
        observed.address = ([192, 168, 0, 7], 2).into();
        observed.observed_at_ms = 12;
        observed.last_success_ms = Some(12);
        registry.upsert(device, observed);
        let ranked = registry.ranked(device, 12);
        assert_eq!(ranked[0].address, ([192, 168, 0, 7], 2).into());
        assert_eq!(ranked[0].failures, 0);
        // Expired siblings from the same source are dropped on the next upsert.
        let mut late = endpoint(EndpointSource::Lan, 9);
        late.address = ([192, 168, 0, 9], 9).into();
        late.observed_at_ms = 150;
        late.expires_at_ms = 300;
        registry.upsert(device, late);
        assert_eq!(registry.ranked(device, 150).len(), 2);
    }

    #[test]
    fn failure_backoff_is_bounded_and_excludes_route() {
        let mut route = endpoint(EndpointSource::Lan, 1);
        route.expires_at_ms = 1_000;
        for now in 0..20 {
            route.record_failure(now, 10, 100);
        }
        assert!(route.retry_after_ms.unwrap() <= 119);
        assert!(!route.is_eligible(50));
        route.record_success(120);
        assert!(route.is_eligible(120));
    }

    #[test]
    fn preferred_dialing_and_generation_winner_are_deterministic() {
        let low = DeviceId::from_public_key(&[1; 32]);
        let high = DeviceId::from_public_key(&[2; 32]);
        let (local, remote) = if low < high { (low, high) } else { (high, low) };
        assert!(is_preferred_initiator(local, remote));
        assert!(!is_preferred_initiator(remote, local));
        let older = SessionCandidate {
            direction: ConnectionDirection::Outbound,
            generation: 4,
        };
        let newer = SessionCandidate {
            direction: ConnectionDirection::Inbound,
            generation: 5,
        };
        assert_eq!(choose_session(local, remote, older, newer), older);
        let newest_preferred = SessionCandidate {
            direction: ConnectionDirection::Outbound,
            generation: 6,
        };
        assert_eq!(
            choose_session(local, remote, older, newest_preferred),
            newest_preferred
        );
    }

    // ---- Reconnect orchestration -------------------------------------------------

    use std::collections::HashSet;

    /// Milliseconds on Tokio's clock, so paused virtual time drives both the
    /// scheduler's sleeps and the timestamps it compares against.
    struct VirtualClock(tokio::time::Instant);

    impl Clock for VirtualClock {
        fn now_ms(&self) -> u64 {
            1_000 + u64::try_from(self.0.elapsed().as_millis()).unwrap()
        }
    }

    /// In-memory LAN: devices listen on addresses, some addresses swallow
    /// packets forever, and a successful dial reports an inbound session to
    /// the callee's manager the way the sync bridge does in the app.
    #[derive(Default)]
    struct FakeLan {
        listeners: Mutex<HashMap<SocketAddr, DeviceId>>,
        black_holes: Mutex<HashSet<SocketAddr>>,
        dials: Mutex<Vec<(DeviceId, SocketAddr, u64)>>,
        sessions: Mutex<HashSet<(DeviceId, DeviceId)>>,
        managers: Mutex<HashMap<DeviceId, Weak<ConnectionManager>>>,
        started: Mutex<Option<tokio::time::Instant>>,
    }

    impl FakeLan {
        fn dial_count(&self) -> usize {
            self.dials.lock().unwrap().len()
        }
        fn dial_times(&self) -> Vec<u64> {
            self.dials
                .lock()
                .unwrap()
                .iter()
                .map(|dial| dial.2)
                .collect()
        }
        fn dialed_addresses(&self) -> Vec<SocketAddr> {
            self.dials
                .lock()
                .unwrap()
                .iter()
                .map(|dial| dial.1)
                .collect()
        }
    }

    struct FakeConnector {
        local: DeviceId,
        lan: Arc<FakeLan>,
    }

    #[async_trait]
    impl PeerConnector for FakeConnector {
        async fn connect(
            &self,
            peer: DeviceId,
            endpoint: NetworkEndpoint,
        ) -> Result<u64, ConnectionFailure> {
            let at = self
                .lan
                .started
                .lock()
                .unwrap()
                .map_or(0, |started| started.elapsed().as_millis() as u64);
            self.lan
                .dials
                .lock()
                .unwrap()
                .push((self.local, endpoint.address, at));
            if self
                .lan
                .black_holes
                .lock()
                .unwrap()
                .contains(&endpoint.address)
            {
                std::future::pending::<()>().await;
            }
            if self.lan.listeners.lock().unwrap().get(&endpoint.address) != Some(&peer) {
                return Err(ConnectionFailure::Route("connection refused".into()));
            }
            let pair = if self.local < peer {
                (self.local, peer)
            } else {
                (peer, self.local)
            };
            self.lan.sessions.lock().unwrap().insert(pair);
            let callee = self.lan.managers.lock().unwrap().get(&peer).cloned();
            if let Some(callee) = callee.and_then(|weak| weak.upgrade()) {
                callee.set_state(self.local, PeerConnectionState::Connected);
            }
            Ok(1)
        }
    }

    fn devices() -> (DeviceId, DeviceId) {
        let one = DeviceId::from_public_key(&[1; 32]);
        let two = DeviceId::from_public_key(&[2; 32]);
        if one < two { (one, two) } else { (two, one) }
    }

    fn lan_endpoint(address: SocketAddr, now: u64, ttl: u64) -> NetworkEndpoint {
        NetworkEndpoint {
            address,
            source: EndpointSource::Lan,
            observed_at_ms: now,
            expires_at_ms: now + ttl,
            interface_scope: None,
            last_success_ms: None,
            failures: 0,
            retry_after_ms: None,
        }
    }

    struct Node {
        manager: Arc<ConnectionManager>,
        registry: Arc<Mutex<EndpointRegistry>>,
        clock: Arc<VirtualClock>,
    }

    impl Node {
        fn new(local: DeviceId, lan: &Arc<FakeLan>) -> Self {
            let clock = Arc::new(VirtualClock(tokio::time::Instant::now()));
            lan.started
                .lock()
                .unwrap()
                .get_or_insert_with(tokio::time::Instant::now);
            let registry = Arc::new(Mutex::new(EndpointRegistry::default()));
            let manager = ConnectionManager::with_timing(
                local,
                Arc::new(FakeConnector {
                    local,
                    lan: lan.clone(),
                }),
                registry.clone(),
                4,
                DialTiming::default(),
                clock.clone(),
            )
            .unwrap();
            lan.managers
                .lock()
                .unwrap()
                .insert(local, Arc::downgrade(&manager));
            Self {
                manager,
                registry,
                clock,
            }
        }
        fn now(&self) -> u64 {
            self.clock.now_ms()
        }
        fn learn(&self, peer: DeviceId, address: SocketAddr, ttl: u64) {
            let now = self.now();
            self.registry
                .lock()
                .unwrap()
                .upsert(peer, lan_endpoint(address, now, ttl));
            self.manager.request_connect(peer, now);
        }
        fn state(&self, peer: DeviceId) -> Option<PeerConnectionState> {
            self.manager.states().get(&peer).cloned()
        }
    }

    async fn advance(ms: u64) {
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }

    fn address(last: u8, port: u16) -> SocketAddr {
        ([192, 168, 1, last], port).into()
    }

    // Pins the reported bug: a discovered, trusted peer with no session was
    // recorded as an endpoint and never dialed, so paired devices sat at
    // Offline after the first session dropped. Also pins that a lost session
    // is retried on its own, which is the Wi-Fi-toggle recovery.
    #[tokio::test(start_paused = true)]
    async fn discovered_peer_without_session_is_dialed_and_redialed_after_loss() {
        let (local, remote) = devices();
        let lan = Arc::new(FakeLan::default());
        lan.listeners
            .lock()
            .unwrap()
            .insert(address(2, 7000), remote);
        let node = Node::new(local, &lan);
        node.learn(remote, address(2, 7000), 30_000);
        // A burst of resolutions for the same instance is one attempt.
        node.manager.request_connect(remote, node.now());
        advance(10).await;
        assert_eq!(lan.dial_count(), 1);
        assert_eq!(node.state(remote), Some(PeerConnectionState::Connected));

        // Re-resolution while the session is live starts nothing.
        node.learn(remote, address(2, 7000), 30_000);
        advance(10).await;
        assert_eq!(lan.dial_count(), 1);

        // The session drops: the scheduler redials after the minimum backoff
        // without waiting for mDNS to re-announce the peer.
        node.manager
            .set_state(remote, PeerConnectionState::Disconnected);
        advance(200).await;
        assert_eq!(lan.dial_count(), 1, "no redial before retry_min_ms");
        advance(100).await;
        assert_eq!(lan.dial_count(), 2);
        assert_eq!(node.state(remote), Some(PeerConnectionState::Connected));
    }

    // Pins "who dials": the preferred side dials at once; the other side waits,
    // then dials anyway, so a backgrounded preferred side cannot leave both
    // devices offline.
    #[tokio::test(start_paused = true)]
    async fn preferred_side_dials_at_once_and_non_preferred_after_delay() {
        let (low, high) = devices();
        let lan = Arc::new(FakeLan::default());
        lan.listeners.lock().unwrap().insert(address(1, 7000), low);
        lan.listeners.lock().unwrap().insert(address(2, 7000), high);

        let preferred = Node::new(low, &lan);
        preferred.learn(high, address(2, 7000), 30_000);
        advance(1).await;
        assert_eq!(lan.dial_count(), 1, "preferred initiator dials at once");

        let lan = Arc::new(FakeLan::default());
        lan.listeners.lock().unwrap().insert(address(1, 7000), low);
        let non_preferred = Node::new(high, &lan);
        non_preferred.learn(low, address(1, 7000), 30_000);
        advance(1_400).await;
        assert_eq!(lan.dial_count(), 0, "non-preferred side waits first");
        advance(200).await;
        assert_eq!(lan.dial_count(), 1, "then dials the absent preferred side");
        assert_eq!(
            non_preferred.state(low),
            Some(PeerConnectionState::Connected)
        );
    }

    // Pins duplicate avoidance: both sides learn each other at once, the
    // preferred one connects first, and the other stands down.
    #[tokio::test(start_paused = true)]
    async fn two_managers_learning_each_other_keep_one_session() {
        let (low, high) = devices();
        let lan = Arc::new(FakeLan::default());
        lan.listeners.lock().unwrap().insert(address(1, 7000), low);
        lan.listeners.lock().unwrap().insert(address(2, 7000), high);
        let a = Node::new(low, &lan);
        let b = Node::new(high, &lan);
        b.learn(low, address(1, 7000), 30_000);
        a.learn(high, address(2, 7000), 30_000);
        advance(3_000).await;
        assert_eq!(lan.dial_count(), 1);
        assert_eq!(lan.sessions.lock().unwrap().len(), 1);
        assert_eq!(a.state(high), Some(PeerConnectionState::Connected));
        assert_eq!(b.state(low), Some(PeerConnectionState::Connected));
    }

    // Pins bounded backoff: an unreachable peer is retried with growing gaps
    // up to the cap, never in a busy loop.
    #[tokio::test(start_paused = true)]
    async fn repeated_failures_back_off_from_min_to_max() {
        let (local, remote) = devices();
        let lan = Arc::new(FakeLan::default());
        let node = Node::new(local, &lan);
        node.learn(remote, address(2, 7000), 10 * 60_000);
        advance(3 * 60_000).await;
        let times = lan.dial_times();
        let gaps = times
            .windows(2)
            .map(|pair| pair[1] - pair[0])
            .collect::<Vec<_>>();
        assert!(gaps.len() >= 8, "kept retrying: {gaps:?}");
        assert!(gaps[0] >= 250, "first retry waits retry_min_ms: {gaps:?}");
        assert!(
            gaps.windows(2).all(|pair| pair[1] >= pair[0]),
            "gaps never shrink: {gaps:?}"
        );
        assert!(
            gaps.iter().all(|gap| *gap <= 30_000),
            "gaps are capped: {gaps:?}"
        );
        assert_eq!(*gaps.last().unwrap(), 30_000);
        assert_eq!(
            node.manager.sync_status(),
            SyncStatus::Searching,
            "an unreachable peer is still being searched for"
        );
    }

    // Pins the retry bound: once every endpoint has expired the peer holds no
    // timer, and a fresh discovery restarts dialing.
    #[tokio::test(start_paused = true)]
    async fn expired_endpoints_stop_retries_and_new_upsert_restarts_them() {
        let (local, remote) = devices();
        let lan = Arc::new(FakeLan::default());
        let node = Node::new(local, &lan);
        node.learn(remote, address(2, 7000), 5_000);
        advance(10_000).await;
        let after_expiry = lan.dial_count();
        assert!(after_expiry >= 2);
        advance(5 * 60_000).await;
        assert_eq!(lan.dial_count(), after_expiry, "no retries after expiry");

        lan.listeners
            .lock()
            .unwrap()
            .insert(address(2, 7001), remote);
        node.learn(remote, address(2, 7001), 30_000);
        advance(10).await;
        assert_eq!(lan.dial_count(), after_expiry + 1);
        assert_eq!(node.state(remote), Some(PeerConnectionState::Connected));
    }

    // Pins the Wi-Fi-toggle address change: the old address (previous lease)
    // still ranks first because it once succeeded, swallows packets, and must
    // fail within the dial timeout so the new address is tried in the same
    // attempt instead of after QUIC's idle timeout.
    #[tokio::test(start_paused = true)]
    async fn stale_address_times_out_and_next_endpoint_is_tried_in_same_attempt() {
        let (local, remote) = devices();
        let lan = Arc::new(FakeLan::default());
        lan.black_holes.lock().unwrap().insert(address(2, 7000));
        lan.listeners
            .lock()
            .unwrap()
            .insert(address(3, 7001), remote);
        let node = Node::new(local, &lan);
        let now = node.now();
        {
            let mut registry = node.registry.lock().unwrap();
            let mut stale = lan_endpoint(address(2, 7000), now, 120_000);
            stale.last_success_ms = Some(now);
            registry.upsert(remote, stale);
            registry.upsert(remote, lan_endpoint(address(3, 7001), now, 30_000));
        }
        node.manager.request_connect(remote, now);
        advance(4_900).await;
        assert_ne!(node.state(remote), Some(PeerConnectionState::Connected));
        advance(200).await;
        assert_eq!(node.state(remote), Some(PeerConnectionState::Connected));
        assert_eq!(
            lan.dialed_addresses(),
            vec![address(2, 7000), address(3, 7001)]
        );
        let registry = node.registry.lock().unwrap();
        assert_eq!(registry.endpoints[&remote][0].failures, 1);
        assert!(registry.endpoints[&remote][0].retry_after_ms.is_some());
    }

    // Pins that the pairing provisioning dial (an explicit `connect_manual`)
    // is not doubled by discovery or the scheduler while it runs.
    #[tokio::test(start_paused = true)]
    async fn explicit_dial_in_flight_blocks_automatic_attempts() {
        let (local, remote) = devices();
        let lan = Arc::new(FakeLan::default());
        lan.black_holes.lock().unwrap().insert(address(2, 7000));
        let node = Node::new(local, &lan);
        node.registry
            .lock()
            .unwrap()
            .upsert(remote, lan_endpoint(address(2, 7000), node.now(), 60_000));
        let manager = node.manager.clone();
        let now = node.now();
        let manual = tokio::spawn(async move { manager.connect_manual(remote, now).await });
        advance(10).await;
        node.manager.request_connect(remote, node.now());
        node.manager.reconnect_known_peers(node.now());
        advance(10).await;
        assert_eq!(lan.dial_count(), 1);
        assert!(manual.await.unwrap().is_err());
    }

    // Pins that suspending (Android background) stops automatic redials.
    #[tokio::test(start_paused = true)]
    async fn suspended_manager_does_not_redial() {
        let (local, remote) = devices();
        let lan = Arc::new(FakeLan::default());
        lan.listeners
            .lock()
            .unwrap()
            .insert(address(2, 7000), remote);
        let node = Node::new(local, &lan);
        node.learn(remote, address(2, 7000), 60_000);
        advance(10).await;
        node.manager.set_suspended(true);
        node.manager
            .set_state(remote, PeerConnectionState::Disconnected);
        node.manager.request_connect(remote, node.now());
        advance(10_000).await;
        assert_eq!(lan.dial_count(), 1);
        node.manager.set_suspended(false);
        node.manager.reconnect_known_peers(node.now());
        advance(10).await;
        assert_eq!(lan.dial_count(), 2);
    }

    // Pins the status chip: an unreachable phone reads as Searching, a
    // rejected key still reads as Error.
    #[test]
    fn aggregate_treats_route_failures_as_searching_and_trust_failures_as_error() {
        let (one, two) = devices();
        for failure in [
            ConnectionFailure::NoRoute,
            ConnectionFailure::Route("refused".into()),
            ConnectionFailure::Transport("closed".into()),
            ConnectionFailure::Stream("reset".into()),
        ] {
            let states = HashMap::from([(one, PeerConnectionState::Failed(failure))]);
            assert_eq!(aggregate_sync_status(&states), SyncStatus::Searching);
        }
        for failure in [
            ConnectionFailure::Trust("unknown".into()),
            ConnectionFailure::Tls("bad cert".into()),
        ] {
            let states = HashMap::from([
                (one, PeerConnectionState::Failed(failure)),
                (two, PeerConnectionState::Synced),
            ]);
            assert_eq!(aggregate_sync_status(&states), SyncStatus::Error);
        }
    }
}
