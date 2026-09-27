//! Under the fixed port policy the sync and pairing endpoints bind inside the
//! configured range, in order, and an exhausted range defers networking
//! instead of falling back to an ephemeral port.

use std::{net::UdpSocket, ops::RangeInclusive, sync::Arc};

use app_core::{
    AppCore, AppCoreConfig, FakeDiscoveryProvider, InMemorySecureKeyStore, ManualClock,
    NetworkPorts, NetworkingDeferredReason, PortPolicy, QuinnTransportConfig,
};

/// Finds `len` contiguous loopback UDP ports that are free right now. The
/// sockets are returned so the caller decides which ports to release.
fn free_range(len: u16) -> (RangeInclusive<u16>, Vec<UdpSocket>) {
    for _ in 0..200 {
        let probe = UdpSocket::bind("127.0.0.1:0").unwrap();
        let first = probe.local_addr().unwrap().port();
        drop(probe);
        let Some(last) = first.checked_add(len - 1) else {
            continue;
        };
        let held: Result<Vec<_>, _> = (first..=last)
            .map(|port| UdpSocket::bind(("127.0.0.1", port)))
            .collect();
        if let Ok(held) = held {
            return (first..=last, held);
        }
    }
    panic!("no free contiguous UDP range found");
}

async fn open(dir: &std::path::Path, seed: u8, range: RangeInclusive<u16>) -> AppCore {
    open_on(dir, seed, "127.0.0.1:0", range).await.unwrap()
}

async fn open_on(
    dir: &std::path::Path,
    seed: u8,
    bind: &str,
    range: RangeInclusive<u16>,
) -> app_core::Result<AppCore> {
    AppCore::open_networked_with_discovery(
        dir,
        Arc::new(InMemorySecureKeyStore::seeded([seed; 32])),
        bind.parse().unwrap(),
        AppCoreConfig {
            ports: PortPolicy::Range(range),
            ..AppCoreConfig::default()
        },
        QuinnTransportConfig::default(),
        Arc::new(FakeDiscoveryProvider::new(Arc::new(ManualClock::new(0)))),
    )
    .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_cores_take_consecutive_ports_in_the_range() {
    let (range, held) = free_range(4);
    drop(held);
    let r = *range.start();
    let dir_a = tempfile::tempdir().unwrap();
    let dir_b = tempfile::tempdir().unwrap();
    let a = open(dir_a.path(), 41, range.clone()).await;
    let b = open(dir_b.path(), 42, range.clone()).await;

    assert_eq!(a.networking_deferred(), None);
    assert_eq!(b.networking_deferred(), None);
    assert_eq!(
        a.network_ports(),
        NetworkPorts {
            sync: Some(r),
            pairing: Some(r + 1),
            policy: PortPolicy::Range(range.clone()),
        }
    );
    assert_eq!(a.network_addr().unwrap().port(), r);
    assert_eq!(a.pairing_addr().unwrap().port(), r + 1);
    assert_eq!(b.network_ports().sync, Some(r + 2));
    assert_eq!(b.network_ports().pairing, Some(r + 3));
    assert_eq!(b.network_addr().unwrap().port(), r + 2);
    assert_eq!(b.pairing_addr().unwrap().port(), r + 3);

    a.shutdown().await.unwrap();
    b.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_exhausted_range_defers_networking_and_a_reopen_recovers() {
    let (range, mut held) = free_range(3);
    let dir = tempfile::tempdir().unwrap();
    let core = open(dir.path(), 43, range.clone()).await;

    assert_eq!(
        core.networking_deferred(),
        Some(NetworkingDeferredReason::PortsExhausted {
            first: *range.start(),
            last: *range.end(),
        })
    );
    assert!(core.networking_requires_reopen());
    assert_eq!(core.network_addr(), None);
    assert_eq!(
        core.network_ports(),
        NetworkPorts {
            sync: None,
            pairing: None,
            policy: PortPolicy::Range(range.clone()),
        }
    );
    core.create_new_dataset().await.unwrap();
    core.create_collection("Food".into(), String::new())
        .await
        .unwrap();
    assert!(core.retry_networking().await.is_err());
    core.shutdown().await.unwrap();
    drop(core);

    // One free port is not enough: sync takes it and pairing finds nothing
    // above it, so the whole stack stays deferred.
    held.pop();
    let core = open(dir.path(), 43, range.clone()).await;
    assert!(matches!(
        core.networking_deferred(),
        Some(NetworkingDeferredReason::PortsExhausted { .. })
    ));
    assert_eq!(core.network_addr(), None);
    core.shutdown().await.unwrap();
    drop(core);

    held.clear();
    let core = open(dir.path(), 43, range.clone()).await;
    assert_eq!(core.networking_deferred(), None);
    let ports = core.network_ports();
    assert!(range.contains(&ports.sync.unwrap()));
    assert!(range.contains(&ports.pairing.unwrap()));
    assert!(ports.sync < ports.pairing);
    core.shutdown().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_bind_failure_other_than_a_busy_port_fails_the_open() {
    let (range, held) = free_range(2);
    drop(held);
    let dir = tempfile::tempdir().unwrap();
    let error = open_on(dir.path(), 44, "192.0.2.1:0", range)
        .await
        .expect_err("an unassignable address must fail the open");
    assert!(matches!(error, app_core::AppError::Network(_)), "{error}");
}
