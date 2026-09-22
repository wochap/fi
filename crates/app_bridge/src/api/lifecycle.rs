use std::{net::SocketAddr, path::PathBuf, sync::Arc, sync::OnceLock};

use app_core::{
    AppCore, AppCoreConfig, ApplicationState, DiscoveryGroupSecret, DomainKind,
    InMemorySecureKeyStore, LinuxSecretServiceKeyStore, QuinnTransportConfig, RecoveryRecord,
    SecureKeyStore,
};
use flutter_rust_bridge::frb;
use tokio::sync::{RwLock, watch};

use crate::{
    api::models::{
        BootstrapDto, BridgeError, BridgeErrorEventDto, DataChangedDto, DomainKindDto,
        NetworkingDeferredDto, ProjectionDto,
    },
    frb_generated::StreamSink,
};

/// How the process core was (last) opened. Kept next to the core so a dataset
/// reset reopens the exact directory and key store initialization used and
/// never takes a path from Dart.
#[frb(ignore)]
#[derive(Clone)]
enum OpenMode {
    Local,
    Networked(Arc<dyn SecureKeyStore>),
}

#[frb(ignore)]
#[derive(Clone)]
struct OpenTarget {
    data_dir: PathBuf,
    mode: OpenMode,
}

#[frb(ignore)]
#[derive(Default)]
struct ProcessSlot {
    core: Option<AppCore>,
    /// Set on every initialization attempt, including a failed one, so reset
    /// can run against a directory whose open never succeeded.
    target: Option<OpenTarget>,
}

static SLOT: OnceLock<RwLock<ProcessSlot>> = OnceLock::new();

fn process_slot() -> &'static RwLock<ProcessSlot> {
    SLOT.get_or_init(|| RwLock::new(ProcessSlot::default()))
}

pub(crate) async fn core() -> Result<AppCore, BridgeError> {
    process_slot()
        .read()
        .await
        .core
        .clone()
        .ok_or_else(|| BridgeError::lifecycle("The local collection service is not initialized."))
}

#[frb(init)]
pub fn init_app() {
    let _ = tracing_subscriber::fmt()
        .json()
        .with_target(false)
        .with_current_span(false)
        .with_writer(crate::log_sink::make_writer)
        .try_init();
    flutter_rust_bridge::setup_default_user_utils();
}

#[frb(ignore)]
async fn open_core(target: &OpenTarget) -> Result<AppCore, BridgeError> {
    match &target.mode {
        OpenMode::Local => AppCore::open(target.data_dir.clone()).await,
        OpenMode::Networked(key_store) => AppCore::open_networked(
            target.data_dir.clone(),
            key_store.clone(),
            SocketAddr::from(([0, 0, 0, 0], 0)),
            AppCoreConfig::default(),
            QuinnTransportConfig::default(),
        )
        .await
        .inspect_err(|error| {
            tracing::error!(event = "bootstrap_error", error = %error, "networked core failed to open")
        }),
    }
    .map_err(BridgeError::from)
}

#[frb(ignore)]
async fn initialize_with(data_dir: String, mode: OpenMode) -> Result<BootstrapDto, BridgeError> {
    if data_dir.trim().is_empty() {
        return Err(BridgeError::initialization(
            "An application data directory is required.",
        ));
    }
    let mut slot = process_slot().write().await;
    if let Some(core) = slot.core.as_ref() {
        return Ok(BootstrapDto::from_app(core));
    }
    let target = OpenTarget {
        data_dir: PathBuf::from(data_dir),
        mode,
    };
    slot.target = Some(target.clone());
    let core = open_core(&target).await?;
    let state = BootstrapDto::from_app(&core);
    slot.core = Some(core);
    Ok(state)
}

pub async fn initialize(data_dir: String) -> Result<BootstrapDto, BridgeError> {
    initialize_with(data_dir, OpenMode::Local).await
}

pub async fn initialize_desktop_networked(data_dir: String) -> Result<BootstrapDto, BridgeError> {
    initialize_with(
        data_dir,
        OpenMode::Networked(Arc::new(LinuxSecretServiceKeyStore::new("com.gean.fi"))),
    )
    .await
}

pub async fn initialize_android_networked(
    data_dir: String,
    device_seed: Vec<u8>,
    discovery_secret: Option<Vec<u8>>,
) -> Result<BootstrapDto, BridgeError> {
    let seed: [u8; 32] = device_seed
        .try_into()
        .map_err(|_| BridgeError::initialization("Android returned an invalid device key."))?;
    let store = Arc::new(InMemorySecureKeyStore::seeded(seed));
    if let Some(secret) = discovery_secret {
        let secret: [u8; 32] = secret.try_into().map_err(|_| {
            BridgeError::initialization("Android returned an invalid discovery secret.")
        })?;
        store
            .store_discovery_group_secret(&DiscoveryGroupSecret::from_bytes(secret))
            .await
            .map_err(|_| BridgeError::initialization("Android secure storage is unavailable."))?;
    }
    initialize_with(data_dir, OpenMode::Networked(store)).await
}

/// Deliberately abandons this device's local dataset and reopens the core in
/// `NeedsDecision`. Stops pairing and shuts the live core down first; works
/// equally when the last initialization failed (schema cliff), since the
/// directory and key store are remembered from that attempt.
pub async fn reset_dataset() -> Result<BootstrapDto, BridgeError> {
    let mut slot = process_slot().write().await;
    let target = slot.target.clone().ok_or_else(|| {
        BridgeError::lifecycle("The local collection service was never initialized.")
    })?;
    if let Some(core) = slot.core.take() {
        // Local cores have no pairing; ignore that refusal.
        let _ = core.stop_pairing().await;
        core.shutdown().await.map_err(BridgeError::from)?;
    }
    let key_store = match &target.mode {
        OpenMode::Local => None,
        OpenMode::Networked(key_store) => Some(key_store.as_ref()),
    };
    app_core::reset_dataset(&target.data_dir, key_store)
        .await
        .map_err(BridgeError::from)?;
    let core = open_core(&target).await?;
    let state = BootstrapDto::from_app(&core);
    slot.core = Some(core);
    Ok(state)
}

/// Why peer networking is not running, when a networked open met a locked or
/// unavailable secure store. `None` means networking is not deferred.
pub async fn networking_deferred() -> Result<Option<NetworkingDeferredDto>, BridgeError> {
    Ok(core()
        .await?
        .networking_deferred()
        .as_ref()
        .map(NetworkingDeferredDto::from_core))
}

/// Retries the networking startup deferred by a locked or unavailable secure
/// store and reports whether peer networking is now active. Idempotent: with
/// nothing deferred it succeeds without restarting discovery. A deferral that
/// happened before the device key could be read is retried by reopening the
/// core with the same target, since there is no network stack to restart.
pub async fn retry_networking() -> Result<bool, BridgeError> {
    let mut slot = process_slot().write().await;
    let live = slot.core.clone().ok_or_else(|| {
        BridgeError::lifecycle("The local collection service is not initialized.")
    })?;
    if !live.networking_requires_reopen() {
        return live.retry_networking().await.map_err(BridgeError::from);
    }
    let target = slot.target.clone().ok_or_else(|| {
        BridgeError::lifecycle("The local collection service was never initialized.")
    })?;
    if let Some(core) = slot.core.take() {
        core.shutdown().await.map_err(BridgeError::from)?;
    }
    let reopened = open_core(&target).await?;
    let deferred = reopened.networking_deferred();
    slot.core = Some(reopened);
    match deferred {
        Some(reason) => Err(BridgeError::from(reason.to_app_error())),
        None => Ok(true),
    }
}

pub async fn bootstrap_state() -> Result<BootstrapDto, BridgeError> {
    Ok(BootstrapDto::from_app(&core().await?))
}

pub async fn projection_state() -> Result<ProjectionDto, BridgeError> {
    Ok(ProjectionDto::from_core(core().await?.projection_state()))
}

pub async fn shutdown() -> Result<(), BridgeError> {
    let app = process_slot().write().await.core.take();
    if let Some(app) = app {
        app.shutdown().await.map_err(BridgeError::from)?;
    }
    Ok(())
}

pub async fn set_foreground(foreground: bool) -> Result<(), BridgeError> {
    core()
        .await?
        .set_foreground(foreground)
        .await
        .map_err(BridgeError::from)
}

/// Streams bootstrap state, re-emitting whenever either the lifecycle or the
/// recovery outcome changes so recovery progress is never silent.
pub async fn bootstrap_stream(sink: StreamSink<BootstrapDto>) -> Result<(), BridgeError> {
    let app = core().await?;
    let mut lifecycle = app.subscribe_lifecycle();
    let mut recovery = app.subscribe_recovery();
    tokio::spawn(async move {
        let current = |lifecycle: &watch::Receiver<ApplicationState>,
                       recovery: &watch::Receiver<Option<RecoveryRecord>>| {
            BootstrapDto::from_core(lifecycle.borrow().clone(), recovery.borrow().clone())
        };
        if sink.add(current(&lifecycle, &recovery)).is_err() {
            return;
        }
        loop {
            tokio::select! {
                changed = lifecycle.changed() => {
                    if changed.is_err() { break; }
                    lifecycle.borrow_and_update();
                }
                changed = recovery.changed() => {
                    if changed.is_err() { break; }
                    recovery.borrow_and_update();
                }
            }
            if sink.add(current(&lifecycle, &recovery)).is_err() {
                break;
            }
        }
    });
    Ok(())
}

pub async fn projection_stream(sink: StreamSink<ProjectionDto>) -> Result<(), BridgeError> {
    let mut receiver = core().await?.subscribe_projection();
    tokio::spawn(async move {
        if sink
            .add(ProjectionDto::from_core(receiver.borrow().clone()))
            .is_err()
        {
            return;
        }
        while receiver.changed().await.is_ok() {
            if sink
                .add(ProjectionDto::from_core(
                    receiver.borrow_and_update().clone(),
                ))
                .is_err()
            {
                break;
            }
        }
    });
    Ok(())
}

pub async fn data_changed_stream(sink: StreamSink<DataChangedDto>) -> Result<(), BridgeError> {
    let mut receiver = core().await?.subscribe_data_changed();
    tokio::spawn(async move {
        loop {
            let event = match receiver.recv().await {
                Ok(event) => event.into(),
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => DataChangedDto {
                    kinds: vec![
                        DomainKindDto::from(DomainKind::Collections),
                        DomainKindDto::from(DomainKind::Schemas),
                        DomainKindDto::from(DomainKind::Records),
                    ],
                    collection_ids: vec![],
                    checkpoint: String::new(),
                },
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            };
            if sink.add(event).is_err() {
                break;
            }
        }
    });
    Ok(())
}

pub async fn error_stream(sink: StreamSink<BridgeErrorEventDto>) -> Result<(), BridgeError> {
    let mut receiver = core().await?.subscribe_errors();
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    if sink.add(event.into()).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use crate::api::{
        collections,
        models::{BootstrapKindDto, RecoveryOutcomeDto, RecoveryReasonDto},
    };

    use super::{core, initialize, reset_dataset, shutdown};

    /// Bridge tests share one process slot; serialize the ones that use it.
    static SLOT_GUARD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    #[tokio::test]
    async fn delegates_commands_and_stream_sources_reconnect() {
        let _guard = SLOT_GUARD.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let initial = initialize(directory.path().to_string_lossy().into_owned())
            .await
            .unwrap();
        assert_eq!(initial.kind, BootstrapKindDto::NeedsDecision);

        let ready = collections::create_new_dataset().await.unwrap();
        assert_eq!(ready.kind, BootstrapKindDto::Ready);

        let first_status = core().await.unwrap().subscribe_lifecycle();
        assert_eq!(
            first_status.borrow().clone(),
            app_core::ApplicationState::Ready {
                root: ready.root_id.as_deref().unwrap().parse().unwrap(),
            }
        );
        drop(first_status);
        let reopened_status = core().await.unwrap().subscribe_lifecycle();
        assert!(matches!(
            reopened_status.borrow().clone(),
            app_core::ApplicationState::Ready { .. }
        ));

        let mut changes = core().await.unwrap().subscribe_data_changed();
        let collection = collections::create_collection("Food".into(), String::new())
            .await
            .unwrap();
        let event = tokio::time::timeout(Duration::from_secs(1), changes.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            event.kinds,
            vec![
                app_core::DomainKind::Collections,
                app_core::DomainKind::Schemas
            ]
        );
        assert!(
            collections::list_collections()
                .await
                .unwrap()
                .iter()
                .any(|item| item.id == collection)
        );

        let error = collections::create_collection(" ".into(), String::new())
            .await
            .unwrap_err();
        assert_eq!(error.kind, crate::api::models::BridgeErrorKind::Validation);
        shutdown().await.unwrap();
    }

    #[tokio::test]
    async fn reset_reopens_in_needs_decision_with_and_without_a_live_core() {
        let _guard = SLOT_GUARD.lock().await;
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_string_lossy().into_owned();

        // Live core in Ready: reset lands in NeedsDecision and later calls use
        // the reopened core.
        initialize(data_dir.clone()).await.unwrap();
        let ready = collections::create_new_dataset().await.unwrap();
        assert_eq!(ready.kind, BootstrapKindDto::Ready);
        let after = reset_dataset().await.unwrap();
        assert_eq!(after.kind, BootstrapKindDto::NeedsDecision);
        assert_eq!(
            core().await.unwrap().lifecycle_state(),
            app_core::ApplicationState::NeedsDecision
        );

        // Bootstrap record without its root snapshot: initialization now
        // succeeds in a recovering Joining state that names the root, and a
        // reset from there still lands in NeedsDecision.
        let ready = collections::create_new_dataset().await.unwrap();
        shutdown().await.unwrap();
        std::fs::remove_dir_all(directory.path().join("automerge/documents")).unwrap();
        let recovering = initialize(data_dir.clone()).await.unwrap();
        assert_eq!(recovering.kind, BootstrapKindDto::Joining);
        assert_eq!(recovering.root_id, ready.root_id);
        let recovery = recovering.recovery.expect("recovery is observable");
        assert_eq!(recovery.reason, RecoveryReasonDto::RootSnapshotMissing);
        assert_eq!(recovery.outcome, RecoveryOutcomeDto::Recovering);
        assert_eq!(recovery.root_id, ready.root_id);
        let after = reset_dataset().await.unwrap();
        assert_eq!(after.kind, BootstrapKindDto::NeedsDecision);
        assert_eq!(after.recovery, None);

        // Genuinely inconsistent state (a Creating record beside a foreign
        // document): initialization fails with a reset-resolvable error and
        // reset still works without a live core.
        let ready = collections::create_new_dataset().await.unwrap();
        shutdown().await.unwrap();
        let root: automerge_repo::DocumentId = ready.root_id.unwrap().parse().unwrap();
        let documents = directory.path().join("automerge/documents");
        std::fs::copy(
            documents.join(format!("{root}.automerge")),
            documents.join(format!("{}.automerge", automerge_repo::DocumentId::new())),
        )
        .unwrap();
        automerge_repo::storage::ControlStore::store(
            &app_core::adapters::SqliteControlStore::open(directory.path().join("control.sqlite"))
                .unwrap(),
            automerge_repo::BootstrapRecord::Creating { root },
        )
        .await
        .unwrap();

        let error = initialize(data_dir.clone()).await.unwrap_err();
        assert!(error.reset_resolvable, "{error:?}");
        assert!(core().await.is_err());
        let after = reset_dataset().await.unwrap();
        assert_eq!(after.kind, BootstrapKindDto::NeedsDecision);
        assert_eq!(
            initialize(data_dir).await.unwrap().kind,
            BootstrapKindDto::NeedsDecision
        );
        shutdown().await.unwrap();
    }
}
