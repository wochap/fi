use std::{fmt, str::FromStr, sync::Arc};

use uuid::Uuid;

/// Stable identifier for an Automerge document.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct DocumentId(Uuid);

impl DocumentId {
    #[must_use]
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
    #[must_use]
    pub const fn from_bytes(bytes: [u8; 16]) -> Self {
        Self(Uuid::from_bytes(bytes))
    }
    #[must_use]
    pub const fn to_bytes(self) -> [u8; 16] {
        *self.0.as_bytes()
    }
}

impl Default for DocumentId {
    fn default() -> Self {
        Self::new()
    }
}
impl fmt::Display for DocumentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.hyphenated().fmt(f)
    }
}
impl FromStr for DocumentId {
    type Err = uuid::Error;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Uuid::parse_str(value).map(Self)
    }
}

/// Identity asserted by an authenticated transport session.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct PeerId(Arc<str>);

impl PeerId {
    #[must_use]
    pub fn new(value: impl Into<Arc<str>>) -> Self {
        Self(value.into())
    }
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl fmt::Display for PeerId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl From<&str> for PeerId {
    fn from(value: &str) -> Self {
        Self::new(value)
    }
}
impl From<String> for PeerId {
    fn from(value: String) -> Self {
        Self::new(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_id_is_canonical_and_exactly_sixteen_bytes() {
        let id: DocumentId = "550E8400-E29B-41D4-A716-446655440000".parse().unwrap();
        assert_eq!(id.to_string(), "550e8400-e29b-41d4-a716-446655440000");
        assert_eq!(DocumentId::from_bytes(id.to_bytes()), id);
        assert_eq!(id.to_bytes().len(), 16);
    }

    #[test]
    fn peer_id_clones_share_owned_text() {
        let peer = PeerId::from("device-a");
        assert_eq!(peer.clone(), peer);
        assert_eq!(peer.to_string(), "device-a");
    }
}
