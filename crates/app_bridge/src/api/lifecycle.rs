use std::sync::OnceLock;

use app_core::{AppCore, DomainKind};
use flutter_rust_bridge::frb;
use tokio::sync::RwLock;

use crate::{
    api::models::{
        BootstrapDto, BridgeError, BridgeErrorEventDto, DataChangedDto, DomainKindDto,
        ProjectionDto,
    },
    frb_generated::StreamSink,
};

static CORE: OnceLock<RwLock<Option<AppCore>>> = OnceLock::new();

fn process_core() -> &'static RwLock<Option<AppCore>> {
    CORE.get_or_init(|| RwLock::new(None))
}

pub(crate) async fn core() -> Result<AppCore, BridgeError> {
    process_core()
        .read()
        .await
        .clone()
        .ok_or_else(|| BridgeError::lifecycle("The local finance service is not initialized."))
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub async fn initialize(data_dir: String) -> Result<BootstrapDto, BridgeError> {
    if data_dir.trim().is_empty() {
        return Err(BridgeError::initialization(
            "An application data directory is required.",
        ));
    }
    let mut slot = process_core().write().await;
    if let Some(core) = slot.as_ref() {
        return Ok(BootstrapDto::from_core(core.lifecycle_state()));
    }
    let core = AppCore::open(data_dir).await.map_err(BridgeError::from)?;
    let state = BootstrapDto::from_core(core.lifecycle_state());
    *slot = Some(core);
    Ok(state)
}

pub async fn bootstrap_state() -> Result<BootstrapDto, BridgeError> {
    Ok(BootstrapDto::from_core(core().await?.lifecycle_state()))
}

pub async fn projection_state() -> Result<ProjectionDto, BridgeError> {
    Ok(ProjectionDto::from_core(core().await?.projection_state()))
}

pub async fn shutdown() -> Result<(), BridgeError> {
    let app = process_core().write().await.take();
    if let Some(app) = app {
        app.shutdown().await.map_err(BridgeError::from)?;
    }
    Ok(())
}

pub async fn bootstrap_stream(sink: StreamSink<BootstrapDto>) -> Result<(), BridgeError> {
    let mut receiver = core().await?.subscribe_lifecycle();
    tokio::spawn(async move {
        if sink
            .add(BootstrapDto::from_core(receiver.borrow().clone()))
            .is_err()
        {
            return;
        }
        while receiver.changed().await.is_ok() {
            if sink
                .add(BootstrapDto::from_core(
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
                        DomainKindDto::from(DomainKind::Categories),
                        DomainKindDto::from(DomainKind::Transactions),
                    ],
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

    use crate::api::{finance, models::BootstrapKindDto};

    use super::{core, initialize, shutdown};

    #[tokio::test]
    async fn delegates_commands_and_stream_sources_reconnect() {
        let directory = tempfile::tempdir().unwrap();
        let initial = initialize(directory.path().to_string_lossy().into_owned())
            .await
            .unwrap();
        assert_eq!(initial.kind, BootstrapKindDto::NeedsDecision);

        let ready = finance::create_new_dataset().await.unwrap();
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
        let category = finance::create_category("Food".into()).await.unwrap();
        let event = tokio::time::timeout(Duration::from_secs(1), changes.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(event.kinds, vec![app_core::DomainKind::Categories]);
        assert!(
            finance::list_categories()
                .await
                .unwrap()
                .iter()
                .any(|item| item.id == category)
        );

        let error = finance::create_category(" ".into()).await.unwrap_err();
        assert_eq!(error.kind, crate::api::models::BridgeErrorKind::Validation);
        shutdown().await.unwrap();
    }
}
