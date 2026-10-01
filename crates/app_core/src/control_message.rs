//! Typed frames on the authenticated per-session control channel.
//!
//! Every frame starts with one type byte: [`CONTROL_ROTATION`] carries a
//! discovery-secret rotation update unchanged, [`CONTROL_TAILNET_HINT`] carries
//! the sender's tailnet sync addresses.

use std::net::{Ipv4Addr, SocketAddrV4};

use crate::discovery::is_tailnet_address;

pub const CONTROL_ROTATION: u8 = 0x01;
pub const CONTROL_TAILNET_HINT: u8 = 0x02;
/// Reply to a tailnet hint, sent whether or not the hint decoded.
pub const TAILNET_HINT_ACK: [u8; 1] = [CONTROL_TAILNET_HINT];
/// Most addresses one hint may carry.
pub const MAX_TAILNET_HINT_ADDRESSES: usize = 2;

const HINT_ENTRY_SIZE: usize = 6;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ControlMessage<'a> {
    Rotation(&'a [u8]),
    TailnetHint(&'a [u8]),
    Unknown,
}

#[derive(Clone, Copy, Debug, thiserror::Error, Eq, PartialEq)]
pub enum TailnetHintError {
    #[error("tailnet hint lists too many addresses")]
    TooMany,
    #[error("tailnet hint length does not match its count")]
    Length,
}

/// Splits a control frame into its type and payload.
#[must_use]
pub fn parse_control(frame: &[u8]) -> ControlMessage<'_> {
    match frame.split_first() {
        Some((&CONTROL_ROTATION, payload)) => ControlMessage::Rotation(payload),
        Some((&CONTROL_TAILNET_HINT, payload)) => ControlMessage::TailnetHint(payload),
        _ => ControlMessage::Unknown,
    }
}

/// A rotation update framed for the control channel.
#[must_use]
pub fn rotation_frame(update: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(update.len() + 1);
    frame.push(CONTROL_ROTATION);
    frame.extend_from_slice(update);
    frame
}

/// A tailnet hint frame for at most [`MAX_TAILNET_HINT_ADDRESSES`] addresses;
/// extra addresses are dropped.
#[must_use]
pub fn tailnet_hint_frame(addresses: &[SocketAddrV4]) -> Vec<u8> {
    let addresses = &addresses[..addresses.len().min(MAX_TAILNET_HINT_ADDRESSES)];
    let mut frame = Vec::with_capacity(2 + addresses.len() * HINT_ENTRY_SIZE);
    frame.push(CONTROL_TAILNET_HINT);
    frame.push(addresses.len() as u8);
    for address in addresses {
        frame.extend_from_slice(&address.ip().octets());
        frame.extend_from_slice(&address.port().to_be_bytes());
    }
    frame
}

/// Decodes a tailnet hint payload (after the type byte), keeping only tailnet
/// addresses with a non-zero port.
pub fn decode_tailnet_hint(payload: &[u8]) -> Result<Vec<SocketAddrV4>, TailnetHintError> {
    let (&count, entries) = payload.split_first().ok_or(TailnetHintError::Length)?;
    let count = usize::from(count);
    if count > MAX_TAILNET_HINT_ADDRESSES {
        return Err(TailnetHintError::TooMany);
    }
    if entries.len() != count * HINT_ENTRY_SIZE {
        return Err(TailnetHintError::Length);
    }
    Ok(entries
        .chunks_exact(HINT_ENTRY_SIZE)
        .map(|entry| {
            SocketAddrV4::new(
                Ipv4Addr::new(entry[0], entry[1], entry[2], entry[3]),
                u16::from_be_bytes([entry[4], entry[5]]),
            )
        })
        .filter(|address| is_tailnet_address(*address.ip()) && address.port() != 0)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn address(text: &str) -> SocketAddrV4 {
        text.parse().unwrap()
    }

    #[test]
    fn hint_round_trips() {
        let addresses = [address("100.88.10.4:47380"), address("100.71.3.9:47381")];
        let frame = tailnet_hint_frame(&addresses);
        let ControlMessage::TailnetHint(payload) = parse_control(&frame) else {
            panic!("hint frame parses as a hint");
        };
        assert_eq!(decode_tailnet_hint(payload).unwrap(), addresses);
        assert_eq!(
            decode_tailnet_hint(&[0]).unwrap(),
            Vec::<SocketAddrV4>::new()
        );
    }

    #[test]
    fn hint_over_two_addresses_is_rejected() {
        let mut payload = vec![3];
        payload.extend_from_slice(&[100, 88, 10, 4, 0xb9, 0x14].repeat(3));
        assert_eq!(
            decode_tailnet_hint(&payload),
            Err(TailnetHintError::TooMany)
        );
        let three = [
            address("100.88.10.4:1"),
            address("100.88.10.5:1"),
            address("100.88.10.6:1"),
        ];
        let frame = tailnet_hint_frame(&three);
        assert_eq!(frame[1], 2, "the encoder caps the count");
    }

    #[test]
    fn truncated_hint_is_rejected() {
        let frame = tailnet_hint_frame(&[address("100.88.10.4:47380")]);
        let payload = &frame[1..];
        assert_eq!(
            decode_tailnet_hint(&payload[..payload.len() - 1]),
            Err(TailnetHintError::Length)
        );
        assert_eq!(decode_tailnet_hint(&[]), Err(TailnetHintError::Length));
        let mut trailing = payload.to_vec();
        trailing.push(0);
        assert_eq!(
            decode_tailnet_hint(&trailing),
            Err(TailnetHintError::Length)
        );
    }

    #[test]
    fn non_tailnet_entries_are_dropped_on_decode() {
        let frame = tailnet_hint_frame(&[address("100.88.10.4:47380"), address("8.8.8.8:47380")]);
        assert_eq!(
            decode_tailnet_hint(&frame[1..]).unwrap(),
            vec![address("100.88.10.4:47380")]
        );
    }

    #[test]
    fn frames_are_typed() {
        assert_eq!(
            parse_control(&rotation_frame(&[7, 8])),
            ControlMessage::Rotation(&[7, 8])
        );
        assert_eq!(parse_control(&[0x7f, 1]), ControlMessage::Unknown);
        assert_eq!(parse_control(&[]), ControlMessage::Unknown);
    }
}
