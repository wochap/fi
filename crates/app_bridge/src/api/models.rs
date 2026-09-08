use app_core::{
    AppError, ApplicationState, DataChanged, DomainError, DomainKind, ErrorEvent, ProjectionState,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BootstrapKindDto {
    NeedsDecision,
    Creating,
    Joining,
    Ready,
    ShuttingDown,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BootstrapDto {
    pub kind: BootstrapKindDto,
    pub root_id: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProjectionKindDto {
    Unavailable,
    Rebuilding,
    Projecting,
    Ready,
    Failed,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectionDto {
    pub kind: ProjectionKindDto,
    pub checkpoint: Option<String>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollectionDto {
    pub id: String,
    pub name: String,
    pub description: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CollectionSchemaDto {
    pub id: String,
    pub description: String,
    pub name: String,
    pub fields: Vec<FieldDefinitionDto>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FieldTypeKindDto {
    Text,
    Integer,
    FixedDecimal,
    Boolean,
    Date,
    DateTime,
    Duration,
    Enum,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FieldTypeDto {
    pub kind: FieldTypeKindDto,
    pub scale: Option<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FieldValueKindDto {
    Null,
    Text,
    Integer,
    FixedDecimal,
    Boolean,
    Date,
    DateTime,
    Duration,
    Enum,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FieldValueDto {
    pub kind: FieldValueKindDto,
    pub integer_value: Option<i64>,
    pub text_value: Option<String>,
    pub boolean_value: Option<bool>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ValidationMetadataDto {
    pub min_integer: Option<i64>,
    pub max_integer: Option<i64>,
    pub min_length: Option<u32>,
    pub max_length: Option<u32>,
}
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct DisplayMetadataDto {
    pub multiline: bool,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EnumOptionDto {
    pub id: String,
    pub label: String,
    pub order: i64,
    pub deleted: bool,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FieldDefinitionDto {
    pub id: String,
    pub name: String,
    pub field_type: FieldTypeDto,
    pub required: bool,
    pub default_value: Option<FieldValueDto>,
    pub validation: ValidationMetadataDto,
    pub display: DisplayMetadataDto,
    pub order: i64,
    pub deleted: bool,
    pub enum_options: Vec<EnumOptionDto>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordValueDto {
    pub field_id: String,
    pub value: FieldValueDto,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiagnosticDto {
    pub kind: String,
    pub entity_id: String,
    pub field_id: Option<String>,
    pub message: String,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordDto {
    pub id: String,
    pub collection_id: String,
    pub values: Vec<RecordValueDto>,
    pub valid: bool,
    pub diagnostics: Vec<DiagnosticDto>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DomainKindDto {
    Collections,
    Schemas,
    Records,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DataChangedDto {
    pub kinds: Vec<DomainKindDto>,
    pub collection_ids: Vec<String>,
    pub checkpoint: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BridgeErrorKind {
    Initialization,
    Validation,
    Bootstrap,
    Persistence,
    Projection,
    Lifecycle,
    Internal,
}

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
#[error("{message}")]
pub struct BridgeError {
    pub kind: BridgeErrorKind,
    pub field: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BridgeErrorEventDto {
    pub kind: BridgeErrorKind,
    pub operation: String,
    pub message: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PairingKindDto {
    Idle,
    Discoverable,
    Connecting,
    AwaitingConfirmation,
    Committing,
    Trusted,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingStateDto {
    pub kind: PairingKindDto,
    pub session_id: Option<String>,
    pub sas: Option<String>,
    pub peer_device_id: Option<String>,
    pub deadline_ms: Option<u64>,
    pub local_confirmed: bool,
    pub remote_confirmed: bool,
    pub message: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PairingCandidateDto {
    pub instance_id: String,
    pub endpoint: String,
    pub expires_at_ms: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TrustedDeviceDto {
    pub device_id: String,
    pub friendly_name: String,
    pub paired_at_ms: u64,
    pub last_seen_ms: Option<u64>,
    pub last_sync_ms: Option<u64>,
    pub revoked: bool,
    pub connection: PeerConnectionKindDto,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PeerConnectionKindDto {
    Offline,
    Searching,
    Connected,
    Syncing,
    Synced,
    Error,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SyncStatusDto {
    Offline,
    Searching,
    Connected,
    Syncing,
    Synced,
    Error,
}

impl From<app_core::PairingState> for PairingStateDto {
    fn from(value: app_core::PairingState) -> Self {
        use app_core::PairingState;
        let mut dto = Self {
            kind: PairingKindDto::Idle,
            session_id: None,
            sas: None,
            peer_device_id: None,
            deadline_ms: None,
            local_confirmed: false,
            remote_confirmed: false,
            message: None,
        };
        match value {
            PairingState::Idle => {}
            PairingState::Discoverable { deadline_ms, .. } => {
                dto.kind = PairingKindDto::Discoverable;
                dto.deadline_ms = Some(deadline_ms);
            }
            PairingState::Connecting {
                session_id,
                deadline_ms,
                ..
            } => {
                dto.kind = PairingKindDto::Connecting;
                dto.session_id = Some(hex_id(session_id.0));
                dto.deadline_ms = Some(deadline_ms);
            }
            PairingState::AwaitingConfirmation {
                session_id,
                sas,
                local_confirmed,
                remote_confirmed,
                deadline_ms,
            } => {
                dto.kind = PairingKindDto::AwaitingConfirmation;
                dto.session_id = Some(hex_id(session_id.0));
                dto.sas = Some(sas.expose().to_owned());
                dto.local_confirmed = local_confirmed;
                dto.remote_confirmed = remote_confirmed;
                dto.deadline_ms = Some(deadline_ms);
            }
            PairingState::Committing {
                session_id,
                peer,
                deadline_ms,
            } => {
                dto.kind = PairingKindDto::Committing;
                dto.session_id = Some(hex_id(session_id.0));
                dto.peer_device_id = Some(peer.to_string());
                dto.deadline_ms = Some(deadline_ms);
            }
            PairingState::Trusted { peer } => {
                dto.kind = PairingKindDto::Trusted;
                dto.peer_device_id = Some(peer.to_string());
            }
            PairingState::Failed { error } => {
                dto.kind = PairingKindDto::Failed;
                dto.message = Some(error.to_string());
            }
        }
        dto
    }
}

impl From<app_core::PairingCandidate> for PairingCandidateDto {
    fn from(value: app_core::PairingCandidate) -> Self {
        Self {
            instance_id: value.instance_id.to_string(),
            endpoint: value.endpoint.to_string(),
            expires_at_ms: value.expires_at_ms,
        }
    }
}

impl TrustedDeviceDto {
    pub(crate) fn from_core(
        value: app_core::TrustedDeviceRecord,
        connection: Option<&app_core::PeerConnectionState>,
    ) -> Self {
        Self {
            device_id: value.device_id.to_string(),
            friendly_name: value.friendly_name,
            paired_at_ms: value.paired_at_ms,
            last_seen_ms: value.last_seen_ms,
            last_sync_ms: value.last_sync_ms,
            revoked: value.state == app_core::TrustState::Revoked,
            connection: connection.into(),
        }
    }
}

impl From<Option<&app_core::PeerConnectionState>> for PeerConnectionKindDto {
    fn from(value: Option<&app_core::PeerConnectionState>) -> Self {
        use app_core::PeerConnectionState;
        match value {
            None | Some(PeerConnectionState::Disconnected) => Self::Offline,
            Some(
                PeerConnectionState::Connecting { .. } | PeerConnectionState::Authenticating { .. },
            ) => Self::Searching,
            Some(PeerConnectionState::Connected) => Self::Connected,
            Some(PeerConnectionState::Syncing) => Self::Syncing,
            Some(PeerConnectionState::Synced) => Self::Synced,
            Some(PeerConnectionState::Failed(_)) => Self::Error,
        }
    }
}

impl From<app_core::SyncStatus> for SyncStatusDto {
    fn from(value: app_core::SyncStatus) -> Self {
        match value {
            app_core::SyncStatus::Offline => Self::Offline,
            app_core::SyncStatus::Searching => Self::Searching,
            app_core::SyncStatus::Connected => Self::Connected,
            app_core::SyncStatus::Syncing => Self::Syncing,
            app_core::SyncStatus::Synced => Self::Synced,
            app_core::SyncStatus::Error => Self::Error,
        }
    }
}

fn hex_id(value: [u8; 16]) -> String {
    value.iter().map(|byte| format!("{byte:02x}")).collect()
}

impl BootstrapDto {
    pub(crate) fn from_core(value: ApplicationState) -> Self {
        match value {
            ApplicationState::NeedsDecision => Self::new(BootstrapKindDto::NeedsDecision, None),
            ApplicationState::Creating => Self::new(BootstrapKindDto::Creating, None),
            ApplicationState::Joining { root } => {
                Self::new(BootstrapKindDto::Joining, Some(root.to_string()))
            }
            ApplicationState::Ready { root } => {
                Self::new(BootstrapKindDto::Ready, Some(root.to_string()))
            }
            ApplicationState::ShuttingDown => Self::new(BootstrapKindDto::ShuttingDown, None),
            ApplicationState::Closed => Self::new(BootstrapKindDto::Closed, None),
        }
    }

    fn new(kind: BootstrapKindDto, root_id: Option<String>) -> Self {
        Self { kind, root_id }
    }
}

impl ProjectionDto {
    pub(crate) fn from_core(value: ProjectionState) -> Self {
        match value {
            ProjectionState::Unavailable => Self::new(ProjectionKindDto::Unavailable, None, None),
            ProjectionState::Rebuilding => Self::new(ProjectionKindDto::Rebuilding, None, None),
            ProjectionState::Projecting => Self::new(ProjectionKindDto::Projecting, None, None),
            ProjectionState::Ready { checkpoint } => {
                Self::new(ProjectionKindDto::Ready, Some(checkpoint.heads), None)
            }
            ProjectionState::Failed { .. } => Self::new(
                ProjectionKindDto::Failed,
                None,
                Some("The local read model could not be refreshed.".into()),
            ),
            ProjectionState::Closed => Self::new(ProjectionKindDto::Closed, None, None),
        }
    }

    fn new(kind: ProjectionKindDto, checkpoint: Option<String>, message: Option<String>) -> Self {
        Self {
            kind,
            checkpoint,
            message,
        }
    }
}

impl From<app_core::CollectionView> for CollectionDto {
    fn from(value: app_core::CollectionView) -> Self {
        Self {
            id: value.id.to_string(),
            name: value.name,
            description: value.description,
        }
    }
}
impl From<app_core::CollectionSchema> for CollectionSchemaDto {
    fn from(value: app_core::CollectionSchema) -> Self {
        Self {
            id: value.id.to_string(),
            name: value.name,
            description: value.description,
            fields: value.fields.into_iter().map(Into::into).collect(),
        }
    }
}
impl From<app_core::FieldType> for FieldTypeDto {
    fn from(value: app_core::FieldType) -> Self {
        let (kind, scale) = match value {
            app_core::FieldType::Text => (FieldTypeKindDto::Text, None),
            app_core::FieldType::Integer => (FieldTypeKindDto::Integer, None),
            app_core::FieldType::FixedDecimal { scale } => {
                (FieldTypeKindDto::FixedDecimal, Some(scale))
            }
            app_core::FieldType::Boolean => (FieldTypeKindDto::Boolean, None),
            app_core::FieldType::Date => (FieldTypeKindDto::Date, None),
            app_core::FieldType::DateTime => (FieldTypeKindDto::DateTime, None),
            app_core::FieldType::Duration => (FieldTypeKindDto::Duration, None),
            app_core::FieldType::Enum => (FieldTypeKindDto::Enum, None),
        };
        Self { kind, scale }
    }
}
impl From<FieldTypeDto> for app_core::FieldType {
    fn from(value: FieldTypeDto) -> Self {
        match value.kind {
            FieldTypeKindDto::Text => Self::Text,
            FieldTypeKindDto::Integer => Self::Integer,
            FieldTypeKindDto::FixedDecimal => Self::FixedDecimal {
                scale: value.scale.unwrap_or(u8::MAX),
            },
            FieldTypeKindDto::Boolean => Self::Boolean,
            FieldTypeKindDto::Date => Self::Date,
            FieldTypeKindDto::DateTime => Self::DateTime,
            FieldTypeKindDto::Duration => Self::Duration,
            FieldTypeKindDto::Enum => Self::Enum,
        }
    }
}
impl From<app_core::FieldValue> for FieldValueDto {
    fn from(value: app_core::FieldValue) -> Self {
        let (kind, integer_value, text_value, boolean_value) = match value {
            app_core::FieldValue::Null => (FieldValueKindDto::Null, None, None, None),
            app_core::FieldValue::Text(value) => (FieldValueKindDto::Text, None, Some(value), None),
            app_core::FieldValue::Integer(value) => {
                (FieldValueKindDto::Integer, Some(value), None, None)
            }
            app_core::FieldValue::FixedDecimal(value) => {
                (FieldValueKindDto::FixedDecimal, Some(value), None, None)
            }
            app_core::FieldValue::Boolean(value) => {
                (FieldValueKindDto::Boolean, None, None, Some(value))
            }
            app_core::FieldValue::Date(value) => (FieldValueKindDto::Date, Some(value), None, None),
            app_core::FieldValue::DateTime(value) => {
                (FieldValueKindDto::DateTime, Some(value), None, None)
            }
            app_core::FieldValue::Duration(value) => {
                (FieldValueKindDto::Duration, Some(value), None, None)
            }
            app_core::FieldValue::Enum(value) => {
                (FieldValueKindDto::Enum, None, Some(value.to_string()), None)
            }
        };
        Self {
            kind,
            integer_value,
            text_value,
            boolean_value,
        }
    }
}
impl FieldValueDto {
    pub(crate) fn into_core(self) -> Result<app_core::FieldValue, BridgeError> {
        let missing = || BridgeError::validation("value", "typed value payload is missing");
        Ok(match self.kind {
            FieldValueKindDto::Null => app_core::FieldValue::Null,
            FieldValueKindDto::Text => {
                app_core::FieldValue::Text(self.text_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::Integer => {
                app_core::FieldValue::Integer(self.integer_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::FixedDecimal => {
                app_core::FieldValue::FixedDecimal(self.integer_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::Boolean => {
                app_core::FieldValue::Boolean(self.boolean_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::Date => {
                app_core::FieldValue::Date(self.integer_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::DateTime => {
                app_core::FieldValue::DateTime(self.integer_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::Duration => {
                app_core::FieldValue::Duration(self.integer_value.ok_or_else(missing)?)
            }
            FieldValueKindDto::Enum => {
                app_core::FieldValue::Enum(self.text_value.ok_or_else(missing)?.parse().map_err(
                    |error: app_core::DomainError| BridgeError::from(AppError::from(error)),
                )?)
            }
        })
    }
}
impl From<app_core::FieldDefinition> for FieldDefinitionDto {
    fn from(value: app_core::FieldDefinition) -> Self {
        Self {
            id: value.id.to_string(),
            name: value.name,
            field_type: value.field_type.into(),
            required: value.required,
            default_value: value.default.map(Into::into),
            validation: ValidationMetadataDto {
                min_integer: value.validation.min_integer,
                max_integer: value.validation.max_integer,
                min_length: value.validation.min_length,
                max_length: value.validation.max_length,
            },
            display: DisplayMetadataDto {
                multiline: value.display.multiline,
            },
            order: value.order,
            deleted: value.deleted,
            enum_options: value.enum_options.into_iter().map(Into::into).collect(),
        }
    }
}
impl TryFrom<FieldDefinitionDto> for app_core::FieldDefinition {
    type Error = BridgeError;
    fn try_from(value: FieldDefinitionDto) -> Result<Self, Self::Error> {
        Ok(Self {
            id: value
                .id
                .parse()
                .map_err(|error: app_core::DomainError| BridgeError::from(AppError::from(error)))?,
            name: value.name,
            field_type: value.field_type.into(),
            required: value.required,
            default: value
                .default_value
                .map(FieldValueDto::into_core)
                .transpose()?,
            validation: app_core::ValidationMetadata {
                min_integer: value.validation.min_integer,
                max_integer: value.validation.max_integer,
                min_length: value.validation.min_length,
                max_length: value.validation.max_length,
            },
            display: app_core::DisplayMetadata {
                multiline: value.display.multiline,
            },
            order: value.order,
            deleted: value.deleted,
            enum_options: value
                .enum_options
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_, _>>()?,
        })
    }
}
impl From<app_core::EnumOption> for EnumOptionDto {
    fn from(value: app_core::EnumOption) -> Self {
        Self {
            id: value.id.to_string(),
            label: value.label,
            order: value.order,
            deleted: value.deleted,
        }
    }
}
impl TryFrom<EnumOptionDto> for app_core::EnumOption {
    type Error = BridgeError;
    fn try_from(value: EnumOptionDto) -> Result<Self, Self::Error> {
        Ok(Self {
            id: value
                .id
                .parse()
                .map_err(|error: app_core::DomainError| BridgeError::from(AppError::from(error)))?,
            label: value.label,
            order: value.order,
            deleted: value.deleted,
        })
    }
}
impl From<app_core::GenericDiagnostic> for DiagnosticDto {
    fn from(value: app_core::GenericDiagnostic) -> Self {
        Self {
            kind: value.kind,
            entity_id: value.entity_id,
            field_id: value.field_id.map(|id| id.to_string()),
            message: value.message,
        }
    }
}
impl From<app_core::RecordView> for RecordDto {
    fn from(value: app_core::RecordView) -> Self {
        Self {
            id: value.record.id.to_string(),
            collection_id: value.record.collection_id.to_string(),
            values: value
                .record
                .values
                .into_iter()
                .map(|(field_id, value)| RecordValueDto {
                    field_id: field_id.to_string(),
                    value: value.into(),
                })
                .collect(),
            valid: value.valid,
            diagnostics: value.diagnostics.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<DomainKind> for DomainKindDto {
    fn from(value: DomainKind) -> Self {
        match value {
            DomainKind::Collections => Self::Collections,
            DomainKind::Schemas => Self::Schemas,
            DomainKind::Records => Self::Records,
        }
    }
}

impl From<DataChanged> for DataChangedDto {
    fn from(value: DataChanged) -> Self {
        Self {
            kinds: value.kinds.into_iter().map(Into::into).collect(),
            collection_ids: value
                .collection_ids
                .into_iter()
                .map(|id| id.to_string())
                .collect(),
            checkpoint: value.checkpoint.heads,
        }
    }
}

impl From<ErrorEvent> for BridgeErrorEventDto {
    fn from(value: ErrorEvent) -> Self {
        Self {
            kind: BridgeErrorKind::Projection,
            operation: value.operation.into(),
            message: "The local read model could not be refreshed.".into(),
        }
    }
}

impl From<AppError> for BridgeError {
    fn from(value: AppError) -> Self {
        match value {
            AppError::Domain(DomainError::Invalid { field, message }) => Self {
                kind: BridgeErrorKind::Validation,
                field: Some(field.into()),
                message,
            },
            AppError::Domain(DomainError::NotFound { kind, .. }) => Self::safe(
                BridgeErrorKind::Validation,
                format!("The selected {kind} no longer exists."),
            ),
            AppError::Domain(_) => Self::safe(
                BridgeErrorKind::Internal,
                "The local collection data is not supported by this application version.",
            ),
            AppError::Bootstrap(error) => Self::safe(BridgeErrorKind::Bootstrap, error.to_string()),
            AppError::Projection(_) => Self::safe(
                BridgeErrorKind::Projection,
                "The local read model could not be refreshed.",
            ),
            AppError::Repository(_) | AppError::Storage(_) => Self::safe(
                BridgeErrorKind::Persistence,
                "Local data could not be saved or loaded.",
            ),
            AppError::Identity(_) | AppError::Network(_) | AppError::Pairing(_) => Self::safe(
                BridgeErrorKind::Initialization,
                "Secure device networking could not be initialized.",
            ),
            AppError::Clock(error) => Self::safe(BridgeErrorKind::Validation, error.to_string()),
            AppError::OwnerStopped => Self::safe(
                BridgeErrorKind::Lifecycle,
                "The local collection service is not running.",
            ),
        }
    }
}

impl BridgeError {
    pub(crate) fn validation(field: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            kind: BridgeErrorKind::Validation,
            field: Some(field.into()),
            message: message.into(),
        }
    }
    pub(crate) fn initialization(message: impl Into<String>) -> Self {
        Self::safe(BridgeErrorKind::Initialization, message)
    }

    pub(crate) fn lifecycle(message: impl Into<String>) -> Self {
        Self::safe(BridgeErrorKind::Lifecycle, message)
    }

    fn safe(kind: BridgeErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            field: None,
            message: message.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use app_core::{AppError, DomainError};

    use super::{BridgeError, BridgeErrorKind};

    #[test]
    fn maps_validation_and_hides_infrastructure_failures() {
        let validation = BridgeError::from(AppError::Domain(DomainError::Invalid {
            field: "amount_minor",
            message: "must be non-zero".into(),
        }));
        assert_eq!(validation.kind, BridgeErrorKind::Validation);
        assert_eq!(validation.field.as_deref(), Some("amount_minor"));

        let storage = BridgeError::from(AppError::Storage(
            "/private/path/control.sqlite: disk failure".into(),
        ));
        assert_eq!(storage.kind, BridgeErrorKind::Persistence);
        assert!(!storage.message.contains("/private/path"));
        assert!(!storage.message.contains("sqlite"));
    }
}
