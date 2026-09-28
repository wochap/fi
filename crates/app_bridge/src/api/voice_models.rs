//! Voice model provisioning; see `app_core::models`.
//!
//! Every call names the models directory (`<app data>/models`). The process
//! keeps one manager per directory so a running download and its status
//! stream survive across calls.

use std::{
    path::PathBuf,
    sync::{Mutex, OnceLock},
};

use app_core::models::{
    DownloadProgress, ModelError, ModelManager, ModelManagerConfig, ModelStatus,
};
use flutter_rust_bridge::frb;

use crate::frb_generated::StreamSink;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelStatusKindDto {
    NotDownloaded,
    Downloading,
    Paused,
    Ready,
    Failed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelErrorKindDto {
    Network,
    HttpStatus,
    Checksum,
    NotEnoughStorage,
    Io,
    VoiceTurnActive,
}

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
#[error("{message}")]
pub struct ModelErrorDto {
    pub kind: ModelErrorKindDto,
    pub message: String,
    /// Set for `HttpStatus`.
    pub http_status: Option<u16>,
    /// Set for `NotEnoughStorage`: download plus headroom.
    pub needed_bytes: Option<u64>,
}

impl From<ModelError> for ModelErrorDto {
    fn from(error: ModelError) -> Self {
        let message = error.to_string();
        let (kind, http_status, needed_bytes) = match error {
            ModelError::Network(_) => (ModelErrorKindDto::Network, None, None),
            ModelError::HttpStatus(status) => (ModelErrorKindDto::HttpStatus, Some(status), None),
            ModelError::Checksum { .. } => (ModelErrorKindDto::Checksum, None, None),
            ModelError::NotEnoughStorage { needed_bytes, .. } => (
                ModelErrorKindDto::NotEnoughStorage,
                None,
                Some(needed_bytes),
            ),
            ModelError::Io(_) => (ModelErrorKindDto::Io, None, None),
            ModelError::VoiceTurnActive => (ModelErrorKindDto::VoiceTurnActive, None, None),
        };
        Self {
            kind,
            message,
            http_status,
            needed_bytes,
        }
    }
}

/// The model set's state, flattened for Dart.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelStatusDto {
    pub kind: ModelStatusKindDto,
    /// Bytes on disk over the whole set (verified plus partial).
    pub done_bytes: u64,
    /// Sum of every manifest file.
    pub total_bytes: u64,
    /// Sum of files not yet verified: the size a download offer shows.
    pub remaining_bytes: u64,
    pub seconds_left: Option<u64>,
    /// Set for `Failed`.
    pub error: Option<ModelErrorDto>,
}

impl ModelStatusDto {
    fn from_core(status: ModelStatus, manager: &ModelManager) -> Self {
        let store = manager.store();
        let total_bytes = store.manifest().total_size();
        let with_progress = |kind, progress: DownloadProgress, error| Self {
            kind,
            done_bytes: progress.done_bytes,
            total_bytes: progress.total_bytes,
            remaining_bytes: store.remaining_bytes(),
            seconds_left: progress.seconds_left,
            error,
        };
        match status {
            ModelStatus::NotDownloaded { download_bytes } => Self {
                kind: ModelStatusKindDto::NotDownloaded,
                done_bytes: 0,
                total_bytes,
                remaining_bytes: download_bytes,
                seconds_left: None,
                error: None,
            },
            ModelStatus::Downloading(progress) => {
                with_progress(ModelStatusKindDto::Downloading, progress, None)
            }
            ModelStatus::Paused(progress) => {
                with_progress(ModelStatusKindDto::Paused, progress, None)
            }
            ModelStatus::Ready { size_on_disk } => Self {
                kind: ModelStatusKindDto::Ready,
                done_bytes: size_on_disk,
                total_bytes,
                remaining_bytes: 0,
                seconds_left: None,
                error: None,
            },
            ModelStatus::Failed { error, progress } => with_progress(
                ModelStatusKindDto::Failed,
                progress,
                Some(ModelErrorDto::from(error)),
            ),
        }
    }
}

static MANAGERS: OnceLock<Mutex<Vec<(PathBuf, ModelManager)>>> = OnceLock::new();

fn manager(models_dir: &str) -> ModelManager {
    let path = PathBuf::from(models_dir);
    let mut managers = MANAGERS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .expect("model managers lock");
    if let Some((_, manager)) = managers.iter().find(|(dir, _)| *dir == path) {
        return manager.clone();
    }
    let manager = ModelManager::new(ModelManagerConfig::new(path.clone()));
    managers.push((path, manager.clone()));
    manager
}

/// Current status of the model set.
#[frb(sync)]
#[must_use]
pub fn model_status(models_dir: String) -> ModelStatusDto {
    let manager = manager(&models_dir);
    ModelStatusDto::from_core(manager.status(), &manager)
}

/// Free bytes on the volume holding the models, when known.
#[frb(sync)]
#[must_use]
pub fn model_free_storage_bytes(models_dir: String) -> Option<u64> {
    let mut path = PathBuf::from(models_dir);
    while !path.exists() {
        if !path.pop() {
            return None;
        }
    }
    app_core::models::system_free_space()(&path).ok()
}

/// Starts or resumes the download. Refuses with `NotEnoughStorage` when it won't fit.
pub fn start_model_download(models_dir: String) -> Result<(), ModelErrorDto> {
    manager(&models_dir)
        .start_download()
        .map_err(ModelErrorDto::from)
}

/// Pauses the download, keeping the bytes already stored.
pub fn pause_model_download(models_dir: String) {
    manager(&models_dir).pause_download();
}

/// Cancels the download, dropping partial bytes.
pub fn cancel_model_download(models_dir: String) {
    manager(&models_dir).cancel_download();
}

/// Deletes every model file, returning the bytes freed.
pub fn delete_models(models_dir: String) -> Result<u64, ModelErrorDto> {
    manager(&models_dir)
        .delete_models()
        .map_err(ModelErrorDto::from)
}

/// Deletes the models, then starts a fresh download.
pub fn redownload_models(models_dir: String) -> Result<(), ModelErrorDto> {
    manager(&models_dir)
        .redownload_models()
        .map_err(ModelErrorDto::from)
}

/// Marks a voice turn as running; delete and re-download refuse meanwhile.
#[frb(sync)]
pub fn set_voice_turn_active(models_dir: String, active: bool) {
    manager(&models_dir).set_voice_turn_active(active);
}

/// Streams the current status and every change.
pub async fn model_status_events(models_dir: String, sink: StreamSink<ModelStatusDto>) {
    let manager = manager(&models_dir);
    let mut receiver = manager.subscribe();
    tokio::spawn(async move {
        let current = receiver.borrow_and_update().clone();
        if sink
            .add(ModelStatusDto::from_core(current, &manager))
            .is_err()
        {
            return;
        }
        while receiver.changed().await.is_ok() {
            let status = receiver.borrow_and_update().clone();
            if sink
                .add(ModelStatusDto::from_core(status, &manager))
                .is_err()
            {
                break;
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_directory_reports_not_downloaded_with_the_manifest_size() {
        let dir = tempfile::tempdir().unwrap();
        let status = model_status(dir.path().to_string_lossy().into_owned());
        assert_eq!(status.kind, ModelStatusKindDto::NotDownloaded);
        assert_eq!(status.remaining_bytes, status.total_bytes);
        assert!(status.total_bytes > 1_000_000_000);
    }

    #[test]
    fn delete_refuses_during_a_voice_turn() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_string_lossy().into_owned();
        set_voice_turn_active(path.clone(), true);
        let error = delete_models(path.clone()).unwrap_err();
        assert_eq!(error.kind, ModelErrorKindDto::VoiceTurnActive);
        set_voice_turn_active(path.clone(), false);
        assert_eq!(delete_models(path), Ok(0));
    }

    #[test]
    fn storage_errors_carry_the_needed_bytes() {
        let dto = ModelErrorDto::from(ModelError::NotEnoughStorage {
            needed_bytes: 10,
            available_bytes: 1,
        });
        assert_eq!(dto.kind, ModelErrorKindDto::NotEnoughStorage);
        assert_eq!(dto.needed_bytes, Some(10));
    }
}
