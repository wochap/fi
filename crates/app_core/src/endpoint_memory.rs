//! Remembered peer endpoints and manual connect-by-address input.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};

use crate::routing::ConnectionFailure;

/// How long a remembered address stays a dial candidate after its last
/// successful session.
pub const REMEMBERED_ENDPOINT_TTL_MS: u64 = 14 * 24 * 60 * 60 * 1000;
/// Remembered addresses kept per peer; the oldest success is dropped first.
pub const REMEMBERED_ENDPOINTS_PER_PEER: usize = 3;
/// A remembered address younger than this is not rewritten.
pub const REMEMBER_WRITE_THROTTLE_MS: u64 = 5 * 60 * 1000;
/// Port used when a manually entered address has none. Equals
/// `*DEFAULT_SYNC_PORT_RANGE.start()`.
pub const DEFAULT_MANUAL_PORT: u16 = 47380;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ManualAddressError {
    Invalid,
}

/// Parses user input as an IPv4 socket address; a bare IPv4 address gets
/// [`DEFAULT_MANUAL_PORT`]. Host names, IPv6 and port 0 are invalid.
pub fn parse_manual_address(input: &str) -> Result<SocketAddr, ManualAddressError> {
    let input = input.trim();
    let address = if let Ok(address) = input.parse::<SocketAddrV4>() {
        address
    } else if let Ok(ip) = input.parse::<Ipv4Addr>() {
        SocketAddrV4::new(ip, DEFAULT_MANUAL_PORT)
    } else {
        return Err(ManualAddressError::Invalid);
    };
    if address.port() == 0 {
        return Err(ManualAddressError::Invalid);
    }
    Ok(SocketAddr::V4(address))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ManualConnectOutcome {
    Connected,
    InvalidAddress,
    NotLocalNetwork,
    Failed(ConnectionFailure),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_manual_port_is_the_first_sync_port() {
        assert_eq!(
            DEFAULT_MANUAL_PORT,
            *crate::application::DEFAULT_SYNC_PORT_RANGE.start()
        );
    }

    #[test]
    fn parses_ipv4_with_and_without_port() {
        assert_eq!(
            parse_manual_address("192.168.0.165"),
            Ok("192.168.0.165:47380".parse().unwrap())
        );
        assert_eq!(
            parse_manual_address("192.168.0.165:47381"),
            Ok("192.168.0.165:47381".parse().unwrap())
        );
        assert_eq!(
            parse_manual_address(" 10.0.0.2:47380 "),
            Ok("10.0.0.2:47380".parse().unwrap())
        );
    }

    #[test]
    fn rejects_everything_else() {
        for input in [
            "192.168.0",
            "phone.local",
            "192.168.0.165:70000",
            "192.168.0.165:0",
            "[fe80::1]:47380",
            "",
        ] {
            assert_eq!(
                parse_manual_address(input),
                Err(ManualAddressError::Invalid),
                "{input}"
            );
        }
    }
}
