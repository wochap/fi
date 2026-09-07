//! Permanent installation identity and secure-key storage boundaries.

use std::{fmt, str::FromStr, sync::Mutex};

use async_trait::async_trait;
use ed25519_dalek::{SigningKey, VerifyingKey};
use rand_core::OsRng;
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use thiserror::Error;
use zeroize::Zeroizing;

use crate::discovery::DiscoveryGroupSecret;

const DEVICE_ID_DOMAIN: &[u8] = b"fi-device-id-v1";

#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct DeviceId([u8; 32]);

impl DeviceId {
    #[must_use]
    pub fn from_public_key(public_key: &[u8; 32]) -> Self {
        let mut digest = Sha256::new();
        digest.update(DEVICE_ID_DOMAIN);
        digest.update(public_key);
        Self(digest.finalize().into())
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    #[must_use]
    pub fn constant_time_eq(&self, other: &Self) -> bool {
        bool::from(self.0.ct_eq(&other.0))
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, formatter)
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&hex::encode(self.0))
    }
}

impl FromStr for DeviceId {
    type Err = IdentityError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        if value.len() != 64 || value.bytes().any(|byte| byte.is_ascii_uppercase()) {
            return Err(IdentityError::MalformedDeviceId);
        }
        let bytes = hex::decode(value).map_err(|_| IdentityError::MalformedDeviceId)?;
        let bytes: [u8; 32] = bytes
            .try_into()
            .map_err(|_| IdentityError::MalformedDeviceId)?;
        Ok(Self(bytes))
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct PublicDeviceKey([u8; 32]);

impl PublicDeviceKey {
    pub fn from_bytes(bytes: [u8; 32]) -> Result<Self, IdentityError> {
        VerifyingKey::from_bytes(&bytes).map_err(|_| IdentityError::MalformedPublicKey)?;
        Ok(Self(bytes))
    }

    #[must_use]
    pub const fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    #[must_use]
    pub fn constant_time_eq(&self, other: &Self) -> bool {
        bool::from(self.0.ct_eq(&other.0))
    }
}

pub struct PrivateDeviceKey(Zeroizing<[u8; 32]>);

impl PrivateDeviceKey {
    pub fn from_seed(seed: &[u8]) -> Result<Self, IdentityError> {
        let seed: [u8; 32] = seed
            .try_into()
            .map_err(|_| IdentityError::MalformedPrivateKey)?;
        Ok(Self(Zeroizing::new(seed)))
    }

    #[must_use]
    pub fn generate() -> Self {
        Self(Zeroizing::new(SigningKey::generate(&mut OsRng).to_bytes()))
    }

    #[must_use]
    pub fn public_key(&self) -> PublicDeviceKey {
        PublicDeviceKey(SigningKey::from_bytes(&self.0).verifying_key().to_bytes())
    }

    pub(crate) fn signing_key(&self) -> SigningKey {
        SigningKey::from_bytes(&self.0)
    }

    pub(crate) fn expose_seed(&self) -> &[u8; 32] {
        &self.0
    }
}

impl fmt::Debug for PrivateDeviceKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PrivateDeviceKey([REDACTED])")
    }
}

#[derive(Debug)]
pub struct DeviceIdentity {
    id: DeviceId,
    public_key: PublicDeviceKey,
    private_key: PrivateDeviceKey,
}

impl DeviceIdentity {
    pub async fn load_or_create(store: &dyn SecureKeyStore) -> Result<Self, IdentityError> {
        let private_key = store.load_or_create_device_key().await?;
        let public_key = private_key.public_key();
        Ok(Self {
            id: DeviceId::from_public_key(public_key.as_bytes()),
            public_key,
            private_key,
        })
    }

    #[must_use]
    pub const fn id(&self) -> DeviceId {
        self.id
    }

    #[must_use]
    pub const fn public_key(&self) -> PublicDeviceKey {
        self.public_key
    }

    pub(crate) fn private_key(&self) -> &PrivateDeviceKey {
        &self.private_key
    }
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum SecureStoreError {
    #[error("secure key store is locked")]
    Locked,
    #[error("secure key store is unavailable: {0}")]
    Unavailable(String),
    #[error("secure key store contains malformed device key material")]
    MalformedKey,
    #[error("secure key store operation failed: {0}")]
    Operation(String),
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum IdentityError {
    #[error(transparent)]
    SecureStore(#[from] SecureStoreError),
    #[error("device id is not canonical lowercase SHA-256")]
    MalformedDeviceId,
    #[error("device public key is malformed")]
    MalformedPublicKey,
    #[error("device private key is malformed")]
    MalformedPrivateKey,
}

#[async_trait]
pub trait SecureKeyStore: Send + Sync + 'static {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError>;
    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError>;
    async fn store_discovery_group_secret(
        &self,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError>;
    async fn load_previous_discovery_group_secret(
        &self,
    ) -> Result<Option<(u64, DiscoveryGroupSecret)>, SecureStoreError> {
        Ok(None)
    }
    async fn store_previous_discovery_group_secret(
        &self,
        _epoch: u64,
        _secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        Err(SecureStoreError::Unavailable(
            "previous discovery-secret retention is unavailable".into(),
        ))
    }
    async fn remove_previous_discovery_group_secret(&self) -> Result<(), SecureStoreError> {
        Ok(())
    }
}

/// Linux adapter backed only by the desktop session's Secret Service.
#[derive(Clone, Debug)]
pub struct LinuxSecretServiceKeyStore {
    application_id: String,
}

impl LinuxSecretServiceKeyStore {
    #[must_use]
    pub fn new(application_id: impl Into<String>) -> Self {
        Self {
            application_id: application_id.into(),
        }
    }
}

#[cfg(target_os = "linux")]
#[async_trait]
impl SecureKeyStore for LinuxSecretServiceKeyStore {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError> {
        use secret_service::{EncryptionType, SecretService};
        use std::collections::HashMap;

        fn map_error(error: secret_service::Error) -> SecureStoreError {
            match error {
                secret_service::Error::Locked | secret_service::Error::Prompt => {
                    SecureStoreError::Locked
                }
                secret_service::Error::Unavailable => SecureStoreError::Unavailable(
                    "no Secret Service provider is available in this desktop session".into(),
                ),
                other => SecureStoreError::Operation(other.to_string()),
            }
        }

        let service = SecretService::connect(EncryptionType::Dh)
            .await
            .map_err(map_error)?;
        let collection = service.get_default_collection().await.map_err(map_error)?;
        collection.ensure_unlocked().await.map_err(map_error)?;
        let attributes = HashMap::from([
            ("application", self.application_id.as_str()),
            ("kind", "ed25519-device-seed-v1"),
        ]);
        let items = collection
            .search_items(attributes.clone())
            .await
            .map_err(map_error)?;
        if let Some(item) = items.first() {
            let secret = Zeroizing::new(item.get_secret().await.map_err(map_error)?);
            return PrivateDeviceKey::from_seed(&secret)
                .map_err(|_| SecureStoreError::MalformedKey);
        }
        let generated = PrivateDeviceKey::generate();
        collection
            .create_item(
                "Fi device identity",
                attributes,
                generated.expose_seed(),
                true,
                "application/octet-stream",
            )
            .await
            .map_err(map_error)?;
        Ok(generated)
    }

    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError> {
        use secret_service::{EncryptionType, SecretService};
        use std::collections::HashMap;

        let map_error = |error: secret_service::Error| match error {
            secret_service::Error::Locked | secret_service::Error::Prompt => {
                SecureStoreError::Locked
            }
            secret_service::Error::Unavailable => SecureStoreError::Unavailable(
                "no Secret Service provider is available in this desktop session".into(),
            ),
            other => SecureStoreError::Operation(other.to_string()),
        };
        let service = SecretService::connect(EncryptionType::Dh)
            .await
            .map_err(map_error)?;
        let collection = service.get_default_collection().await.map_err(map_error)?;
        collection.ensure_unlocked().await.map_err(map_error)?;
        let attributes = HashMap::from([
            ("application", self.application_id.as_str()),
            ("kind", "discovery-group-secret-v1"),
        ]);
        let items = collection
            .search_items(attributes)
            .await
            .map_err(map_error)?;
        let Some(item) = items.first() else {
            return Ok(None);
        };
        let secret = Zeroizing::new(item.get_secret().await.map_err(map_error)?);
        let bytes: [u8; 32] = secret
            .as_slice()
            .try_into()
            .map_err(|_| SecureStoreError::MalformedKey)?;
        Ok(Some(DiscoveryGroupSecret::from_bytes(bytes)))
    }

    async fn store_discovery_group_secret(
        &self,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        use secret_service::{EncryptionType, SecretService};
        use std::collections::HashMap;

        let map_error = |error: secret_service::Error| match error {
            secret_service::Error::Locked | secret_service::Error::Prompt => {
                SecureStoreError::Locked
            }
            secret_service::Error::Unavailable => SecureStoreError::Unavailable(
                "no Secret Service provider is available in this desktop session".into(),
            ),
            other => SecureStoreError::Operation(other.to_string()),
        };
        let service = SecretService::connect(EncryptionType::Dh)
            .await
            .map_err(map_error)?;
        let collection = service.get_default_collection().await.map_err(map_error)?;
        collection.ensure_unlocked().await.map_err(map_error)?;
        let attributes = HashMap::from([
            ("application", self.application_id.as_str()),
            ("kind", "discovery-group-secret-v1"),
        ]);
        collection
            .create_item(
                "Fi discovery group",
                attributes,
                secret.expose(),
                true,
                "application/octet-stream",
            )
            .await
            .map_err(map_error)?;
        Ok(())
    }
}

#[cfg(not(target_os = "linux"))]
#[async_trait]
impl SecureKeyStore for LinuxSecretServiceKeyStore {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError> {
        Err(SecureStoreError::Unavailable(
            "Linux Secret Service is unavailable on this platform".into(),
        ))
    }
    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError> {
        Err(SecureStoreError::Unavailable(
            "Linux Secret Service is unavailable on this platform".into(),
        ))
    }
    async fn store_discovery_group_secret(
        &self,
        _secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        Err(SecureStoreError::Unavailable(
            "Linux Secret Service is unavailable on this platform".into(),
        ))
    }
}

/// Deterministic adapter for tests. It never writes key material to disk.
#[derive(Debug)]
pub struct InMemorySecureKeyStore {
    seed: Mutex<Option<[u8; 32]>>,
    discovery_secret: Mutex<Option<[u8; 32]>>,
    previous_discovery_secret: Mutex<Option<(u64, [u8; 32])>>,
}

impl InMemorySecureKeyStore {
    #[must_use]
    pub const fn empty() -> Self {
        Self {
            seed: Mutex::new(None),
            discovery_secret: Mutex::new(None),
            previous_discovery_secret: Mutex::new(None),
        }
    }

    #[must_use]
    pub const fn seeded(seed: [u8; 32]) -> Self {
        Self {
            seed: Mutex::new(Some(seed)),
            discovery_secret: Mutex::new(None),
            previous_discovery_secret: Mutex::new(None),
        }
    }
}

impl Default for InMemorySecureKeyStore {
    fn default() -> Self {
        Self::empty()
    }
}

#[async_trait]
impl SecureKeyStore for InMemorySecureKeyStore {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError> {
        let mut stored = self
            .seed
            .lock()
            .map_err(|_| SecureStoreError::Operation("in-memory key lock poisoned".into()))?;
        let seed = *stored.get_or_insert_with(|| *PrivateDeviceKey::generate().expose_seed());
        PrivateDeviceKey::from_seed(&seed).map_err(|_| SecureStoreError::MalformedKey)
    }

    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError> {
        let secret = *self
            .discovery_secret
            .lock()
            .map_err(|_| SecureStoreError::Operation("in-memory discovery lock poisoned".into()))?;
        Ok(secret.map(DiscoveryGroupSecret::from_bytes))
    }

    async fn store_discovery_group_secret(
        &self,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        *self.discovery_secret.lock().map_err(|_| {
            SecureStoreError::Operation("in-memory discovery lock poisoned".into())
        })? = Some(*secret.expose());
        Ok(())
    }

    async fn load_previous_discovery_group_secret(
        &self,
    ) -> Result<Option<(u64, DiscoveryGroupSecret)>, SecureStoreError> {
        let stored = *self.previous_discovery_secret.lock().map_err(|_| {
            SecureStoreError::Operation("in-memory previous discovery lock poisoned".into())
        })?;
        Ok(stored.map(|(epoch, bytes)| (epoch, DiscoveryGroupSecret::from_bytes(bytes))))
    }

    async fn store_previous_discovery_group_secret(
        &self,
        epoch: u64,
        secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        *self.previous_discovery_secret.lock().map_err(|_| {
            SecureStoreError::Operation("in-memory previous discovery lock poisoned".into())
        })? = Some((epoch, *secret.expose()));
        Ok(())
    }

    async fn remove_previous_discovery_group_secret(&self) -> Result<(), SecureStoreError> {
        *self.previous_discovery_secret.lock().map_err(|_| {
            SecureStoreError::Operation("in-memory previous discovery lock poisoned".into())
        })? = None;
        Ok(())
    }
}

/// Adapter useful for deterministic failure and lifecycle tests.
#[derive(Clone, Debug)]
pub struct UnavailableSecureKeyStore(pub SecureStoreError);

#[async_trait]
impl SecureKeyStore for UnavailableSecureKeyStore {
    async fn load_or_create_device_key(&self) -> Result<PrivateDeviceKey, SecureStoreError> {
        Err(self.0.clone())
    }
    async fn load_discovery_group_secret(
        &self,
    ) -> Result<Option<DiscoveryGroupSecret>, SecureStoreError> {
        Err(self.0.clone())
    }
    async fn store_discovery_group_secret(
        &self,
        _secret: &DiscoveryGroupSecret,
    ) -> Result<(), SecureStoreError> {
        Err(self.0.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn first_creation_and_restart_are_stable() {
        let store = InMemorySecureKeyStore::empty();
        let first = DeviceIdentity::load_or_create(&store).await.unwrap();
        let second = DeviceIdentity::load_or_create(&store).await.unwrap();
        assert_eq!(first.id(), second.id());
        assert_eq!(first.public_key(), second.public_key());
        assert!(store.load_discovery_group_secret().await.unwrap().is_none());
        let group = DiscoveryGroupSecret::from_bytes([8; 32]);
        store.store_discovery_group_secret(&group).await.unwrap();
        assert_eq!(
            store.load_discovery_group_secret().await.unwrap(),
            Some(group)
        );
    }

    #[test]
    fn fingerprint_has_a_stable_vector() {
        let public = PublicDeviceKey::from_bytes([
            0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7, 0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64,
            0x07, 0x3a, 0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25, 0xaf, 0x02, 0x1a, 0x68,
            0xf7, 0x07, 0x51, 0x1a,
        ])
        .unwrap();
        assert_eq!(
            DeviceId::from_public_key(public.as_bytes()).to_string(),
            "502396255fcdc2a8a3d9f6ac909a25bf1f74f44f20ef73eafa07eade7d3f25ab"
        );
    }

    #[test]
    fn malformed_keys_and_noncanonical_ids_are_rejected() {
        assert_eq!(
            PrivateDeviceKey::from_seed(&[1; 31]).unwrap_err(),
            IdentityError::MalformedPrivateKey
        );
        assert!(
            "AA00000000000000000000000000000000000000000000000000000000000000"
                .parse::<DeviceId>()
                .is_err()
        );
    }

    #[tokio::test]
    async fn unavailable_storage_is_typed_and_secret_formatting_is_redacted() {
        let failure =
            UnavailableSecureKeyStore(SecureStoreError::Unavailable("no session bus".into()));
        let error = DeviceIdentity::load_or_create(&failure).await.unwrap_err();
        assert!(matches!(
            error,
            IdentityError::SecureStore(SecureStoreError::Unavailable(_))
        ));
        let key = PrivateDeviceKey::from_seed(&[0x5a; 32]).unwrap();
        let formatted = format!("{key:?}");
        assert_eq!(formatted, "PrivateDeviceKey([REDACTED])");
        assert!(!formatted.contains("5a"));
    }
}
