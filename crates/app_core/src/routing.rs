//! Device-oriented endpoint selection and bounded connection orchestration.

use std::{
    cmp::Reverse,
    collections::{BTreeMap, HashMap},
    net::SocketAddr,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use tokio::sync::{Semaphore, watch};

use crate::{discovery::AddressPolicy, identity::DeviceId};

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

#[must_use]
pub fn aggregate_sync_status(states: &HashMap<DeviceId, PeerConnectionState>) -> SyncStatus {
    if states.is_empty()
        || states
            .values()
            .all(|state| matches!(state, PeerConnectionState::Disconnected))
    {
        SyncStatus::Offline
    } else if states
        .values()
        .any(|state| matches!(state, PeerConnectionState::Failed(_)))
    {
        SyncStatus::Error
    } else if states.values().any(|state| {
        matches!(
            state,
            PeerConnectionState::Connecting { .. } | PeerConnectionState::Authenticating { .. }
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

pub struct ConnectionManager {
    local: DeviceId,
    connector: Arc<dyn PeerConnector>,
    registry: Arc<Mutex<EndpointRegistry>>,
    attempts: Arc<Semaphore>,
    states: watch::Sender<HashMap<DeviceId, PeerConnectionState>>,
    retry_min_ms: u64,
    retry_max_ms: u64,
}

impl ConnectionManager {
    pub fn new(
        local: DeviceId,
        connector: Arc<dyn PeerConnector>,
        registry: Arc<Mutex<EndpointRegistry>>,
        max_concurrent_attempts: usize,
    ) -> Result<Self, &'static str> {
        if max_concurrent_attempts == 0 {
            return Err("connection capacity must be greater than zero");
        }
        let (states, _) = watch::channel(HashMap::new());
        Ok(Self {
            local,
            connector,
            registry,
            attempts: Arc::new(Semaphore::new(max_concurrent_attempts)),
            states,
            retry_min_ms: 250,
            retry_max_ms: 30_000,
        })
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
        tracing::info!(
            event = "peer_connection_state",
            device_id = %peer,
            state = connection_state_name(&state),
            "peer connection state transition"
        );
        self.states.send_modify(|states| {
            states.insert(peer, state);
        });
    }

    #[must_use]
    pub fn states(&self) -> HashMap<DeviceId, PeerConnectionState> {
        self.states.borrow().clone()
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

    pub async fn connect_manual(
        &self,
        peer: DeviceId,
        now_ms: u64,
    ) -> Result<u64, ConnectionFailure> {
        let _permit = self
            .attempts
            .acquire()
            .await
            .map_err(|_| ConnectionFailure::Transport("connection manager closed".into()))?;
        let endpoints = self
            .registry
            .lock()
            .map_err(|_| ConnectionFailure::Transport("endpoint registry lock poisoned".into()))?
            .ranked(peer, now_ms);
        if endpoints.is_empty() {
            self.set_state(
                peer,
                PeerConnectionState::Failed(ConnectionFailure::NoRoute),
            );
            return Err(ConnectionFailure::NoRoute);
        }
        let mut last = ConnectionFailure::NoRoute;
        for endpoint in endpoints {
            self.set_state(
                peer,
                PeerConnectionState::Connecting {
                    endpoint: endpoint.address,
                },
            );
            self.set_state(
                peer,
                PeerConnectionState::Authenticating {
                    endpoint: endpoint.address,
                },
            );
            match self.connector.connect(peer, endpoint.clone()).await {
                Ok(generation) => {
                    if let Ok(mut registry) = self.registry.lock()
                        && let Some(route) = registry.endpoint_mut(peer, endpoint.address)
                    {
                        route.record_success(now_ms);
                    }
                    self.set_state(peer, PeerConnectionState::Connected);
                    return Ok(generation);
                }
                Err(error) => {
                    if let Ok(mut registry) = self.registry.lock()
                        && let Some(route) = registry.endpoint_mut(peer, endpoint.address)
                    {
                        route.record_failure(now_ms, self.retry_min_ms, self.retry_max_ms);
                    }
                    last = error;
                }
            }
        }
        self.set_state(peer, PeerConnectionState::Failed(last.clone()));
        Err(last)
    }
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
}
