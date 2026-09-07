//! Provider-neutral, privacy-preserving LAN endpoint discovery.

use std::{
    collections::{BTreeMap, HashMap},
    fmt,
    net::{IpAddr, SocketAddr},
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
    active: Mutex<HashMap<DiscoveryScope, MdnsActive>>,
    events: broadcast::Sender<DiscoveryEvent>,
}

impl fmt::Debug for MdnsDiscovery {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MdnsDiscovery").finish_non_exhaustive()
    }
}

impl MdnsDiscovery {
    pub fn new() -> Result<Self, DiscoveryError> {
        let daemon = mdns_sd::ServiceDaemon::new()
            .map_err(|error| DiscoveryError::Provider(error.to_string()))?;
        let (events, _) = broadcast::channel(128);
        Ok(Self {
            daemon,
            active: Mutex::new(HashMap::new()),
            events,
        })
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
        let info = mdns_sd::ServiceInfo::new(
            &service_type,
            &advertisement.instance_name,
            &hostname,
            "",
            advertisement.port,
            properties.as_slice(),
        )
        .map_err(|error| DiscoveryError::Provider(error.to_string()))?
        .enable_addr_auto();
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
    trusted: impl IntoIterator<Item = DeviceId>,
) -> Option<(DeviceId, SocketAddr, u64)> {
    if !is_lan_address(endpoint.address.ip()) || endpoint.expires_at_ms == 0 {
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

fn is_lan_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(value) => value.is_private() || value.is_link_local() || value.is_loopback(),
        IpAddr::V6(value) => {
            value.is_unique_local() || value.is_unicast_link_local() || value.is_loopback()
        }
    }
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
            address: "127.0.0.1:42".parse().unwrap(),
            properties: BTreeMap::from([
                ("v".into(), "1".into()),
                ("e".into(), "1".into()),
                ("r".into(), group_routing_token(&a, 1, device)),
            ]),
            expires_at_ms: 10,
        };
        assert!(match_group_endpoint(&endpoint, &a, []).is_none());
        assert_eq!(
            match_group_endpoint(&endpoint, &a, [device]).unwrap().0,
            device
        );
        assert!(match_group_endpoint(&endpoint, &b, [device]).is_none());
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
