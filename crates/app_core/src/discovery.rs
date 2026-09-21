//! Provider-neutral, privacy-preserving LAN endpoint discovery.

use std::{
    collections::{BTreeMap, HashMap},
    fmt,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use async_trait::async_trait;
use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::identity::DeviceId;

pub const PAIRING_SERVICE_TYPE: &str = "_myapp-pair._udp.local.";
pub const DISCOVERY_PROTOCOL_VERSION: u16 = 1;
pub const DEFAULT_RECORD_TTL_MS: u64 = 30_000;
const SERVICE_DOMAIN: &[u8] = b"fi-mdns-service-v1";
const ROUTE_DOMAIN: &[u8] = b"fi-mdns-route-v1";

#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct PairingInstanceId([u8; 16]);

impl PairingInstanceId {
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(bytes)
    }
    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 16] {
        &self.0
    }
}

impl fmt::Debug for PairingInstanceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PairingInstanceId({})", hex::encode(self.0))
    }
}

impl fmt::Display for PairingInstanceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&hex::encode(self.0))
    }
}

#[derive(Clone, Eq, PartialEq, Zeroize, ZeroizeOnDrop)]
pub struct DiscoveryGroupSecret([u8; 32]);

impl DiscoveryGroupSecret {
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }
    #[must_use]
    pub const fn expose(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for DiscoveryGroupSecret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("DiscoveryGroupSecret([REDACTED])")
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum DiscoveryScope {
    Pairing,
    Group { epoch: u64, selector: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveryAdvertisement {
    pub scope: DiscoveryScope,
    pub instance_name: String,
    pub port: u16,
    pub properties: BTreeMap<String, String>,
    pub ttl_ms: u64,
}

impl DiscoveryAdvertisement {
    #[must_use]
    pub fn pairing(
        instance: PairingInstanceId,
        random_name: String,
        port: u16,
        ttl_ms: u64,
    ) -> Self {
        Self {
            scope: DiscoveryScope::Pairing,
            instance_name: random_name,
            port,
            properties: BTreeMap::from([
                ("v".into(), DISCOVERY_PROTOCOL_VERSION.to_string()),
                ("i".into(), instance.to_string()),
            ]),
            ttl_ms,
        }
    }

    #[must_use]
    pub fn group(
        selector: String,
        epoch: u64,
        route_token: String,
        random_name: String,
        port: u16,
        ttl_ms: u64,
    ) -> Self {
        Self {
            scope: DiscoveryScope::Group { epoch, selector },
            instance_name: random_name,
            port,
            properties: BTreeMap::from([
                ("v".into(), DISCOVERY_PROTOCOL_VERSION.to_string()),
                ("e".into(), epoch.to_string()),
                ("r".into(), route_token),
            ]),
            ttl_ms,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveredEndpoint {
    pub scope: DiscoveryScope,
    pub instance_name: String,
    pub address: SocketAddr,
    pub properties: BTreeMap<String, String>,
    pub expires_at_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DiscoveryEvent {
    Upsert(DiscoveredEndpoint),
    Expired {
        scope: DiscoveryScope,
        instance_name: String,
    },
}

#[derive(Clone, Debug, thiserror::Error, Eq, PartialEq)]
pub enum DiscoveryError {
    #[error("discovery scope is already active")]
    AlreadyActive,
    #[error("discovery scope is inactive")]
    Inactive,
    #[error("invalid discovery record: {0}")]
    InvalidRecord(&'static str),
    #[error("discovery provider failed: {0}")]
    Provider(String),
    #[error("no peer-routable address to advertise")]
    NoRoutableAddress,
}

/// Interface-name prefixes that denote a host-local bridge or tunnel rather than a
/// LAN segment a remote peer can reach. Matched case-insensitively as prefixes.
const HOST_LOCAL_INTERFACE_MARKERS: &[&str] = &[
    "podman",
    "docker",
    "br-",
    "veth",
    "virbr",
    "cni",
    "flannel",
    "kube",
    "lxc",
    "lxd",
    "vmnet",
    "vnet",
    "tailscale",
    "ts0",
    "tun",
    "tap",
    "wg",
    "zt",
    "dummy",
    "bridge",
    "nerdctl",
    "containerd",
];

/// Whether an interface name denotes loopback or a host-local virtual bridge.
#[must_use]
pub fn is_host_local_interface(name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    lowered == "lo"
        || lowered.starts_with("lo:")
        || HOST_LOCAL_INTERFACE_MARKERS
            .iter()
            .any(|marker| lowered.starts_with(marker))
}

/// Decides which addresses are worth advertising and which peer addresses are
/// worth dialing, given where the local transport is bound.
///
/// Bound to an unspecified or LAN address, loopback peers are not dialable across
/// machines and are rejected. Bound to loopback (single-host tests), only loopback
/// peers are reachable. The address family follows the bind address: an IPv4-only
/// socket cannot dial IPv6, and an IPv6 link-local address cannot be dialed at all
/// because `SocketAddr` carries no scope id.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AddressPolicy {
    local_bind: IpAddr,
}

impl Default for AddressPolicy {
    fn default() -> Self {
        Self::for_bind(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
    }
}

impl AddressPolicy {
    #[must_use]
    pub const fn for_bind(local_bind: IpAddr) -> Self {
        Self { local_bind }
    }

    #[must_use]
    pub const fn local_bind(&self) -> IpAddr {
        self.local_bind
    }

    /// Receive side: may a peer at `address` be dialed from the local socket?
    #[must_use]
    pub fn admits_peer_address(&self, address: IpAddr) -> bool {
        if self.local_bind.is_ipv4() && address.is_ipv6() {
            return false;
        }
        if self.local_bind.is_loopback() {
            return address.is_loopback();
        }
        match address {
            IpAddr::V4(value) => {
                !value.is_unspecified()
                    && !value.is_broadcast()
                    && !value.is_multicast()
                    && !value.is_loopback()
                    && (value.is_private() || value.is_link_local())
            }
            IpAddr::V6(value) => {
                !value.is_unspecified()
                    && !value.is_multicast()
                    && !value.is_loopback()
                    && value.is_unique_local()
            }
        }
    }

    /// Advertise side: should `address` on interface `name` be published?
    #[must_use]
    pub fn advertises_interface(&self, name: &str, address: IpAddr, point_to_point: bool) -> bool {
        !point_to_point
            && self.admits_peer_address(address)
            && (address.is_loopback() || !is_host_local_interface(name))
    }

    /// Deterministic preference among admitted addresses; lower ranks first.
    #[must_use]
    pub fn rank(address: IpAddr) -> u8 {
        match address {
            IpAddr::V4(value) if value.is_private() => 0,
            IpAddr::V4(value) if value.is_link_local() => 1,
            IpAddr::V6(value) if value.is_unique_local() => 2,
            value if value.is_loopback() => 3,
            _ => 4,
        }
    }

    /// The endpoint to dial among several admitted addresses of one peer,
    /// independent of the order they were observed in.
    #[must_use]
    pub fn select(addresses: impl IntoIterator<Item = SocketAddr>) -> Option<SocketAddr> {
        addresses
            .into_iter()
            .min_by_key(|address| (Self::rank(address.ip()), *address))
    }

    /// Addresses this host would advertise right now, from the kernel's view.
    #[must_use]
    pub fn local_advertisable_addresses(&self) -> Vec<IpAddr> {
        self.advertisable_addresses(
            if_addrs::get_if_addrs()
                .unwrap_or_default()
                .into_iter()
                .map(|interface| {
                    let address = interface.ip();
                    (interface.name, address, interface.is_p2p)
                }),
        )
    }

    /// Which of `(name, address, point_to_point)` this policy would advertise.
    #[must_use]
    pub fn advertisable_addresses(
        &self,
        interfaces: impl IntoIterator<Item = (String, IpAddr, bool)>,
    ) -> Vec<IpAddr> {
        interfaces
            .into_iter()
            .filter(|(name, address, point_to_point)| {
                self.advertises_interface(name, *address, *point_to_point)
            })
            .map(|(_, address, _)| address)
            .collect()
    }
}

#[async_trait]
pub trait DiscoveryProvider: Send + Sync + 'static {
    async fn start(&self, advertisement: DiscoveryAdvertisement) -> Result<(), DiscoveryError>;
    async fn start_browse(&self, scope: DiscoveryScope) -> Result<(), DiscoveryError>;
    async fn stop(&self, scope: &DiscoveryScope) -> Result<(), DiscoveryError>;
    fn subscribe(&self) -> broadcast::Receiver<DiscoveryEvent>;
}

pub trait Clock: Send + Sync + 'static {
    fn now_ms(&self) -> u64;
}

#[derive(Debug, Default)]
pub struct ManualClock(std::sync::atomic::AtomicU64);

impl ManualClock {
    #[must_use]
    pub const fn new(now_ms: u64) -> Self {
        Self(std::sync::atomic::AtomicU64::new(now_ms))
    }
    pub fn advance(&self, delta_ms: u64) {
        self.0
            .fetch_add(delta_ms, std::sync::atomic::Ordering::AcqRel);
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.0.load(std::sync::atomic::Ordering::Acquire)
    }
}

/// Deterministic provider used by protocol tests and platform adapters.
pub struct FakeDiscoveryProvider {
    active: Mutex<HashMap<DiscoveryScope, DiscoveryAdvertisement>>,
    browsing: Mutex<std::collections::HashSet<DiscoveryScope>>,
    events: broadcast::Sender<DiscoveryEvent>,
    clock: Arc<dyn Clock>,
}

struct MdnsActive {
    service_type: String,
    fullname: Option<String>,
    task: JoinHandle<()>,
}

/// DNS-SD adapter. Dynamic group service types are kept below Android's
/// 15-byte service-label limit; the provider boundary permits an exact-owner
/// query implementation if a platform daemon is stricter.
pub struct MdnsDiscovery {
    daemon: mdns_sd::ServiceDaemon,
    policy: AddressPolicy,
    active: Mutex<HashMap<DiscoveryScope, MdnsActive>>,
    events: broadcast::Sender<DiscoveryEvent>,
}

impl fmt::Debug for MdnsDiscovery {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MdnsDiscovery").finish_non_exhaustive()
    }
}

impl MdnsDiscovery {
    /// Advertises as if the transport were bound to `0.0.0.0`; see [`AddressPolicy`].
    pub fn new() -> Result<Self, DiscoveryError> {
        Self::with_policy(AddressPolicy::default())
    }

    pub fn with_policy(policy: AddressPolicy) -> Result<Self, DiscoveryError> {
        let daemon = mdns_sd::ServiceDaemon::new()
            .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        let (events, _) = broadcast::channel(128);
        Ok(Self {
            daemon,
            policy,
            active: Mutex::new(HashMap::new()),
            events,
        })
    }

    #[must_use]
    pub const fn policy(&self) -> AddressPolicy {
        self.policy
    }

    fn service_type(scope: &DiscoveryScope) -> &str {
        match scope {
            DiscoveryScope::Pairing => PAIRING_SERVICE_TYPE,
            DiscoveryScope::Group { selector, .. } => selector,
        }
    }
}

#[async_trait]
impl DiscoveryProvider for MdnsDiscovery {
    async fn start(&self, advertisement: DiscoveryAdvertisement) -> Result<(), DiscoveryError> {
        validate_advertisement(&advertisement)?;
        if self
            .active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .contains_key(&advertisement.scope)
        {
            return Err(DiscoveryError::AlreadyActive);
        }
        let service_type = Self::service_type(&advertisement.scope).to_owned();
        let hostname = format!("{}.local.", advertisement.instance_name);
        let properties: Vec<(&str, &str)> = advertisement
            .properties
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect();
        let mut info = mdns_sd::ServiceInfo::new(
            &service_type,
            &advertisement.instance_name,
            &hostname,
            "",
            advertisement.port,
            properties.as_slice(),
        )
        .map_err(|error| DiscoveryError::Provider(error.to_string()))?
        .enable_addr_auto();
        // Only peer-routable interfaces feed the auto-detected address set, now and
        // on every IP re-check the daemon performs.
        let policy = self.policy;
        info.set_interfaces(vec![mdns_sd::IfKind::Predicate(mdns_sd::IfPredicate::new(
            move |interface| {
                policy.advertises_interface(&interface.name, interface.ip(), interface.is_p2p())
            },
        ))]);
        let advertisable = policy.local_advertisable_addresses();
        if advertisable.is_empty() {
            tracing::warn!(
                event = "discovery_no_routable_address",
                scope = ?advertisement.scope,
                "no peer-routable address to advertise; device is undiscoverable until one appears"
            );
            // Pairing is user-initiated: surface it. Group discovery runs for the
            // process lifetime and picks addresses up when they appear.
            if advertisement.scope == DiscoveryScope::Pairing {
                return Err(DiscoveryError::NoRoutableAddress);
            }
        } else {
            tracing::info!(
                event = "discovery_advertise",
                scope = ?advertisement.scope,
                addresses = ?advertisable,
                port = advertisement.port,
                "advertising peer-routable addresses"
            );
        }
        let fullname = info.get_fullname().to_owned();
        let receiver = self
            .daemon
            .browse(&service_type)
            .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        self.daemon
            .register(info)
            .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        let events = self.events.clone();
        let scope = advertisement.scope.clone();
        let ttl_ms = advertisement.ttl_ms;
        let service_suffix = format!(".{service_type}");
        let task = tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                match event {
                    mdns_sd::ServiceEvent::ServiceResolved(info) => {
                        let properties: BTreeMap<String, String> = info
                            .get_properties()
                            .iter()
                            .map(|property| {
                                (property.key().to_owned(), property.val_str().to_owned())
                            })
                            .collect();
                        let expires_at_ms = system_now_ms().saturating_add(ttl_ms);
                        for address in info.get_addresses() {
                            let _ = events.send(DiscoveryEvent::Upsert(DiscoveredEndpoint {
                                scope: scope.clone(),
                                instance_name: info
                                    .get_fullname()
                                    .strip_suffix(&service_suffix)
                                    .unwrap_or(info.get_fullname())
                                    .to_owned(),
                                address: SocketAddr::new(address.to_ip_addr(), info.get_port()),
                                properties: properties.clone(),
                                expires_at_ms,
                            }));
                        }
                    }
                    mdns_sd::ServiceEvent::ServiceRemoved(_, fullname) => {
                        let _ = events.send(DiscoveryEvent::Expired {
                            scope: scope.clone(),
                            instance_name: fullname
                                .strip_suffix(&service_suffix)
                                .unwrap_or(&fullname)
                                .to_owned(),
                        });
                    }
                    _ => {}
                }
            }
        });
        self.active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .insert(
                advertisement.scope,
                MdnsActive {
                    service_type,
                    fullname: Some(fullname),
                    task,
                },
            );
        Ok(())
    }

    async fn start_browse(&self, scope: DiscoveryScope) -> Result<(), DiscoveryError> {
        if self
            .active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .contains_key(&scope)
        {
            return Err(DiscoveryError::AlreadyActive);
        }
        let service_type = Self::service_type(&scope).to_owned();
        let receiver = self
            .daemon
            .browse(&service_type)
            .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        let events = self.events.clone();
        let event_scope = scope.clone();
        let service_suffix = format!(".{service_type}");
        let task = tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                match event {
                    mdns_sd::ServiceEvent::ServiceResolved(info) => {
                        let properties: BTreeMap<String, String> = info
                            .get_properties()
                            .iter()
                            .map(|property| {
                                (property.key().to_owned(), property.val_str().to_owned())
                            })
                            .collect();
                        for address in info.get_addresses() {
                            let _ = events.send(DiscoveryEvent::Upsert(DiscoveredEndpoint {
                                scope: event_scope.clone(),
                                instance_name: info
                                    .get_fullname()
                                    .strip_suffix(&service_suffix)
                                    .unwrap_or(info.get_fullname())
                                    .to_owned(),
                                address: SocketAddr::new(address.to_ip_addr(), info.get_port()),
                                properties: properties.clone(),
                                expires_at_ms: system_now_ms()
                                    .saturating_add(DEFAULT_RECORD_TTL_MS),
                            }));
                        }
                    }
                    mdns_sd::ServiceEvent::ServiceRemoved(_, fullname) => {
                        let _ = events.send(DiscoveryEvent::Expired {
                            scope: event_scope.clone(),
                            instance_name: fullname
                                .strip_suffix(&service_suffix)
                                .unwrap_or(&fullname)
                                .to_owned(),
                        });
                    }
                    _ => {}
                }
            }
        });
        self.active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .insert(
                scope,
                MdnsActive {
                    service_type,
                    fullname: None,
                    task,
                },
            );
        Ok(())
    }

    async fn stop(&self, scope: &DiscoveryScope) -> Result<(), DiscoveryError> {
        let active = self
            .active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .remove(scope)
            .ok_or(DiscoveryError::Inactive)?;
        active.task.abort();
        self.daemon
            .stop_browse(&active.service_type)
            .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        if let Some(fullname) = active.fullname {
            self.daemon
                .unregister(&fullname)
                .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        }
        Ok(())
    }

    fn subscribe(&self) -> broadcast::Receiver<DiscoveryEvent> {
        self.events.subscribe()
    }
}

impl Drop for MdnsDiscovery {
    fn drop(&mut self) {
        for (_, active) in self
            .active
            .get_mut()
            .expect("discovery lock poisoned")
            .drain()
        {
            active.task.abort();
            let _ = self.daemon.stop_browse(&active.service_type);
            if let Some(fullname) = active.fullname {
                let _ = self.daemon.unregister(&fullname);
            }
        }
        let _ = self.daemon.shutdown();
    }
}

fn system_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

impl fmt::Debug for FakeDiscoveryProvider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FakeDiscoveryProvider")
            .field("active", &self.advertisements())
            .finish_non_exhaustive()
    }
}

impl FakeDiscoveryProvider {
    #[must_use]
    pub fn new(clock: Arc<dyn Clock>) -> Self {
        let (events, _) = broadcast::channel(128);
        Self {
            active: Mutex::new(HashMap::new()),
            browsing: Mutex::new(std::collections::HashSet::new()),
            events,
            clock,
        }
    }
    #[must_use]
    pub fn advertisements(&self) -> Vec<DiscoveryAdvertisement> {
        self.active
            .lock()
            .expect("discovery lock poisoned")
            .values()
            .cloned()
            .collect()
    }
    #[must_use]
    pub fn browsing_scopes(&self) -> Vec<DiscoveryScope> {
        self.browsing
            .lock()
            .expect("discovery lock poisoned")
            .iter()
            .cloned()
            .collect()
    }
    pub fn resolve(
        &self,
        advertisement: &DiscoveryAdvertisement,
        ip: IpAddr,
    ) -> Result<(), DiscoveryError> {
        validate_advertisement(advertisement)?;
        let endpoint = DiscoveredEndpoint {
            scope: advertisement.scope.clone(),
            instance_name: advertisement.instance_name.clone(),
            address: SocketAddr::new(ip, advertisement.port),
            properties: advertisement.properties.clone(),
            expires_at_ms: self.clock.now_ms().saturating_add(advertisement.ttl_ms),
        };
        let _ = self.events.send(DiscoveryEvent::Upsert(endpoint));
        Ok(())
    }
    pub fn expire(&self, scope: DiscoveryScope, instance_name: String) {
        let _ = self.events.send(DiscoveryEvent::Expired {
            scope,
            instance_name,
        });
    }
}

#[async_trait]
impl DiscoveryProvider for FakeDiscoveryProvider {
    async fn start(&self, advertisement: DiscoveryAdvertisement) -> Result<(), DiscoveryError> {
        validate_advertisement(&advertisement)?;
        let mut active = self
            .active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?;
        if active
            .insert(advertisement.scope.clone(), advertisement)
            .is_some()
        {
            return Err(DiscoveryError::AlreadyActive);
        }
        Ok(())
    }
    async fn start_browse(&self, scope: DiscoveryScope) -> Result<(), DiscoveryError> {
        if !matches!(scope, DiscoveryScope::Group { .. }) {
            return Err(DiscoveryError::InvalidRecord(
                "pairing browse requires advertisement",
            ));
        }
        if !self
            .browsing
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .insert(scope)
        {
            return Err(DiscoveryError::AlreadyActive);
        }
        Ok(())
    }
    async fn stop(&self, scope: &DiscoveryScope) -> Result<(), DiscoveryError> {
        let advertised = self
            .active
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .remove(scope)
            .is_some();
        let browsed = self
            .browsing
            .lock()
            .map_err(|_| DiscoveryError::Provider("lock poisoned".into()))?
            .remove(scope);
        if advertised || browsed {
            Ok(())
        } else {
            Err(DiscoveryError::Inactive)
        }
    }
    fn subscribe(&self) -> broadcast::Receiver<DiscoveryEvent> {
        self.events.subscribe()
    }
}

pub fn validate_advertisement(value: &DiscoveryAdvertisement) -> Result<(), DiscoveryError> {
    if value.port == 0
        || value.ttl_ms == 0
        || value.instance_name.is_empty()
        || value.instance_name.len() > 63
    {
        return Err(DiscoveryError::InvalidRecord(
            "invalid instance, port, or TTL",
        ));
    }
    let expected: &[&str] = match value.scope {
        DiscoveryScope::Pairing => &["i", "v"],
        DiscoveryScope::Group { .. } => &["e", "r", "v"],
    };
    if value.properties.len() != expected.len()
        || !expected
            .iter()
            .all(|key| value.properties.contains_key(*key))
    {
        return Err(DiscoveryError::InvalidRecord(
            "unexpected or missing property",
        ));
    }
    if value
        .properties
        .get("v")
        .and_then(|version| version.parse::<u16>().ok())
        != Some(DISCOVERY_PROTOCOL_VERSION)
    {
        return Err(DiscoveryError::InvalidRecord("unsupported version"));
    }
    match &value.scope {
        DiscoveryScope::Pairing => {
            let instance = value.properties.get("i").expect("validated property");
            if instance.len() != 32
                || !instance
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            {
                return Err(DiscoveryError::InvalidRecord("invalid pairing instance"));
            }
        }
        DiscoveryScope::Group { epoch, selector } => {
            if value
                .properties
                .get("e")
                .and_then(|value| value.parse::<u64>().ok())
                != Some(*epoch)
                || !selector.starts_with("_fi-")
                || !selector.ends_with("._udp.local.")
                || value
                    .properties
                    .get("r")
                    .is_none_or(|route| route.len() != 26)
            {
                return Err(DiscoveryError::InvalidRecord("invalid group record"));
            }
        }
    }
    Ok(())
}

type HmacSha256 = Hmac<Sha256>;

fn token(
    secret: &DiscoveryGroupSecret,
    domain: &[u8],
    epoch: u64,
    suffix: &[u8],
    bytes: usize,
) -> String {
    let mut mac = HmacSha256::new_from_slice(secret.expose()).expect("HMAC accepts any key length");
    mac.update(domain);
    mac.update(&epoch.to_be_bytes());
    mac.update(suffix);
    let output = mac.finalize().into_bytes();
    BASE32_NOPAD.encode(&output[..bytes]).to_ascii_lowercase()
}

#[must_use]
pub fn group_service_selector(secret: &DiscoveryGroupSecret, epoch: u64) -> String {
    format!(
        "_fi-{}._udp.local.",
        token(secret, SERVICE_DOMAIN, epoch, &[], 6)
    )
}

#[must_use]
pub fn group_routing_token(secret: &DiscoveryGroupSecret, epoch: u64, device: DeviceId) -> String {
    token(secret, ROUTE_DOMAIN, epoch, device.as_bytes(), 16)
}

#[must_use]
pub fn match_group_endpoint(
    endpoint: &DiscoveredEndpoint,
    secret: &DiscoveryGroupSecret,
    policy: &AddressPolicy,
    trusted: impl IntoIterator<Item = DeviceId>,
) -> Option<(DeviceId, SocketAddr, u64)> {
    if !policy.admits_peer_address(endpoint.address.ip()) || endpoint.expires_at_ms == 0 {
        return None;
    }
    let DiscoveryScope::Group { epoch, selector } = &endpoint.scope else {
        return None;
    };
    if *selector != group_service_selector(secret, *epoch) {
        return None;
    }
    let advertised = endpoint.properties.get("r")?;
    trusted.into_iter().find_map(|device| {
        (group_routing_token(secret, *epoch, device) == *advertised).then_some((
            device,
            endpoint.address,
            endpoint.expires_at_ms,
        ))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn pairing_records_are_minimal_and_expiring() {
        let clock = Arc::new(ManualClock::new(100));
        let provider = FakeDiscoveryProvider::new(clock.clone());
        assert!(provider.advertisements().is_empty());
        let record = DiscoveryAdvertisement::pairing(
            PairingInstanceId::from_bytes([7; 16]),
            "random-window".into(),
            4433,
            500,
        );
        provider.start(record.clone()).await.unwrap();
        let mut events = provider.subscribe();
        provider
            .resolve(&record, "127.0.0.1".parse().unwrap())
            .unwrap();
        let DiscoveryEvent::Upsert(found) = events.recv().await.unwrap() else {
            panic!()
        };
        assert_eq!(
            found
                .properties
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["i", "v"]
        );
        assert_eq!(found.expires_at_ms, 600);
        provider.stop(&DiscoveryScope::Pairing).await.unwrap();
        assert!(provider.advertisements().is_empty());
    }

    #[test]
    fn groups_are_isolated_and_unknown_routes_are_ignored() {
        let a = DiscoveryGroupSecret::from_bytes([1; 32]);
        let b = DiscoveryGroupSecret::from_bytes([2; 32]);
        assert_ne!(group_service_selector(&a, 1), group_service_selector(&b, 1));
        let key = crate::identity::PrivateDeviceKey::from_seed(&[9; 32])
            .unwrap()
            .public_key();
        let device = DeviceId::from_public_key(key.as_bytes());
        let endpoint = DiscoveredEndpoint {
            scope: DiscoveryScope::Group {
                epoch: 1,
                selector: group_service_selector(&a, 1),
            },
            instance_name: "opaque".into(),
            address: "192.168.1.20:42".parse().unwrap(),
            properties: BTreeMap::from([
                ("v".into(), "1".into()),
                ("e".into(), "1".into()),
                ("r".into(), group_routing_token(&a, 1, device)),
            ]),
            expires_at_ms: 10,
        };
        let policy = AddressPolicy::default();
        assert!(match_group_endpoint(&endpoint, &a, &policy, []).is_none());
        assert_eq!(
            match_group_endpoint(&endpoint, &a, &policy, [device])
                .unwrap()
                .0,
            device
        );
        assert!(match_group_endpoint(&endpoint, &b, &policy, [device]).is_none());
        // A remote peer advertising loopback is never dialable across machines.
        let loopback = DiscoveredEndpoint {
            address: "127.0.0.1:42".parse().unwrap(),
            ..endpoint.clone()
        };
        assert!(match_group_endpoint(&loopback, &a, &policy, [device]).is_none());
        assert!(
            match_group_endpoint(
                &loopback,
                &a,
                &AddressPolicy::for_bind("127.0.0.1".parse().unwrap()),
                [device]
            )
            .is_some()
        );
        let service_type = group_service_selector(&a, 1);
        let route = group_routing_token(&a, 1, device);
        assert!(
            mdns_sd::ServiceInfo::new(
                &service_type,
                "opaque",
                "opaque.local.",
                "127.0.0.1",
                42,
                &[("v", "1"), ("e", "1"), ("r", route.as_str())][..],
            )
            .is_ok()
        );
    }

    #[test]
    fn address_policy_admits_only_peer_routable_addresses() {
        let policy = AddressPolicy::default();
        let admitted = |ip: &str| policy.admits_peer_address(ip.parse().unwrap());
        assert!(admitted("192.168.0.104"));
        assert!(
            admitted("10.88.0.1"),
            "address alone cannot tell a bridge from a LAN"
        );
        assert!(admitted("169.254.10.2"));
        assert!(!admitted("127.0.0.1"));
        assert!(!admitted("0.0.0.0"));
        assert!(!admitted("224.0.0.251"));
        assert!(!admitted("8.8.8.8"));
        // IPv4-only bind: no IPv6 at all.
        assert!(!admitted("fdaa:bbcc:ddee::1"));
        assert!(!admitted("fe80::1"));
        let dual = AddressPolicy::for_bind("::".parse().unwrap());
        assert!(dual.admits_peer_address("fdaa:bbcc:ddee::1".parse().unwrap()));
        assert!(
            !dual.admits_peer_address("fe80::1".parse().unwrap()),
            "link-local needs a scope id that SocketAddr cannot carry"
        );
        assert!(!dual.admits_peer_address("::1".parse().unwrap()));
        assert!(dual.admits_peer_address("192.168.0.104".parse().unwrap()));
        let loopback = AddressPolicy::for_bind("127.0.0.1".parse().unwrap());
        assert!(loopback.admits_peer_address("127.0.0.1".parse().unwrap()));
        assert!(!loopback.admits_peer_address("192.168.0.104".parse().unwrap()));
    }

    #[test]
    fn address_policy_advertises_routable_interfaces_only() {
        let policy = AddressPolicy::default();
        let advertises = |name: &str, ip: &str, p2p: bool| {
            policy.advertises_interface(name, ip.parse().unwrap(), p2p)
        };
        assert!(advertises("wlan0", "192.168.0.104", false));
        assert!(advertises("eth0", "10.0.0.5", false));
        assert!(!advertises("lo", "127.0.0.1", false));
        assert!(!advertises("podman0", "10.88.0.1", false));
        assert!(!advertises("docker0", "172.17.0.1", false));
        assert!(!advertises("br-1a2b3c", "172.18.0.1", false));
        assert!(!advertises("virbr0", "192.168.122.1", false));
        assert!(!advertises("tailscale0", "100.64.0.1", false));
        assert!(!advertises("wg0", "10.200.0.2", false));
        assert!(!advertises("tun0", "10.8.0.2", true));
        assert!(!advertises("wlan0", "2800:200:f580::1", false));
        assert!(!advertises("wlan0", "fe80::1", false));
        let loopback = AddressPolicy::for_bind("127.0.0.1".parse().unwrap());
        assert!(loopback.advertises_interface("lo", "127.0.0.1".parse().unwrap(), false));
        assert!(!loopback.advertises_interface("wlan0", "192.168.0.104".parse().unwrap(), false));
    }

    #[test]
    fn host_without_routable_interface_advertises_no_substitute() {
        let policy = AddressPolicy::default();
        let host = |names: &[(&str, &str)]| {
            names
                .iter()
                .map(|(name, ip)| ((*name).to_owned(), ip.parse::<IpAddr>().unwrap(), false))
                .collect::<Vec<_>>()
        };
        // The development host: loopback, Wi-Fi and a container bridge.
        assert_eq!(
            policy.advertisable_addresses(host(&[
                ("lo", "127.0.0.1"),
                ("wlan0", "192.168.0.104"),
                ("podman0", "10.88.0.1"),
            ])),
            vec!["192.168.0.104".parse::<IpAddr>().unwrap()]
        );
        // Wi-Fi gone: nothing host-local is advertised in its place.
        assert!(
            policy
                .advertisable_addresses(host(&[("lo", "127.0.0.1"), ("podman0", "10.88.0.1")]))
                .is_empty()
        );
    }

    #[test]
    fn address_selection_is_deterministic_and_routability_ranked() {
        let a: SocketAddr = "192.168.0.104:1".parse().unwrap();
        let b: SocketAddr = "169.254.3.4:1".parse().unwrap();
        let c: SocketAddr = "10.88.0.1:1".parse().unwrap();
        assert_eq!(
            AddressPolicy::select([b, c, a]),
            Some(c),
            "numeric order within a rank"
        );
        assert_eq!(AddressPolicy::select([c, a, b]), Some(c));
        assert_eq!(AddressPolicy::select([b, a]), Some(a));
        assert_eq!(AddressPolicy::select([a, b]), Some(a));
        assert_eq!(AddressPolicy::select([]), None);
        let ula: SocketAddr = "[fdaa::1]:1".parse().unwrap();
        assert_eq!(AddressPolicy::select([ula, b]), Some(b));
    }

    #[tokio::test]
    async fn mdns_linux_accepts_dynamic_group_service_lifecycle() {
        let secret = DiscoveryGroupSecret::from_bytes([71; 32]);
        let key = crate::identity::PrivateDeviceKey::from_seed(&[72; 32])
            .unwrap()
            .public_key();
        let device = DeviceId::from_public_key(key.as_bytes());
        let selector = group_service_selector(&secret, 1);
        let provider = MdnsDiscovery::new().unwrap();
        let scope = DiscoveryScope::Group {
            epoch: 1,
            selector: selector.clone(),
        };
        provider
            .start(DiscoveryAdvertisement::group(
                selector,
                1,
                group_routing_token(&secret, 1, device),
                "compatibility-spike".into(),
                44222,
                1_000,
            ))
            .await
            .unwrap();
        provider.stop(&scope).await.unwrap();
    }
}
