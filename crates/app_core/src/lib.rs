#![forbid(unsafe_code)]

pub mod adapters;
pub mod application;
pub mod control;
pub mod discovery;
pub mod domain;
pub mod error;
pub mod events;
pub mod identity;
pub mod pairing;
pub mod pairing_manager;
pub mod pairing_transport;
pub mod ports;
pub mod projection;
pub mod quinn_transport;
pub mod routing;
#[doc(hidden)]
pub mod test_support;

pub use application::{AppCore, AppCoreConfig};
pub use control::{
    DiscoveryGroupMetadata, LocalIdentityRecord, PairingJournalRecord, PairingJournalStage,
    PeerConnectionMetadata, PeerTrustRecord, TrustState, TrustedDeviceRecord,
};
pub use discovery::{
    Clock, DiscoveredEndpoint, DiscoveryAdvertisement, DiscoveryError, DiscoveryEvent,
    DiscoveryGroupSecret, DiscoveryProvider, DiscoveryScope, FakeDiscoveryProvider, ManualClock,
    MdnsDiscovery, PairingInstanceId, group_routing_token, group_service_selector,
    match_group_endpoint,
};
pub use domain::{
    Category, CategoryId, CategoryView, CreateCategory, CreateTransaction, FinanceCommand,
    FinanceSnapshot, Transaction, TransactionFilter, TransactionId, TransactionView,
    UpdateCategory, UpdateTransaction,
};
pub use error::{AppError, BootstrapError, DomainError, ProjectionError, Result};
pub use events::{
    ApplicationState, DataChanged, DomainKind, ErrorEvent, ProjectionState, TransientEvent,
};
pub use identity::{
    DeviceId, DeviceIdentity, IdentityError, InMemorySecureKeyStore, LinuxSecretServiceKeyStore,
    PrivateDeviceKey, PublicDeviceKey, SecureKeyStore, SecureStoreError, UnavailableSecureKeyStore,
};
pub use pairing::{
    PAIRING_ALPN, PairingCandidate, PairingDecision, PairingDecisionKind, PairingError,
    PairingEvent, PairingHello, PairingInput, PairingKeys, PairingMessage, PairingRole,
    PairingSessionId, PairingState, ProvisioningData, ProvisioningEnvelope, RootCompatibility,
    RootState, canonical_transcript, derive_pairing_keys, open_provisioning, pairing_session_id,
    protect_provisioning, reduce_pairing, root_compatibility, sign_commit_ack, sign_decision,
    verify_commit_ack, verify_decision,
};
pub use pairing_manager::{NormalDiscoveryEvent, PairingCommitPlan, PairingManager};
pub use pairing_transport::{PairingConnection, PairingStream, PairingTransport};
pub use projection::{AggregateView, ProjectionCheckpoint};
pub use quinn_transport::{
    MemoryTrustResolver, QuinnTransport, QuinnTransportConfig, QuinnTransportError, SYNC_ALPN,
    TlsIdentity, TrustResolver, extract_public_key,
};
pub use routing::{
    ConnectionDirection, ConnectionFailure, ConnectionManager, EndpointRegistry, EndpointSource,
    NetworkEndpoint, PeerConnectionState, PeerConnector, SessionCandidate, SyncStatus,
    aggregate_sync_status, choose_session, is_preferred_initiator, rank_endpoints,
};
