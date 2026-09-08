#![forbid(unsafe_code)]

pub mod adapters;
pub mod application;
pub mod control;
pub mod discovery;
pub mod discovery_control;
pub mod error;
pub mod events;
pub mod generic;
pub mod hlc;
pub mod identity;
pub mod pairing;
pub mod pairing_manager;
pub mod pairing_transport;
pub mod ports;
pub mod projection;
pub mod query;
pub mod quinn_transport;
pub mod records;
pub mod routing;
pub mod schema;
#[doc(hidden)]
pub mod test_support;
pub mod values;

pub use application::{AppCore, AppCoreConfig};
pub use control::{
    DiscoveryGroupMetadata, DiscoveryRotationJournal, DiscoveryRotationStage, LocalIdentityRecord,
    PairingJournalRecord, PairingJournalStage, PeerConnectionMetadata, PeerTrustRecord, TrustState,
    TrustedDeviceRecord,
};
pub use discovery::{
    Clock, DiscoveredEndpoint, DiscoveryAdvertisement, DiscoveryError, DiscoveryEvent,
    DiscoveryGroupSecret, DiscoveryProvider, DiscoveryScope, FakeDiscoveryProvider, ManualClock,
    MdnsDiscovery, PairingInstanceId, group_routing_token, group_service_selector,
    match_group_endpoint,
};
pub use discovery_control::{
    DISCOVERY_ACK_SIZE, DISCOVERY_CONTROL_VERSION, DISCOVERY_UPDATE_SIZE, DiscoveryControlError,
    DiscoverySecretAck, DiscoverySecretUpdate, authorize_peer, decode_ack, decode_update,
    encode_ack, encode_update,
};
pub use error::{AppError, BootstrapError, DomainError, ProjectionError, Result};
pub use events::{
    ApplicationState, DataChanged, DomainKind, ErrorEvent, ProjectionState, TransientEvent,
};
pub use generic::{
    APP_SCHEMA_VERSION, CollectionView, GenericCommand, GenericDiagnostic, GenericSnapshot,
    RecordView, apply_generic_command, decode_generic, initialize_generic,
};
pub use hlc::{HlcError, HlcNodeId, HlcStamp, HybridLogicalClock, SystemWallTime, WallTime};
pub use identity::{
    DeviceId, DeviceIdentity, IdentityError, InMemorySecureKeyStore, LinuxSecretServiceKeyStore,
    PrivateDeviceKey, PublicDeviceKey, SecureKeyStore, SecureStoreError, UnavailableSecureKeyStore,
};
pub use pairing::{
    PAIRING_ALPN, PairingCandidate, PairingDecision, PairingDecisionKind, PairingError,
    PairingEvent, PairingHello, PairingInput, PairingKeys, PairingMessage, PairingRole,
    PairingSessionId, PairingState, ProvisioningData, ProvisioningEnvelope, RootCompatibility,
    RootState, SasCode, canonical_transcript, derive_pairing_keys, open_provisioning,
    pairing_session_id, protect_provisioning, reduce_pairing, root_compatibility, sign_commit_ack,
    sign_decision, verify_commit_ack, verify_decision,
};
pub use pairing_manager::{NormalDiscoveryEvent, PairingCommitPlan, PairingManager};
pub use pairing_transport::{PairingConnection, PairingStream, PairingTransport};
pub use projection::ProjectionCheckpoint;
pub use query::*;
pub use quinn_transport::{
    MemoryTrustResolver, QuinnTransport, QuinnTransportConfig, QuinnTransportError, SYNC_ALPN,
    TlsIdentity, TrustResolver, extract_public_key,
};
pub use records::{GenericRecord, RecordId, RecordValidationError, validate_record};
pub use routing::{
    ConnectionDirection, ConnectionFailure, ConnectionManager, EndpointRegistry, EndpointSource,
    NetworkEndpoint, PeerConnectionState, PeerConnector, SessionCandidate, SyncStatus,
    aggregate_sync_status, choose_session, is_preferred_initiator, rank_endpoints,
};
pub use schema::{
    CollectionSchema, CollectionSchemaId, DisplayMetadata, EnumOption, EnumOptionId,
    FieldDefinition, FieldId, FieldType, ValidationMetadata,
};
pub use values::{DecimalError, FieldValue, FixedDecimal};
