//! Repository protocol version 1.

use automerge::sync::Message as SyncMessage;
use bytes::{Buf, BufMut, Bytes, BytesMut};

use crate::{DocumentId, error::ProtocolError};

pub const PROTOCOL_VERSION: u8 = 1;
pub const MAX_BODY_LEN: usize = 8 * 1024 * 1024;
const MAGIC: &[u8; 4] = b"FIRP";
const HEADER_LEN: usize = 8;

/// Bootstrap state carried in Hello and live state updates.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapMode {
    Uninitialized,
    Joining(DocumentId),
    Ready(DocumentId),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Message {
    Hello(BootstrapMode),
    BootstrapState(BootstrapMode),
    Inventory(Vec<DocumentId>),
    Announce(DocumentId),
    Sync {
        document: DocumentId,
        message: SyncMessage,
    },
}

impl Message {
    const fn kind(&self) -> u8 {
        match self {
            Self::Hello(_) => 1,
            Self::BootstrapState(_) => 2,
            Self::Inventory(_) => 3,
            Self::Announce(_) => 4,
            Self::Sync { .. } => 5,
        }
    }
}

#[derive(Debug, Default)]
pub struct Codec;

impl Codec {
    pub fn encode(message: Message) -> Result<Bytes, ProtocolError> {
        let kind = message.kind();
        let mut payload = BytesMut::new();
        match message {
            Message::Hello(mode) | Message::BootstrapState(mode) => {
                encode_bootstrap(&mut payload, mode)
            }
            Message::Inventory(ids) => {
                let count = u32::try_from(ids.len()).map_err(|_| ProtocolError::FrameTooLarge {
                    actual: usize::MAX,
                    maximum: MAX_BODY_LEN,
                })?;
                payload.put_u32(count);
                for id in ids {
                    payload.extend_from_slice(&id.to_bytes());
                }
            }
            Message::Announce(id) => payload.extend_from_slice(&id.to_bytes()),
            Message::Sync { document, message } => {
                payload.extend_from_slice(&document.to_bytes());
                payload.extend_from_slice(&message.encode());
            }
        }
        let body_len =
            HEADER_LEN
                .checked_add(payload.len())
                .ok_or(ProtocolError::FrameTooLarge {
                    actual: usize::MAX,
                    maximum: MAX_BODY_LEN,
                })?;
        if body_len > MAX_BODY_LEN {
            return Err(ProtocolError::FrameTooLarge {
                actual: body_len,
                maximum: MAX_BODY_LEN,
            });
        }
        let mut frame = BytesMut::with_capacity(4 + body_len);
        frame.put_u32(body_len as u32);
        frame.extend_from_slice(MAGIC);
        frame.put_u8(PROTOCOL_VERSION);
        frame.put_u8(kind);
        frame.put_u16(0);
        frame.extend_from_slice(&payload);
        Ok(frame.freeze())
    }

    /// Decodes one frame, returning `None` without consuming partial input.
    pub fn decode(source: &mut BytesMut) -> Result<Option<Message>, ProtocolError> {
        if source.len() < 4 {
            return Ok(None);
        }
        let body_len = u32::from_be_bytes(source[..4].try_into().expect("four bytes")) as usize;
        if body_len > MAX_BODY_LEN {
            return Err(ProtocolError::FrameTooLarge {
                actual: body_len,
                maximum: MAX_BODY_LEN,
            });
        }
        if body_len < HEADER_LEN {
            return Err(ProtocolError::InvalidLength);
        }
        let total = 4usize
            .checked_add(body_len)
            .ok_or(ProtocolError::InvalidLength)?;
        if source.len() < total {
            return Ok(None);
        }
        let mut frame = source.split_to(total);
        frame.advance(4);
        Self::decode_body(&frame).map(Some)
    }

    /// Decodes a transport payload that must contain exactly one complete frame.
    pub fn decode_exact(bytes: &[u8]) -> Result<Message, ProtocolError> {
        let mut input = BytesMut::from(bytes);
        let message = Self::decode(&mut input)?.ok_or(ProtocolError::InvalidLength)?;
        if !input.is_empty() {
            return Err(ProtocolError::InvalidLength);
        }
        Ok(message)
    }

    fn decode_body(body: &[u8]) -> Result<Message, ProtocolError> {
        if &body[..4] != MAGIC {
            return Err(ProtocolError::BadMagic);
        }
        if body[4] != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(body[4]));
        }
        let kind = body[5];
        let flags = u16::from_be_bytes([body[6], body[7]]);
        if flags != 0 {
            return Err(ProtocolError::ReservedFlags(flags));
        }
        let payload = &body[HEADER_LEN..];
        match kind {
            1 => Ok(Message::Hello(decode_bootstrap(payload)?)),
            2 => Ok(Message::BootstrapState(decode_bootstrap(payload)?)),
            3 => decode_inventory(payload).map(Message::Inventory),
            4 => Ok(Message::Announce(exact_id(payload)?)),
            5 => {
                if payload.len() <= 16 {
                    return Err(ProtocolError::InvalidLength);
                }
                let document =
                    DocumentId::from_bytes(payload[..16].try_into().expect("sixteen bytes"));
                let encoded = &payload[16..];
                let message =
                    SyncMessage::decode(encoded).map_err(|_| ProtocolError::InvalidSyncPayload)?;
                if message.clone().encode() != encoded {
                    return Err(ProtocolError::InvalidSyncPayload);
                }
                Ok(Message::Sync { document, message })
            }
            other => Err(ProtocolError::UnknownKind(other)),
        }
    }
}

fn encode_bootstrap(output: &mut BytesMut, mode: BootstrapMode) {
    match mode {
        BootstrapMode::Uninitialized => output.put_u8(0),
        BootstrapMode::Joining(root) => {
            output.put_u8(1);
            output.extend_from_slice(&root.to_bytes());
        }
        BootstrapMode::Ready(root) => {
            output.put_u8(2);
            output.extend_from_slice(&root.to_bytes());
        }
    }
}

fn decode_bootstrap(payload: &[u8]) -> Result<BootstrapMode, ProtocolError> {
    match payload {
        [0] => Ok(BootstrapMode::Uninitialized),
        [1, rest @ ..] if rest.len() == 16 => Ok(BootstrapMode::Joining(DocumentId::from_bytes(
            rest.try_into().expect("sixteen bytes"),
        ))),
        [2, rest @ ..] if rest.len() == 16 => Ok(BootstrapMode::Ready(DocumentId::from_bytes(
            rest.try_into().expect("sixteen bytes"),
        ))),
        [mode, ..] if *mode > 2 => Err(ProtocolError::UnknownBootstrapMode(*mode)),
        _ => Err(ProtocolError::InvalidLength),
    }
}

fn exact_id(payload: &[u8]) -> Result<DocumentId, ProtocolError> {
    let bytes: [u8; 16] = payload
        .try_into()
        .map_err(|_| ProtocolError::InvalidLength)?;
    Ok(DocumentId::from_bytes(bytes))
}

fn decode_inventory(payload: &[u8]) -> Result<Vec<DocumentId>, ProtocolError> {
    if payload.len() < 4 {
        return Err(ProtocolError::InvalidLength);
    }
    let count = u32::from_be_bytes(payload[..4].try_into().expect("four bytes")) as usize;
    let id_bytes = count
        .checked_mul(16)
        .ok_or(ProtocolError::InvalidInventoryCount)?;
    if payload.len().checked_sub(4) != Some(id_bytes) {
        return Err(ProtocolError::InvalidInventoryCount);
    }
    Ok(payload[4..]
        .chunks_exact(16)
        .map(|chunk| DocumentId::from_bytes(chunk.try_into().expect("sixteen bytes")))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use automerge::{
        Automerge,
        sync::{State, SyncDoc},
    };

    fn id() -> DocumentId {
        "550e8400-e29b-41d4-a716-446655440000".parse().unwrap()
    }
    fn sync_message() -> SyncMessage {
        Automerge::new()
            .generate_sync_message(&mut State::new())
            .unwrap()
    }

    #[test]
    fn every_message_round_trips() {
        let values = vec![
            Message::Hello(BootstrapMode::Uninitialized),
            Message::BootstrapState(BootstrapMode::Joining(id())),
            Message::Hello(BootstrapMode::Ready(id())),
            Message::Inventory(vec![id()]),
            Message::Announce(id()),
            Message::Sync {
                document: id(),
                message: sync_message(),
            },
        ];
        for value in values {
            let encoded = Codec::encode(value.clone()).unwrap();
            assert_eq!(Codec::decode_exact(&encoded).unwrap(), value);
        }
    }

    #[test]
    fn partial_input_is_not_consumed_and_concatenated_frames_decode() {
        let a = Codec::encode(Message::Hello(BootstrapMode::Uninitialized)).unwrap();
        let b = Codec::encode(Message::Announce(id())).unwrap();
        for boundary in 0..a.len() {
            let mut partial = BytesMut::from(&a[..boundary]);
            assert_eq!(Codec::decode(&mut partial).unwrap(), None);
            assert_eq!(partial.as_ref(), &a[..boundary]);
        }
        let mut both = BytesMut::from([a.as_ref(), b.as_ref()].concat().as_slice());
        assert_eq!(
            Codec::decode(&mut both).unwrap(),
            Some(Message::Hello(BootstrapMode::Uninitialized))
        );
        assert_eq!(
            Codec::decode(&mut both).unwrap(),
            Some(Message::Announce(id()))
        );
        assert!(both.is_empty());
    }

    #[test]
    fn hello_golden_bytes_are_stable() {
        assert_eq!(
            Codec::encode(Message::Hello(BootstrapMode::Uninitialized))
                .unwrap()
                .as_ref(),
            b"\0\0\0\x09FIRP\x01\x01\0\0\0"
        );
    }

    #[test]
    fn malformed_headers_and_payloads_are_rejected() {
        let base = Codec::encode(Message::Hello(BootstrapMode::Uninitialized)).unwrap();
        for (index, value, expected) in [
            (4, b'X', ProtocolError::BadMagic),
            (8, 2, ProtocolError::UnsupportedVersion(2)),
            (9, 99, ProtocolError::UnknownKind(99)),
            (10, 1, ProtocolError::ReservedFlags(256)),
        ] {
            let mut broken = base.to_vec();
            broken[index] = value;
            assert_eq!(Codec::decode_exact(&broken).unwrap_err(), expected);
        }
        let mut oversized = BytesMut::new();
        oversized.put_u32((MAX_BODY_LEN + 1) as u32);
        assert!(matches!(
            Codec::decode(&mut oversized),
            Err(ProtocolError::FrameTooLarge { .. })
        ));
        let invalid_sync = frame(5, &[&id().to_bytes()[..], &[0xff]].concat());
        assert_eq!(
            Codec::decode_exact(&invalid_sync).unwrap_err(),
            ProtocolError::InvalidSyncPayload
        );
        let inventory = frame(3, &[0, 0, 0, 1]);
        assert_eq!(
            Codec::decode_exact(&inventory).unwrap_err(),
            ProtocolError::InvalidInventoryCount
        );
        assert_eq!(
            Codec::decode_exact(&frame(1, &[9])).unwrap_err(),
            ProtocolError::UnknownBootstrapMode(9)
        );
        assert_eq!(
            Codec::decode_exact(&frame(4, &[0; 17])).unwrap_err(),
            ProtocolError::InvalidLength
        );
        let mut truncated = base.to_vec();
        truncated.pop();
        assert_eq!(
            Codec::decode_exact(&truncated).unwrap_err(),
            ProtocolError::InvalidLength
        );
    }

    #[test]
    fn largest_aligned_inventory_below_the_limit_is_legal() {
        let count = (MAX_BODY_LEN - HEADER_LEN - 4) / 16;
        let bytes = Codec::encode(Message::Inventory(vec![id(); count])).unwrap();
        assert!(bytes.len() - 4 <= MAX_BODY_LEN);
        assert_eq!(
            Codec::decode_exact(&bytes).unwrap(),
            Message::Inventory(vec![id(); count])
        );
    }

    fn frame(kind: u8, payload: &[u8]) -> Bytes {
        let mut bytes = BytesMut::new();
        bytes.put_u32((HEADER_LEN + payload.len()) as u32);
        bytes.extend_from_slice(MAGIC);
        bytes.put_u8(1);
        bytes.put_u8(kind);
        bytes.put_u16(0);
        bytes.extend_from_slice(payload);
        bytes.freeze()
    }
}
