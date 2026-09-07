#![forbid(unsafe_code)]

pub mod adapters;
pub mod application;
pub mod control;
pub mod domain;
pub mod error;
pub mod events;
pub mod identity;
pub mod ports;
pub mod projection;
pub mod quinn_transport;
pub mod routing;
#[doc(hidden)]
pub mod test_support;

pub use application::{AppCore, AppCoreConfig};
pub use control::{LocalIdentityRecord, PeerConnectionMetadata, PeerTrustRecord, TrustState};
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
