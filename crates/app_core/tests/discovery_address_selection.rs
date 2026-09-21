//! Stage 1 discovery-address harness for the `discovery-address-selection` change.
//!
//! Two `AppCore` instances run on one host against separate data directories, each
//! with its own real `MdnsDiscovery` daemon. Assertions are made on **resolved
//! address values**, never on whether an operation succeeded: loopback genuinely
//! works when both peers share a machine, so a green "pairing completed" is not
//! evidence about the two-device path.
//!
//! Four observers run at once, because no single one can answer the question:
//!
//! | Observer | Sees | Answers |
//! |---|---|---|
//! | `advertiser` core | registers a pairing advertisement | what production advertises |
//! | `browser` core | real `PairingManager` candidate list | candidate multiplicity per instance |
//! | `observer` daemon | every `DiscoveredEndpoint` production emits | per-address endpoint emission |
//! | raw `mdns_sd` browse | `ScopedIp` with `interface_ids()` | interface origin, which `DiscoveredEndpoint` discards |
//!
//! The live spike is `#[ignore]`d: it needs UDP 5353 multicast and a multi-homed
//! host. Run it with:
//!
//! ```text
//! cargo test --test discovery_address_selection -- --ignored --nocapture
//! ```

use std::{
    collections::{BTreeMap, BTreeSet},
    net::{IpAddr, SocketAddr, UdpSocket},
    sync::Arc,
    time::{Duration, Instant},
};

use app_core::{
    AppCore, AppCoreConfig, DeviceId, DiscoveredEndpoint, DiscoveryEvent, DiscoveryGroupSecret,
    DiscoveryProvider, DiscoveryScope, InMemorySecureKeyStore, MdnsDiscovery, PairingCandidate,
    PrivateDeviceKey, QuinnTransportConfig, discovery::AddressPolicy, group_routing_token,
    group_service_selector, match_group_endpoint,
};

/// How the harness judges an address, independently of production code.
///
/// Deliberately separate from `discovery::is_lan_address`: the point of the spike
/// is to compare production's judgement against an external one.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum Classification {
    /// Reachable by a peer on the same local network.
    Routable,
    /// Reachable only from the host itself. Always "works" in a single-host test.
    Loopback,
    /// On-link only; IPv6 additionally needs a scope id that `SocketAddr` cannot carry.
    LinkLocal,
    /// Container, virtualization, or tunnel bridge belonging to this host.
    VirtualBridge,
    /// Anything else (globally scoped). Unexpected on a LAN; reported, not assumed.
    Other,
}

impl Classification {
    /// Matches the spec's SHALL NOT: loopback and host-local virtual addresses.
    #[must_use]
    const fn is_peer_unreachable(&self) -> bool {
        matches!(self, Self::Loopback | Self::VirtualBridge)
    }
}

/// Interface names that denote a host-local bridge rather than a real LAN segment.
const VIRTUAL_INTERFACE_MARKERS: &[&str] = &[
    "podman",
    "docker",
    "br-",
    "veth",
    "virbr",
    "cni",
    "flannel",
    "kube",
    "lxc",
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

fn is_host_local_interface(name: &str) -> bool {
    let lowered = name.to_ascii_lowercase();
    lowered == "lo"
        || lowered.starts_with("lo:")
        || VIRTUAL_INTERFACE_MARKERS
            .iter()
            .any(|marker| lowered.starts_with(marker))
}

fn classify(address: IpAddr, interfaces: &BTreeSet<String>) -> Classification {
    if address.is_loopback() {
        return Classification::Loopback;
    }
    if interfaces.iter().any(|name| is_host_local_interface(name)) {
        return Classification::VirtualBridge;
    }
    match address {
        IpAddr::V4(value) if value.is_link_local() => Classification::LinkLocal,
        IpAddr::V6(value) if value.is_unicast_link_local() => Classification::LinkLocal,
        IpAddr::V4(value) if value.is_private() => Classification::Routable,
        IpAddr::V6(value) if value.is_unique_local() => Classification::Routable,
        _ => Classification::Other,
    }
}

/// One address seen for the advertiser, with every place it was seen.
#[derive(Clone, Debug, Eq, PartialEq)]
struct ObservedAddress {
    address: IpAddr,
    interfaces: BTreeSet<String>,
    /// Present in the raw DNS-SD record, i.e. actually advertised on the wire.
    advertised: bool,
    /// Emitted by production `MdnsDiscovery` as a `DiscoveredEndpoint`.
    emitted: bool,
    /// Held by the real `PairingManager` candidate list at the end of the window.
    selected: bool,
    /// Source address the kernel routes to this destination from, if any.
    routed_from: Option<IpAddr>,
}

impl ObservedAddress {
    fn classification(&self) -> Classification {
        classify(self.address, &self.interfaces)
    }
}

/// Browses `service_type` with a measurement-only daemon and maps each address in
/// the advertiser's record to the interfaces it was discovered on.
///
/// `DiscoveredEndpoint` cannot answer this: `discovery.rs` reduces `ScopedIp` with
/// `to_ip_addr()`, dropping `interface_ids()` and any IPv6 scope id.
fn collect_interface_origins(
    service_type: &str,
    instance_hex: &str,
    window: Duration,
) -> BTreeMap<IpAddr, BTreeSet<String>> {
    let mut origins: BTreeMap<IpAddr, BTreeSet<String>> = BTreeMap::new();
    let Ok(daemon) = mdns_sd::ServiceDaemon::new() else {
        return origins;
    };
    let Ok(receiver) = daemon.browse(service_type) else {
        let _ = daemon.shutdown();
        return origins;
    };
    let deadline = Instant::now() + window;
    while Instant::now() < deadline {
        match receiver.recv_timeout(Duration::from_millis(250)) {
            Ok(mdns_sd::ServiceEvent::ServiceResolved(info)) => {
                let matches_instance = info
                    .get_properties()
                    .iter()
                    .any(|property| property.key() == "i" && property.val_str() == instance_hex);
                if !matches_instance {
                    continue;
                }
                for scoped in info.get_addresses() {
                    let entry = origins.entry(scoped.to_ip_addr()).or_default();
                    match scoped {
                        mdns_sd::ScopedIp::V4(v4) => {
                            for id in v4.interface_ids() {
                                entry.insert(id.name.clone());
                            }
                        }
                        mdns_sd::ScopedIp::V6(v6) => {
                            entry.insert(v6.scope_id().name.clone());
                        }
                        // `ScopedIp` is `#[non_exhaustive]`.
                        _ => {}
                    }
                }
            }
            Ok(_) => {}
            Err(mdns_sd::RecvTimeoutError::Timeout) => {}
            Err(_) => break,
        }
    }
    let _ = daemon.shutdown();
    origins
}

/// Records the source address the kernel picks for each destination.
///
/// This is the trap the proposal names: from the same host, loopback and the
/// container bridge both "succeed", so success cannot distinguish correct
/// address selection from an accident of shared-host testing.
fn probe_routes(addresses: &[IpAddr], port: u16) -> BTreeMap<IpAddr, Option<IpAddr>> {
    let mut routes = BTreeMap::new();
    for address in addresses {
        let observed = UdpSocket::bind(match address {
            IpAddr::V4(_) => "0.0.0.0:0",
            IpAddr::V6(_) => "[::]:0",
        })
        .ok()
        .and_then(|socket| {
            socket.connect(SocketAddr::new(*address, port)).ok()?;
            socket.local_addr().ok().map(|local| local.ip())
        });
        routes.insert(*address, observed);
    }
    routes
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "live mDNS spike: needs UDP 5353 multicast and a multi-homed host; run with --ignored --nocapture"]
async fn stage1_advertised_addresses_are_peer_routable() {
    let advertiser_dir = tempfile::tempdir().unwrap();
    let browser_dir = tempfile::tempdir().unwrap();

    // Measurement-only observer, started before anything advertises so it cannot
    // miss the first announcement.
    let observer = Arc::new(MdnsDiscovery::new().unwrap());
    let mut observer_events = observer.subscribe();
    observer
        .start_browse(DiscoveryScope::Pairing)
        .await
        .unwrap();

    let advertiser = AppCore::open_networked_with_discovery(
        advertiser_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([71; 32])),
        SocketAddr::from(([0, 0, 0, 0], 0)),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(MdnsDiscovery::new().unwrap()),
    )
    .await
    .unwrap();
    let browser = AppCore::open_networked_with_discovery(
        browser_dir.path(),
        Arc::new(InMemorySecureKeyStore::seeded([72; 32])),
        SocketAddr::from(([0, 0, 0, 0], 0)),
        AppCoreConfig::default(),
        QuinnTransportConfig::default(),
        Arc::new(MdnsDiscovery::new().unwrap()),
    )
    .await
    .unwrap();

    let window_ms = 30_000;
    let browser_candidates = browser.subscribe_pairing_candidates().unwrap();
    let advertiser_instance = advertiser.start_pairing(window_ms).await.unwrap();
    let browser_instance = browser.start_pairing(window_ms).await.unwrap();
    let instance_hex = advertiser_instance.to_string();

    // The raw browse runs on a blocking thread: `recv_timeout` is synchronous.
    let origins = {
        let service_type = app_core::discovery::PAIRING_SERVICE_TYPE.to_owned();
        let hex = instance_hex.clone();
        tokio::task::spawn_blocking(move || {
            collect_interface_origins(&service_type, &hex, Duration::from_secs(12))
        })
        .await
        .unwrap()
    };

    // Everything production emitted for this instance, across the same window.
    let mut emitted: BTreeSet<IpAddr> = BTreeSet::new();
    let drain_deadline = Instant::now() + Duration::from_secs(2);
    while Instant::now() < drain_deadline {
        match tokio::time::timeout(Duration::from_millis(250), observer_events.recv()).await {
            Ok(Ok(DiscoveryEvent::Upsert(endpoint))) => {
                if endpoint.properties.get("i").map(String::as_str) == Some(&instance_hex) {
                    emitted.insert(endpoint.address.ip());
                }
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }

    let candidates: Vec<PairingCandidate> = browser_candidates
        .borrow()
        .iter()
        .filter(|candidate| candidate.instance_id == advertiser_instance)
        .cloned()
        .collect();

    let mut addresses: BTreeMap<IpAddr, ObservedAddress> = BTreeMap::new();
    for (address, interfaces) in &origins {
        addresses.insert(
            *address,
            ObservedAddress {
                address: *address,
                interfaces: interfaces.clone(),
                advertised: true,
                emitted: emitted.contains(address),
                selected: false,
                routed_from: None,
            },
        );
    }
    for address in &emitted {
        addresses
            .entry(*address)
            .or_insert_with(|| ObservedAddress {
                address: *address,
                interfaces: BTreeSet::new(),
                advertised: false,
                emitted: true,
                selected: false,
                routed_from: None,
            });
    }
    let port = advertiser.pairing_addr().map_or(0, |addr| addr.port());
    let routes = probe_routes(&addresses.keys().copied().collect::<Vec<_>>(), port);
    for (address, observed) in routes {
        if let Some(entry) = addresses.get_mut(&address) {
            entry.routed_from = observed;
        }
    }
    for candidate in &candidates {
        if let Some(entry) = addresses.get_mut(&candidate.endpoint.ip()) {
            entry.selected = true;
        }
    }

    let observed: Vec<ObservedAddress> = addresses.into_values().collect();

    println!("=== stage 1: discovery address selection ===");
    println!("advertiser instance : {instance_hex}");
    println!("browser instance    : {browser_instance}");
    println!("advertiser data dir : {}", advertiser_dir.path().display());
    println!("browser data dir    : {}", browser_dir.path().display());
    println!("pairing QUIC port   : {port}");
    println!(
        "avahi coexistence   : registration and browsing both succeeded{}",
        if std::path::Path::new("/etc/avahi").exists() {
            " (avahi configuration present on host)"
        } else {
            ""
        }
    );
    println!(
        "candidates for one instance : {} (instance_id {instance_hex})",
        candidates.len()
    );
    for candidate in &candidates {
        println!("  candidate endpoint  : {}", candidate.endpoint);
    }
    println!(
        "{:<24} {:<22} {:<14} {:<4} {:<4} {:<4} routed-from",
        "address", "interfaces", "class", "adv", "emit", "sel"
    );
    for entry in &observed {
        println!(
            "{:<24} {:<22} {:<14?} {:<4} {:<4} {:<4} {}",
            entry.address.to_string(),
            entry
                .interfaces
                .iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(","),
            entry.classification(),
            entry.advertised,
            entry.emitted,
            entry.selected,
            entry
                .routed_from
                .map_or("-".to_owned(), |source| source.to_string()),
        );
    }

    let unreachable: Vec<_> = observed
        .iter()
        .filter(|entry| entry.classification().is_peer_unreachable())
        .collect();
    let routable: Vec<_> = observed
        .iter()
        .filter(|entry| entry.classification() == Classification::Routable)
        .collect();

    // Task 1.2: fail on address *values*, not on outcomes.
    assert!(
        !observed.is_empty(),
        "no address resolved for instance {instance_hex}; the harness measured nothing"
    );
    assert!(
        !routable.is_empty(),
        "no peer-routable address was advertised; a remote device could never dial this host"
    );
    assert!(
        routable.iter().any(|entry| entry.advertised),
        "the routable address must remain advertised, or the device becomes undiscoverable"
    );
    for entry in &unreachable {
        assert!(
            !entry.selected,
            "peer-unreachable address {} ({:?}, interfaces {:?}) was selected as the candidate \
             endpoint; a remote device would dial an address that only exists on this host",
            entry.address,
            entry.classification(),
            entry.interfaces
        );
    }
    assert!(
        unreachable.iter().all(|entry| !entry.advertised),
        "peer-unreachable addresses were advertised: {:?}",
        unreachable
            .iter()
            .map(|entry| (entry.address, entry.classification()))
            .collect::<Vec<_>>()
    );

    // Task 1.3: one physical device must not surface as several candidates.
    assert!(
        candidates.len() <= 1,
        "one advertising instance yielded {} pairing candidates sharing instance_id {instance_hex}",
        candidates.len()
    );

    advertiser.shutdown().await.unwrap();
    browser.shutdown().await.unwrap();
}

/// Task 3.1: record whether inbound multicast reaches *this application's own
/// socket*, as distinct from `avahi`'s.
///
/// Reading the nft ruleset needs elevated privileges and still only shows intent.
/// This is the direct measurement: a daemon that is not `avahi` browses service
/// types that only remote hosts publish, and reports what arrives. Same-host
/// traffic cannot satisfy it, because the probe discards every address belonging
/// to this host.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "live mDNS spike: needs a LAN with other mDNS-speaking hosts; run with --ignored --nocapture"]
async fn stage1_inbound_multicast_reaches_our_own_socket() {
    // The address this host presents on the LAN, learned from the kernel rather
    // than hardcoded, so anything else is a candidate remote peer.
    let mut own: BTreeSet<IpAddr> = BTreeSet::new();
    for destination in ["224.0.0.251:5353", "[ff02::fb]:5353"] {
        let bind = if destination.starts_with('[') {
            "[::]:0"
        } else {
            "0.0.0.0:0"
        };
        if let Ok(socket) = UdpSocket::bind(bind)
            && socket.connect(destination).is_ok()
            && let Ok(local) = socket.local_addr()
        {
            own.insert(local.ip());
        }
    }
    own.insert("127.0.0.1".parse().unwrap());

    let daemon = mdns_sd::ServiceDaemon::new().unwrap();
    // `_services._dns-sd._udp.local.` is the meta-query: hosts enumerate their own
    // service types through it, so it draws traffic from every mDNS speaker present.
    let probes = ["_services._dns-sd._udp.local.", "_workstation._tcp.local."];
    let mut receivers = Vec::new();
    for service_type in probes {
        receivers.push((service_type, daemon.browse(service_type).unwrap()));
    }

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut remote: BTreeSet<IpAddr> = BTreeSet::new();
    let mut local_resolved = 0usize;
    while Instant::now() < deadline {
        for (service_type, receiver) in &receivers {
            while let Ok(event) = receiver.try_recv() {
                if let mdns_sd::ServiceEvent::ServiceResolved(info) = event {
                    for scoped in info.get_addresses() {
                        let address = scoped.to_ip_addr();
                        // A container-bridge address is this host's too, even
                        // though the kernel does not route multicast through it.
                        let mut interfaces = BTreeSet::new();
                        match scoped {
                            mdns_sd::ScopedIp::V4(v4) => {
                                for id in v4.interface_ids() {
                                    interfaces.insert(id.name.clone());
                                }
                            }
                            mdns_sd::ScopedIp::V6(v6) => {
                                interfaces.insert(v6.scope_id().name.clone());
                            }
                            _ => {}
                        }
                        if own.contains(&address)
                            || interfaces.iter().any(|name| is_host_local_interface(name))
                        {
                            local_resolved += 1;
                        } else {
                            println!(
                                "remote via {service_type:<28} {} -> {address} on {:?}",
                                info.get_fullname(),
                                interfaces
                            );
                            remote.insert(address);
                        }
                    }
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let _ = daemon.shutdown();

    println!("=== stage 1: inbound multicast ===");
    println!("this host's own addresses : {own:?}");
    println!("resolved to this host     : {local_resolved}");
    println!("resolved to remote hosts  : {:?}", remote);
    println!(
        "verdict                   : {}",
        if remote.is_empty() {
            "no remote mDNS host answered; inbound multicast from the LAN is NOT confirmed \
             (either the firewall drops it, or no other host is present)"
        } else {
            "inbound multicast from remote hosts reaches this application's own socket"
        }
    );
    // Not asserted: an empty LAN is a legitimate environment, and a false failure
    // here would mask the address-selection evidence this harness exists for.
}

/// Task 2.2 / 5.1: group-path admission at runtime, probed through
/// `match_group_endpoint` with the production policy for a `0.0.0.0` bind.
///
/// Stage 1 recorded all three admitted. After the fix a loopback address from a
/// remote record is rejected; `10.88.0.1` is still admitted here because an address
/// alone cannot distinguish a bridge from a real `10.x` LAN — that address is kept
/// off the wire by the advertisement filter instead.
#[test]
fn group_path_rejects_loopback_from_remote_records() {
    let secret = DiscoveryGroupSecret::from_bytes([3; 32]);
    let device = DeviceId::from_public_key(
        PrivateDeviceKey::from_seed(&[4; 32])
            .unwrap()
            .public_key()
            .as_bytes(),
    );
    let epoch = 1;
    let selector = group_service_selector(&secret, epoch);
    let route = group_routing_token(&secret, epoch, device);

    let probes = [
        ("lo", "127.0.0.1", Classification::Loopback),
        ("wlan0", "192.168.0.104", Classification::Routable),
        ("podman0", "10.88.0.1", Classification::VirtualBridge),
    ];
    let policy = AddressPolicy::default();
    let mut admitted = Vec::new();
    for (interface, ip, expected_class) in probes {
        let address: IpAddr = ip.parse().unwrap();
        assert_eq!(
            classify(address, &BTreeSet::from([interface.to_owned()])),
            expected_class,
            "harness classifier disagrees with itself for {interface}"
        );
        let endpoint = DiscoveredEndpoint {
            scope: DiscoveryScope::Group {
                epoch,
                selector: selector.clone(),
            },
            instance_name: "probe".into(),
            address: SocketAddr::new(address, 4433),
            properties: BTreeMap::from([
                ("v".into(), "1".into()),
                ("e".into(), epoch.to_string()),
                ("r".into(), route.clone()),
            ]),
            expires_at_ms: 1_000,
        };
        let result = match_group_endpoint(&endpoint, &secret, &policy, [device]).is_some();
        println!("admits_peer_address {interface:<8} {ip:<16} admitted={result}");
        admitted.push((interface, result));
    }
    assert_eq!(
        admitted,
        vec![("lo", false), ("wlan0", true), ("podman0", true)]
    );
}

/// Task 2.4: determine whether `mdns-sd` exposes interface pinning or address
/// filtering, or whether filtering must live in `MdnsDiscovery`.
///
/// A compile-and-run probe of the pinned crate's configuration surface. If this
/// test stops compiling, the vendor API moved and any filtering built on it must
/// be revisited.
#[test]
fn mdns_sd_exposes_interface_pinning_and_address_filtering() {
    let mut info = mdns_sd::ServiceInfo::new(
        app_core::discovery::PAIRING_SERVICE_TYPE,
        "probe",
        "probe.local.",
        "",
        4433,
        &[("v", "1"), ("i", &"0".repeat(32))][..],
    )
    .unwrap()
    .enable_addr_auto();

    // Per-service filtering: restrict which interfaces the auto-detected addresses
    // may come from, by name, by address, by loopback class, or by predicate.
    info.set_interfaces(vec![
        mdns_sd::IfKind::Name("wlan0".to_owned()),
        mdns_sd::IfKind::Addr("192.168.0.104".parse().unwrap()),
        mdns_sd::IfKind::LoopbackV4,
    ]);
    info.set_link_local_only(false);
    assert!(info.is_addr_auto());
    assert!(info.get_addresses().is_empty());

    // Daemon-level pinning exists too; assert only that the selectors are
    // constructible and distinct, since building a daemon binds UDP 5353.
    let selectors = [
        mdns_sd::IfKind::All,
        mdns_sd::IfKind::IPv4,
        mdns_sd::IfKind::IPv6,
        mdns_sd::IfKind::LoopbackV4,
        mdns_sd::IfKind::LoopbackV6,
    ];
    assert!(matches!(
        selectors.as_slice(),
        &[
            mdns_sd::IfKind::All,
            mdns_sd::IfKind::IPv4,
            mdns_sd::IfKind::IPv6,
            mdns_sd::IfKind::LoopbackV4,
            mdns_sd::IfKind::LoopbackV6,
        ]
    ));
}
