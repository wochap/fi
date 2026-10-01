//! Provider-neutral, privacy-preserving LAN endpoint discovery.

use std::{
    collections::{BTreeMap, HashMap},
    fmt,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use async_trait::async_trait;
use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::{control::TrustState, identity::DeviceId};

/// Generic pairing service type. The label is `_fi-` followed by the lowercase
/// unpadded base32 of the first 6 bytes of `SHA-256("fi-mdns-pairing-v1")`, the
/// same shape as [`group_service_selector`], so it does not name its purpose.
pub const PAIRING_SERVICE_TYPE: &str = "_fi-gremyncn3q._udp.local.";
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
    /// Log-only group fingerprint; never published in mDNS properties.
    pub secret_fingerprint: Option<String>,
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
            secret_fingerprint: None,
        }
    }

    #[must_use]
    pub fn group(
        selector: String,
        epoch: u64,
        route_token: String,
        fingerprint: String,
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
            secret_fingerprint: Some(fingerprint),
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

/// Interface-name prefixes of the tunnels a tailnet address may live on:
/// `tailscale0` on desktop, `tun0` for the Android VPN service.
const TAILNET_INTERFACE_PREFIXES: &[&str] = &["tailscale", "tun"];

/// How long a [`TailnetProbe`] reuses one interface scan.
const TAILNET_PROBE_CACHE: Duration = Duration::from_secs(2);

/// Whether `address` is in the tailnet range `100.64.0.0/10`.
#[must_use]
pub const fn is_tailnet_address(address: Ipv4Addr) -> bool {
    let octets = address.octets();
    octets[0] == 100 && octets[1] & 0b1100_0000 == 64
}

/// Whether `address` is an IPv4 tailnet address.
#[must_use]
pub const fn is_tailnet_ip(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(value) => is_tailnet_address(value),
        IpAddr::V6(_) => false,
    }
}

/// Tailnet addresses held by tunnel interfaces among `(name, address, point_to_point)`,
/// ascending and deduplicated. A `100.64.0.0/10` address on any other interface,
/// such as a carrier-grade NAT address on mobile data, does not count.
#[must_use]
pub fn tailnet_addresses(
    interfaces: impl IntoIterator<Item = (String, IpAddr, bool)>,
) -> Vec<Ipv4Addr> {
    let mut addresses: Vec<_> = interfaces
        .into_iter()
        .filter(|(name, _, _)| {
            let lowered = name.to_ascii_lowercase();
            TAILNET_INTERFACE_PREFIXES
                .iter()
                .any(|prefix| lowered.starts_with(prefix))
        })
        .filter_map(|(_, address, _)| match address {
            IpAddr::V4(value) if is_tailnet_address(value) => Some(value),
            _ => None,
        })
        .collect();
    addresses.sort_unstable();
    addresses.dedup();
    addresses
}

/// Whether this device is on a tailnet and at which addresses, read from the
/// current interfaces and cached briefly so hot paths do not rescan them.
#[derive(Clone, Default)]
pub struct TailnetProbe(Arc<TailnetSource>);

#[derive(Default)]
enum TailnetSource {
    #[default]
    System,
    Fixed(Mutex<Vec<Ipv4Addr>>),
}

static SYSTEM_TAILNET: Mutex<Option<(Instant, Vec<Ipv4Addr>)>> = Mutex::new(None);

impl fmt::Debug for TailnetProbe {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("TailnetProbe")
            .field(&self.addresses())
            .finish()
    }
}

impl TailnetProbe {
    /// Reads the host's interfaces.
    #[must_use]
    pub fn system() -> Self {
        Self::default()
    }

    /// Reports `addresses` until changed with [`Self::set_addresses`]; for tests.
    #[must_use]
    pub fn fixed(addresses: impl IntoIterator<Item = Ipv4Addr>) -> Self {
        Self(Arc::new(TailnetSource::Fixed(Mutex::new(
            addresses.into_iter().collect(),
        ))))
    }

    /// Replaces the addresses of a fixed probe; a system probe ignores it.
    pub fn set_addresses(&self, addresses: impl IntoIterator<Item = Ipv4Addr>) {
        if let TailnetSource::Fixed(current) = self.0.as_ref()
            && let Ok(mut current) = current.lock()
        {
            *current = addresses.into_iter().collect();
        }
    }

    /// This device's tailnet addresses, ascending.
    #[must_use]
    pub fn addresses(&self) -> Vec<Ipv4Addr> {
        match self.0.as_ref() {
            TailnetSource::System => {
                let Ok(mut cache) = SYSTEM_TAILNET.lock() else {
                    return Vec::new();
                };
                if let Some((at, addresses)) = cache.as_ref()
                    && at.elapsed() < TAILNET_PROBE_CACHE
                {
                    return addresses.clone();
                }
                let addresses = tailnet_addresses(
                    if_addrs::get_if_addrs()
                        .unwrap_or_default()
                        .into_iter()
                        .map(|interface| {
                            let address = interface.ip();
                            (interface.name, address, interface.is_p2p)
                        }),
                );
                *cache = Some((Instant::now(), addresses.clone()));
                addresses
            }
            TailnetSource::Fixed(addresses) => addresses
                .lock()
                .map(|addresses| addresses.clone())
                .unwrap_or_default(),
        }
    }

    /// Whether a tunnel interface currently holds a tailnet address.
    #[must_use]
    pub fn on_tailnet(&self) -> bool {
        !self.addresses().is_empty()
    }
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

    /// Sync side: the LAN rule, plus tailnet peers while this device is on a
    /// tailnet and bound to IPv4. Pairing and discovery keep the LAN rule.
    #[must_use]
    pub fn admits_sync_peer_address(&self, address: IpAddr, on_tailnet: bool) -> bool {
        self.admits_peer_address(address)
            || (on_tailnet
                && self.local_bind.is_ipv4()
                && !self.local_bind.is_loopback()
                && is_tailnet_ip(address))
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

/// Interfaces the mDNS daemon must not use for a transport bound under `policy`:
/// an IPv4 LAN bind keeps mDNS off IPv6 and loopback; an IPv4 loopback bind keeps
/// loopback for single-host tests; an IPv6 bind keeps everything.
fn disabled_mdns_interfaces(policy: AddressPolicy) -> Vec<mdns_sd::IfKind> {
    match policy.local_bind() {
        IpAddr::V4(address) if address.is_loopback() => vec![mdns_sd::IfKind::IPv6],
        IpAddr::V4(_) => vec![
            mdns_sd::IfKind::IPv6,
            mdns_sd::IfKind::LoopbackV4,
            mdns_sd::IfKind::LoopbackV6,
        ],
        IpAddr::V6(_) => Vec::new(),
    }
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
        let disabled = disabled_mdns_interfaces(policy);
        if !disabled.is_empty() {
            daemon
                .disable_interface(disabled)
                .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        }
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
                fingerprint = advertisement.secret_fingerprint.as_deref(),
                "advertising peer-routable addresses"
            );
        }
        let fullname = info.get_fullname().to_owned();
        tracing::info!(
            event = "discovery_browse_start",
            scope = ?advertisement.scope,
            service_type = %service_type
        );
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
                        let instance_name = info
                            .get_fullname()
                            .strip_suffix(&service_suffix)
                            .unwrap_or(info.get_fullname())
                            .to_owned();
                        tracing::info!(
                            event = "discovery_service_resolved",
                            scope = ?scope,
                            instance = %instance_name,
                            addresses = ?info.get_addresses(),
                            port = info.get_port()
                        );
                        for address in info.get_addresses() {
                            let _ = events.send(DiscoveryEvent::Upsert(DiscoveredEndpoint {
                                scope: scope.clone(),
                                instance_name: instance_name.clone(),
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
        tracing::info!(
            event = "discovery_browse_start",
            scope = ?scope,
            service_type = %service_type
        );
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
                        let instance_name = info
                            .get_fullname()
                            .strip_suffix(&service_suffix)
                            .unwrap_or(info.get_fullname())
                            .to_owned();
                        tracing::info!(
                            event = "discovery_service_resolved",
                            scope = ?event_scope,
                            instance = %instance_name,
                            addresses = ?info.get_addresses(),
                            port = info.get_port()
                        );
                        for address in info.get_addresses() {
                            let _ = events.send(DiscoveryEvent::Upsert(DiscoveredEndpoint {
                                scope: event_scope.clone(),
                                instance_name: instance_name.clone(),
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

/// Short, non-reversible group fingerprint for comparing devices' logs.
#[must_use]
pub fn discovery_secret_fingerprint(secret: &DiscoveryGroupSecret) -> String {
    let mut mac = HmacSha256::new_from_slice(secret.expose()).expect("HMAC accepts any key length");
    mac.update(b"fp");
    let output = mac.finalize().into_bytes();
    output[..4]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Why a group-scoped record did not match this device's group.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GroupRejection {
    Address,
    Selector,
    Token,
    Untrusted(DeviceId),
    Own,
}

impl GroupRejection {
    #[must_use]
    pub const fn reason(&self) -> &'static str {
        match self {
            Self::Address => "address",
            Self::Selector => "selector",
            Self::Token => "token",
            Self::Untrusted(_) => "untrusted",
            Self::Own => "own",
        }
    }
}

pub fn classify_group_endpoint(
    endpoint: &DiscoveredEndpoint,
    secret: &DiscoveryGroupSecret,
    policy: &AddressPolicy,
    local: DeviceId,
    known: &[(DeviceId, TrustState)],
) -> Result<(DeviceId, SocketAddr, u64), GroupRejection> {
    if !policy.admits_peer_address(endpoint.address.ip()) || endpoint.expires_at_ms == 0 {
        return Err(GroupRejection::Address);
    }
    let DiscoveryScope::Group { epoch, selector } = &endpoint.scope else {
        return Err(GroupRejection::Selector);
    };
    if *selector != group_service_selector(secret, *epoch) {
        return Err(GroupRejection::Selector);
    }
    let advertised = endpoint.properties.get("r").ok_or(GroupRejection::Token)?;
    let routes = |device| group_routing_token(secret, *epoch, device) == *advertised;
    if routes(local) {
        return Err(GroupRejection::Own);
    }
    if let Some((device, _)) = known
        .iter()
        .find(|(device, state)| *state == TrustState::Trusted && routes(*device))
    {
        return Ok((*device, endpoint.address, endpoint.expires_at_ms));
    }
    match known
        .iter()
        .find(|(device, state)| *state != TrustState::Trusted && routes(*device))
    {
        Some((device, _)) => Err(GroupRejection::Untrusted(*device)),
        None => Err(GroupRejection::Token),
    }
}

#[must_use]
pub fn match_group_endpoint(
    endpoint: &DiscoveredEndpoint,
    secret: &DiscoveryGroupSecret,
    policy: &AddressPolicy,
    trusted: impl IntoIterator<Item = DeviceId>,
) -> Option<(DeviceId, SocketAddr, u64)> {
    let known: Vec<_> = trusted
        .into_iter()
        .map(|device| (device, TrustState::Trusted))
        .collect();
    // A local id derived from no real key never matches, so nothing is "own".
    let nobody = DeviceId::from_public_key(&[0; 32]);
    classify_group_endpoint(endpoint, secret, policy, nobody, &known).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pairing_service_type_matches_its_derivation() {
        use sha2::Digest as _;
        let digest = Sha256::digest(b"fi-mdns-pairing-v1");
        let expected = format!(
            "_fi-{}._udp.local.",
            BASE32_NOPAD.encode(&digest[..6]).to_ascii_lowercase()
        );
        assert_eq!(PAIRING_SERVICE_TYPE, expected);
        assert!(!PAIRING_SERVICE_TYPE.contains("pair"));
        assert!(!PAIRING_SERVICE_TYPE.contains("myapp"));
    }

    #[test]
    fn disabled_mdns_interfaces_follow_the_bind() {
        let lan = disabled_mdns_interfaces(AddressPolicy::default());
        assert!(matches!(
            lan.as_slice(),
            [
                mdns_sd::IfKind::IPv6,
                mdns_sd::IfKind::LoopbackV4,
                mdns_sd::IfKind::LoopbackV6
            ]
        ));
        let loopback =
            disabled_mdns_interfaces(AddressPolicy::for_bind("127.0.0.1".parse().unwrap()));
        assert!(matches!(loopback.as_slice(), [mdns_sd::IfKind::IPv6]));
        assert!(
            disabled_mdns_interfaces(AddressPolicy::for_bind("::".parse().unwrap())).is_empty()
        );
    }

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

    fn interfaces(names: &[(&str, &str)]) -> Vec<(String, IpAddr, bool)> {
        names
            .iter()
            .map(|(name, ip)| ((*name).to_owned(), ip.parse::<IpAddr>().unwrap(), false))
            .collect()
    }

    #[test]
    fn tailnet_addresses_need_a_tunnel_interface() {
        let tailnet: Ipv4Addr = "100.71.3.9".parse().unwrap();
        assert!(is_tailnet_address(tailnet));
        assert!(is_tailnet_address("100.64.0.0".parse().unwrap()));
        assert!(is_tailnet_address("100.127.255.255".parse().unwrap()));
        assert!(!is_tailnet_address("100.128.0.1".parse().unwrap()));
        assert!(!is_tailnet_address("100.63.255.255".parse().unwrap()));
        assert_eq!(
            tailnet_addresses(interfaces(&[("tailscale0", "100.71.3.9")])),
            vec![tailnet]
        );
        assert_eq!(
            tailnet_addresses(interfaces(&[("tun0", "100.71.3.9")])),
            vec![tailnet]
        );
        assert_eq!(
            tailnet_addresses(interfaces(&[("Tailscale", "100.71.3.9")])),
            vec![tailnet]
        );
        assert!(tailnet_addresses(interfaces(&[("rmnet_data0", "100.100.5.6")])).is_empty());
        assert!(tailnet_addresses(interfaces(&[("tun0", "192.168.0.5")])).is_empty());
        assert!(tailnet_addresses(interfaces(&[("tun0", "fd7a:115c:a1e0::1")])).is_empty());
        assert_eq!(
            tailnet_addresses(interfaces(&[
                ("wlan0", "192.168.0.165"),
                ("tun0", "100.99.0.1"),
                ("tailscale0", "100.71.3.9"),
                ("tailscale0", "100.71.3.9"),
            ])),
            vec![tailnet, "100.99.0.1".parse().unwrap()]
        );
    }

    #[test]
    fn tailnet_probe_reports_injected_addresses() {
        let probe = TailnetProbe::fixed(tailnet_addresses(interfaces(&[
            ("wlan0", "192.168.0.165"),
            ("tun0", "100.71.3.9"),
        ])));
        assert!(probe.on_tailnet());
        assert_eq!(
            probe.addresses(),
            vec!["100.71.3.9".parse::<Ipv4Addr>().unwrap()]
        );
        probe.set_addresses(tailnet_addresses(interfaces(&[(
            "rmnet_data0",
            "100.100.5.6",
        )])));
        assert!(!probe.on_tailnet());
        // The system probe scans real interfaces; it must not panic.
        let _ = TailnetProbe::system().on_tailnet();
    }

    #[test]
    fn sync_admission_adds_tailnet_peers_only_on_a_tailnet() {
        let peer: IpAddr = "100.88.10.4".parse().unwrap();
        let policy = AddressPolicy::default();
        assert!(policy.admits_sync_peer_address(peer, true));
        assert!(!policy.admits_sync_peer_address(peer, false));
        assert!(
            !policy.admits_peer_address(peer),
            "pairing keeps the LAN rule"
        );
        assert!(policy.admits_sync_peer_address("192.168.0.165".parse().unwrap(), false));
        assert!(!policy.admits_sync_peer_address("8.8.8.8".parse().unwrap(), true));
        assert!(!policy.admits_sync_peer_address("100.128.0.1".parse().unwrap(), true));
        assert!(!policy.admits_sync_peer_address("127.0.0.1".parse().unwrap(), true));
        let lan = AddressPolicy::for_bind("192.168.0.165".parse().unwrap());
        assert!(lan.admits_sync_peer_address(peer, true));
        let ipv6 = AddressPolicy::for_bind("::".parse().unwrap());
        assert!(!ipv6.admits_sync_peer_address(peer, true));
        let loopback = AddressPolicy::for_bind("127.0.0.1".parse().unwrap());
        assert!(!loopback.admits_sync_peer_address(peer, true));
        assert!(loopback.admits_sync_peer_address("127.0.0.1".parse().unwrap(), true));
    }

    #[test]
    fn tailnet_addresses_are_never_advertised() {
        let policy = AddressPolicy::default();
        for tunnel in ["tailscale0", "tun0"] {
            assert_eq!(
                policy.advertisable_addresses(interfaces(&[
                    ("wlan0", "192.168.0.165"),
                    (tunnel, "100.71.3.9"),
                ])),
                vec!["192.168.0.165".parse::<IpAddr>().unwrap()]
            );
        }
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

    #[test]
    fn secret_fingerprint_is_stable_short_and_not_the_secret_prefix() {
        let a = DiscoveryGroupSecret::from_bytes([1; 32]);
        let b = DiscoveryGroupSecret::from_bytes([2; 32]);
        let fingerprint = discovery_secret_fingerprint(&a);
        assert_eq!(fingerprint.len(), 8);
        // Independent of epoch: the same secret stays recognisable across epochs 1 and 2.
        assert_eq!(fingerprint, discovery_secret_fingerprint(&a));
        assert_ne!(fingerprint, discovery_secret_fingerprint(&b));
        assert_ne!(fingerprint, hex::encode(&a.expose()[..4]));
        let advertisement = DiscoveryAdvertisement::group(
            group_service_selector(&a, 2),
            2,
            "route".into(),
            fingerprint.clone(),
            "name".into(),
            1,
            1,
        );
        assert_eq!(
            advertisement.secret_fingerprint.as_deref(),
            Some(&*fingerprint)
        );
        assert!(!advertisement.properties.values().any(|v| *v == fingerprint));
    }

    #[test]
    fn group_records_are_classified_with_a_typed_reason() {
        let secret = DiscoveryGroupSecret::from_bytes([1; 32]);
        let other = DiscoveryGroupSecret::from_bytes([2; 32]);
        let device = |seed| {
            let key = crate::identity::PrivateDeviceKey::from_seed(&[seed; 32])
                .unwrap()
                .public_key();
            DeviceId::from_public_key(key.as_bytes())
        };
        let (local, trusted, revoked, stranger) = (device(1), device(2), device(3), device(4));
        let known = [
            (trusted, TrustState::Trusted),
            (revoked, TrustState::Revoked),
        ];
        let policy = AddressPolicy::default();
        let record = |route: Option<DeviceId>| DiscoveredEndpoint {
            scope: DiscoveryScope::Group {
                epoch: 1,
                selector: group_service_selector(&secret, 1),
            },
            instance_name: "opaque".into(),
            address: "192.168.1.20:42".parse().unwrap(),
            properties: route
                .map(|id| ("r".to_owned(), group_routing_token(&secret, 1, id)))
                .into_iter()
                .collect(),
            expires_at_ms: 10,
        };
        let classify = |endpoint: &DiscoveredEndpoint, secret| {
            classify_group_endpoint(endpoint, secret, &policy, local, &known)
        };
        assert_eq!(
            classify(&record(Some(trusted)), &secret).unwrap().0,
            trusted
        );
        assert_eq!(
            classify(&record(Some(revoked)), &secret),
            Err(GroupRejection::Untrusted(revoked))
        );
        assert_eq!(
            classify(&record(Some(stranger)), &secret),
            Err(GroupRejection::Token)
        );
        assert_eq!(classify(&record(None), &secret), Err(GroupRejection::Token));
        assert_eq!(
            classify(&record(Some(local)), &secret),
            Err(GroupRejection::Own)
        );
        assert_eq!(
            classify(&record(Some(trusted)), &other),
            Err(GroupRejection::Selector)
        );
        let pairing = DiscoveredEndpoint {
            scope: DiscoveryScope::Pairing,
            ..record(Some(trusted))
        };
        assert_eq!(classify(&pairing, &secret), Err(GroupRejection::Selector));
        let loopback = DiscoveredEndpoint {
            address: "127.0.0.1:42".parse().unwrap(),
            ..record(Some(trusted))
        };
        assert_eq!(classify(&loopback, &secret), Err(GroupRejection::Address));
        let expired = DiscoveredEndpoint {
            expires_at_ms: 0,
            ..record(Some(trusted))
        };
        assert_eq!(classify(&expired, &secret), Err(GroupRejection::Address));
        assert_eq!(
            [
                GroupRejection::Address,
                GroupRejection::Selector,
                GroupRejection::Token,
                GroupRejection::Untrusted(revoked),
                GroupRejection::Own,
            ]
            .map(|rejection| rejection.reason()),
            ["address", "selector", "token", "untrusted", "own"]
        );
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
                discovery_secret_fingerprint(&secret),
                "compatibility-spike".into(),
                44222,
                1_000,
            ))
            .await
            .unwrap();
        provider.stop(&scope).await.unwrap();
    }
}
