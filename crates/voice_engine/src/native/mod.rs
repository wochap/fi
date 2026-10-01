//! whisper.cpp and llama.cpp runners. Built only with the `native` feature.

mod llama;
mod whisper;

use std::{
    path::Path,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
};

pub use llama::LlamaRunner;
pub use whisper::transcribe;

use app_core::models::{ModelManifest, ModelRole};

use crate::{VoiceError, VoiceLanguage};

fn manifest() -> &'static ModelManifest {
    static MANIFEST: OnceLock<ModelManifest> = OnceLock::new();
    MANIFEST.get_or_init(ModelManifest::bundled)
}

/// The speech model's file name for a language, inside the provisioned models directory.
pub fn speech_model_file(language: VoiceLanguage) -> &'static str {
    manifest()
        .speech_file(language.code())
        .expect("the manifest has a speech model for every voice language")
        .name
        .as_str()
}

/// The instruction model's file name inside the provisioned models directory.
pub fn understanding_model_file() -> &'static str {
    manifest()
        .files
        .iter()
        .find(|file| file.role == ModelRole::Understanding)
        .expect("the manifest has an understanding model")
        .name
        .as_str()
}
/// Big cores on the target device.
pub const THREADS: i32 = 4;

/// A cancel flag shared with the whisper abort callback and the decode loop.
#[derive(Clone, Debug, Default)]
pub struct CancelFlag(Arc<AtomicBool>);

impl CancelFlag {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn reset(&self) {
        self.0.store(false, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }

    /// The flag itself, for C callbacks. Valid while this `CancelFlag` (or a clone) is alive.
    fn as_ptr(&self) -> *const AtomicBool {
        Arc::as_ptr(&self.0)
    }
}

/// `ModelLoadFailed` when the file is missing, unreadable or lacks `magic`; otherwise the load
/// failure is read as an allocation failure when memory is short.
fn check_model_file(path: &Path, magic: &[&[u8]]) -> Result<u64, VoiceError> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|_| VoiceError::ModelLoadFailed)?;
    let size = file
        .metadata()
        .map_err(|_| VoiceError::ModelLoadFailed)?
        .len();
    let mut header = [0u8; 4];
    file.read_exact(&mut header)
        .map_err(|_| VoiceError::ModelLoadFailed)?;
    if !magic.iter().any(|magic| header.starts_with(magic)) {
        return Err(VoiceError::ModelLoadFailed);
    }
    Ok(size)
}

/// Maps a load failure of a readable file: `LowMemory` when available memory cannot hold it,
/// `ModelLoadFailed` otherwise. The native error is logged so the real cause is visible.
fn load_failure(stage: &'static str, error: impl std::fmt::Display, model_size: u64) -> VoiceError {
    let available = available_memory();
    tracing::error!(stage, %error, model_size, ?available, "voice model load failed");
    match available {
        Some(available) if available < model_size + model_size / 2 => VoiceError::LowMemory,
        _ => VoiceError::ModelLoadFailed,
    }
}

/// Maps a failure while running a loaded model: `LowMemory` only when the device is actually
/// short of memory (under 512 MiB available), `ModelLoadFailed` otherwise, and logs the cause.
fn run_failure(stage: &'static str, error: impl std::fmt::Display) -> VoiceError {
    let available = available_memory();
    tracing::error!(stage, %error, ?available, "voice engine step failed");
    match available {
        Some(available) if available < 512 * 1024 * 1024 => VoiceError::LowMemory,
        _ => VoiceError::ModelLoadFailed,
    }
}

fn available_memory() -> Option<u64> {
    let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
    let line = meminfo
        .lines()
        .find(|line| line.starts_with("MemAvailable:"))?;
    let kib: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kib * 1024)
}
