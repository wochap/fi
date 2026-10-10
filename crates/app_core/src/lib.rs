#![forbid(unsafe_code)]

pub mod adapters;
pub mod application;
pub mod control;
pub mod control_message;
pub mod device_name;
pub mod diagnostics;
pub mod discovery;
pub mod discovery_control;
pub mod duration;
pub mod endpoint_memory;
pub mod error;
pub mod events;
pub mod generic;
pub mod hlc;
pub mod identity;
pub mod import_export;
pub mod models;
pub mod option_edits;
pub mod pairing;
pub mod pairing_manager;
pub mod pairing_transport;
pub mod ports;
pub mod projection;
pub mod query;
pub mod quinn_transport;
pub mod records;
pub mod remap;
pub mod routing;
pub mod schema;
#[doc(hidden)]
pub mod test_support;
pub mod values;
pub mod view;
pub mod widget_registry;
pub mod widgets;

pub use application::{
    AppCore, AppCoreConfig, DEFAULT_SYNC_PORT_RANGE, LifecyclePolicy, NetworkPorts,
    NetworkingDeferredReason, PortPolicy, RevocationOutcome, reset_dataset,
};
pub use automerge_repo::{
    QuarantineReason, RecoveryOutcome, RecoveryReason, RecoveryRecord,
    error::BootstrapError as RepositoryBootstrapError,
};
pub use control::{
    DiscoveryGroupMetadata, DiscoveryRotationJournal, DiscoveryRotationStage, LocalIdentityRecord,
    NetworkPreferences, PairingJournalRecord, PairingJournalStage, PeerConnectionMetadata,
    PeerTrustRecord, RememberedEndpoint, ResetIntent, TrustState, TrustedDeviceRecord,
};
pub use device_name::{
    DeviceNameError, MAX_DEVICE_NAME_BYTES, generated_device_name, is_generated_device_name,
    normalize_device_name,
};
pub use discovery::{
    Clock, DiscoveredEndpoint, DiscoveryAdvertisement, DiscoveryError, DiscoveryEvent,
    DiscoveryGroupSecret, DiscoveryProvider, DiscoveryScope, FakeDiscoveryProvider, GroupRejection,
    ManualClock, MdnsDiscovery, PairingInstanceId, TailnetProbe, classify_group_endpoint,
    discovery_secret_fingerprint, group_routing_token, group_service_selector, is_tailnet_address,
    match_group_endpoint, tailnet_addresses,
};
pub use discovery_control::{
    DISCOVERY_ACK_SIZE, DISCOVERY_CONTROL_VERSION, DISCOVERY_UPDATE_SIZE, DiscoveryControlError,
    DiscoverySecretAck, DiscoverySecretUpdate, authorize_peer, decode_ack, decode_update,
    encode_ack, encode_update,
};
pub use endpoint_memory::{ManualAddressError, ManualConnectOutcome, parse_manual_address};
pub use error::{
    AppError, BootstrapError, DomainError, IssueCode, ProjectionError, Result, ValidationIssue,
    summarize_issues,
};
pub use events::{
    ApplicationState, DataChanged, DomainKind, ErrorEvent, ProjectionState, TransientEvent,
};
pub use generic::{
    APP_SCHEMA_VERSION, CollectionView, GenericCommand, GenericDiagnostic, GenericSnapshot,
    ImportItemError, RecordView, apply_generic_command, decode_generic, initialize_generic,
    validate_import,
};
pub use hlc::{HlcError, HlcNodeId, HlcStamp, HybridLogicalClock, SystemWallTime, WallTime};
pub use identity::{
    DeviceId, DeviceIdentity, IdentityError, InMemorySecureKeyStore, LinuxSecretServiceKeyStore,
    LockableSecureKeyStore, PlatformSecretPersistence, PlatformSecretWrite, PrivateDeviceKey,
    PublicDeviceKey, SecureKeyStore, SecureStoreError, UnavailableSecureKeyStore,
    WriteThroughSecureKeyStore,
};
pub use import_export::{
    CloneOutcome, ENVELOPE_FORMAT, ENVELOPE_VERSION, Envelope, ExportedCollection, ExportedRecord,
    ImportAbort, ImportOutcome, ImportedCollection, JsonExport, prepare_import,
};
pub use option_edits::{
    DraftTarget, DraftValue, PENDING_OPTION_PREFIX, PendingOption, ResolvedDraft, resolve_draft,
};
pub use pairing::{
    PAIRING_ALPN, PairingCandidate, PairingDecision, PairingDecisionKind, PairingError,
    PairingEvent, PairingHello, PairingInput, PairingKeys, PairingMessage, PairingRole,
    PairingSessionId, PairingState, ProvisioningData, ProvisioningEnvelope, RootCompatibility,
    RootState, SasCode, canonical_transcript, derive_pairing_keys, open_provisioning,
    pairing_session_id, protect_provisioning, reduce_pairing, root_compatibility, sign_commit_ack,
    sign_decision, verify_commit_ack, verify_decision,
};
pub use pairing_manager::{
    NormalDiscoveryEvent, PairingBind, PairingCommitPlan, PairingManager, PairingPorts,
};
pub use pairing_transport::{PairingConnection, PairingStream, PairingTransport};
pub use projection::ProjectionCheckpoint;
pub use query::*;
pub use quinn_transport::{
    MemoryTrustResolver, QuinnTransport, QuinnTransportConfig, QuinnTransportError, SYNC_ALPN,
    TlsIdentity, TrustResolver, extract_public_key,
};
pub use records::{
    GenericRecord, MEMBER_KEY_SEPARATOR, RecordFieldIssue, RecordId, RecordValidationError,
    member_key, parse_member_key, read_set_value, validate_record, write_set_value,
};
pub use remap::{ClonePlan, IdRemap, clone_plan, plan_with_remap, remap_record_values};
pub use routing::{
    ConnectionDirection, ConnectionFailure, ConnectionManager, DialTiming, EndpointRegistry,
    EndpointSource, NetworkEndpoint, PeerConnectionState, PeerConnector, SessionCandidate,
    SyncStatus, aggregate_sync_status, choose_session, is_preferred_initiator, rank_endpoints,
};
pub use schema::{
    CollectionSchema, CollectionSchemaId, DisplayMetadata, EnumOption, EnumOptionId,
    FieldDefinition, FieldId, FieldType, ValidationMetadata,
};
pub use values::{DecimalError, FieldValue, FixedDecimal};
pub use view::*;
pub use widget_registry::{
    AggregateNumberConfig, BarChartConfig, CORE_AGGREGATE_NUMBER, CORE_BAR_CHART, CORE_LINE_CHART,
    CORE_SCATTER_PLOT, DecodedConfiguration, LineChartConfig, QueryResultShape,
    ResolvedWidgetQuery, ScatterPlotConfig, WidgetDescriptor, WidgetError, WidgetEvaluation,
    builtin_descriptors, decode_configuration, descriptor_for, evaluate_widget, is_supported,
    validate_configuration, validate_widget_configuration,
};
pub use widgets::{
    MAX_STRUCTURED_DEPTH, MAX_STRUCTURED_KEY_LENGTH, MAX_STRUCTURED_NODES, MAX_WIDGET_TITLE_LENGTH,
    MAX_WIDGET_TYPE_LENGTH, StructuredValue, WIDGET_CONFIGURATION_VERSION, WIDGET_LAYOUT_VERSION,
    WidgetConfiguration, WidgetDefinition, WidgetId, WidgetLayout, WidgetSize, WidgetType,
    WidgetUpdate, WidgetValidationError, validate_title, validate_widget_type,
};
