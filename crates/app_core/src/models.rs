//! On-device voice model provisioning.
//!
//! A pinned manifest (`models.json`, compiled in) lists every file voice fill
//! needs with its URL, size and SHA-256. Files are downloaded only on request
//! into `<root>/<manifest version>/`, written as `<name>.part`, resumed with
//! HTTP range requests, and moved into place only after their digest matches.
//! `verified.json` records the files whose digest matched so a restart reports
//! ready without re-hashing gigabytes.

use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, RwLock,
        atomic::{AtomicBool, AtomicU8, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::watch;
use ureq::unversioned::{
    resolver::DefaultResolver,
    transport::{
        Buffers, ConnectionDetails, Connector, NextTimeout, RustlsConnector, TcpConnector,
        Transport,
    },
};

/// Free storage that must remain after the whole download fits.
pub const STORAGE_HEADROOM_BYTES: u64 = 200_000_000;

const VERIFIED_FILE: &str = "verified.json";
const FLUSH_EVERY_BYTES: u64 = 1024 * 1024;
const READ_CHUNK_BYTES: usize = 64 * 1024;

/// The pinned list of model files.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelManifest {
    pub version: String,
    pub files: Vec<ModelFile>,
}

/// What a model file does in voice fill.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelRole {
    Speech,
    Understanding,
}

/// One model file at a pinned revision.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelFile {
    pub name: String,
    /// Friendly name shown to the user.
    pub label: String,
    pub role: ModelRole,
    /// Language code, or `None` for a model shared by every language.
    /// Required in JSON (`null` is explicit).
    #[serde(deserialize_with = "Option::deserialize")]
    pub language: Option<String>,
    pub url: String,
    pub size: u64,
    /// Lowercase hex SHA-256 digest.
    pub sha256: String,
}

impl ModelManifest {
    /// The manifest compiled into this build.
    #[must_use]
    pub fn bundled() -> Self {
        Self::parse(include_str!("models.json")).expect("bundled models.json is valid")
    }

    pub fn parse(json: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json)
    }

    /// Sum of every file's size.
    #[must_use]
    pub fn total_size(&self) -> u64 {
        self.files.iter().map(|file| file.size).sum()
    }

    /// The speech file for a language.
    #[must_use]
    pub fn speech_file(&self, language: &str) -> Option<&ModelFile> {
        self.files.iter().find(|file| {
            file.role == ModelRole::Speech && file.language.as_deref() == Some(language)
        })
    }

    /// Whether the manifest has a speech file for a language.
    #[must_use]
    pub fn has_language(&self, language: &str) -> bool {
        self.speech_file(language).is_some()
    }

    /// Files a language needs: shared files and that language's files, in
    /// manifest order.
    #[must_use]
    pub fn language_set(&self, language: &str) -> Vec<&ModelFile> {
        self.files
            .iter()
            .filter(|file| file.language.as_deref().is_none_or(|code| code == language))
            .collect()
    }

    /// Sum of the sizes of a language's set.
    #[must_use]
    pub fn set_size(&self, language: &str) -> u64 {
        self.language_set(language)
            .iter()
            .map(|file| file.size)
            .sum()
    }
}

/// Bytes done over the whole model set.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DownloadProgress {
    pub done_bytes: u64,
    pub total_bytes: u64,
    /// Estimated time left, once a rate is known.
    pub seconds_left: Option<u64>,
}

impl DownloadProgress {
    /// Whole percent done, 0..=100.
    #[must_use]
    pub fn percent(&self) -> u8 {
        if self.total_bytes == 0 {
            return 0;
        }
        let percent = self.done_bytes.min(self.total_bytes) * 100 / self.total_bytes;
        u8::try_from(percent).unwrap_or(100)
    }
}

/// Typed provisioning failures.
#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum ModelError {
    #[error("network error: {0}")]
    Network(String),
    #[error("the server answered HTTP {0}")]
    HttpStatus(u16),
    #[error("{file} did not match its checksum")]
    Checksum { file: String },
    #[error("not enough storage: {needed_bytes} bytes needed, {available_bytes} available")]
    NotEnoughStorage {
        needed_bytes: u64,
        available_bytes: u64,
    },
    #[error("storage error: {0}")]
    Io(String),
    #[error("a voice fill is in progress")]
    VoiceTurnActive,
}

impl From<io::Error> for ModelError {
    fn from(error: io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

/// The model set's state.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelStatus {
    /// Nothing usable on disk; `download_bytes` is what a download would fetch.
    NotDownloaded {
        download_bytes: u64,
    },
    Downloading(DownloadProgress),
    /// A transfer failed or stalled; waiting before retrying.
    Reconnecting(DownloadProgress),
    /// Re-hashing stored partial bytes before resuming.
    Verifying(VerifyProgress),
    Paused(DownloadProgress),
    Ready {
        size_on_disk: u64,
    },
    Failed {
        error: ModelError,
        progress: DownloadProgress,
    },
}

/// Progress of re-hashing one file's stored bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifyProgress {
    pub file: String,
    pub checked_bytes: u64,
    pub total_bytes: u64,
    /// Estimated time left, once a rate is known.
    pub seconds_left: Option<u64>,
    /// Download progress over the whole set.
    pub download: DownloadProgress,
}

/// One file's state, derived from the disk and the status.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelFileState {
    Waiting,
    Downloading,
    Checking,
    Ready,
    Damaged,
}

/// One manifest file with what is stored of it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelFileDetail {
    pub name: String,
    pub label: String,
    pub role: ModelRole,
    pub language: Option<String>,
    pub size: u64,
    pub stored_bytes: u64,
    pub state: ModelFileState,
}

/// Filesystem view of one manifest version's files.
#[derive(Clone, Debug)]
pub struct ModelStore {
    root: PathBuf,
    manifest: ModelManifest,
    /// Active voice language code; selects the speech file of the set.
    language: Arc<RwLock<String>>,
}

impl ModelStore {
    #[must_use]
    pub fn new(root: PathBuf, manifest: ModelManifest) -> Self {
        Self {
            root,
            manifest,
            language: Arc::new(RwLock::new("en".into())),
        }
    }

    /// The active language code.
    #[must_use]
    pub fn language(&self) -> String {
        self.language.read().expect("language lock").clone()
    }

    fn set_language_code(&self, code: &str) {
        *self.language.write().expect("language lock") = code.into();
    }

    /// Files of the active language's set, in manifest order.
    #[must_use]
    pub fn active_files(&self) -> Vec<ModelFile> {
        self.manifest
            .language_set(&self.language())
            .into_iter()
            .cloned()
            .collect()
    }

    /// Total size of the active language's set.
    #[must_use]
    pub fn set_size(&self) -> u64 {
        self.manifest.set_size(&self.language())
    }

    #[must_use]
    pub fn manifest(&self) -> &ModelManifest {
        &self.manifest
    }

    /// `<root>/<manifest version>/`.
    #[must_use]
    pub fn version_dir(&self) -> PathBuf {
        self.root.join(&self.manifest.version)
    }

    fn file_path(&self, file: &ModelFile) -> PathBuf {
        self.version_dir().join(&file.name)
    }

    fn part_path(&self, file: &ModelFile) -> PathBuf {
        self.version_dir().join(format!("{}.part", file.name))
    }

    fn verified_map(&self) -> BTreeMap<String, String> {
        fs::read(self.version_dir().join(VERIFIED_FILE))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn is_verified(&self, verified: &BTreeMap<String, String>, file: &ModelFile) -> bool {
        verified.get(&file.name) == Some(&file.sha256)
            && fs::metadata(self.file_path(file)).is_ok_and(|meta| meta.len() == file.size)
    }

    fn mark_verified(&self, file: &ModelFile) -> io::Result<()> {
        let mut verified = self.verified_map();
        verified.insert(file.name.clone(), file.sha256.clone());
        let path = self.version_dir().join(VERIFIED_FILE);
        let temp = self.version_dir().join(format!("{VERIFIED_FILE}.tmp"));
        fs::write(
            &temp,
            serde_json::to_vec(&verified).map_err(io::Error::other)?,
        )?;
        fs::rename(temp, path)
    }

    fn unmark_verified(&self, name: &str) -> io::Result<()> {
        let mut verified = self.verified_map();
        if verified.remove(name).is_none() {
            return Ok(());
        }
        let path = self.version_dir().join(VERIFIED_FILE);
        let temp = self.version_dir().join(format!("{VERIFIED_FILE}.tmp"));
        fs::write(
            &temp,
            serde_json::to_vec(&verified).map_err(io::Error::other)?,
        )?;
        fs::rename(temp, path)
    }

    fn unverified_files(&self) -> Vec<ModelFile> {
        let verified = self.verified_map();
        self.active_files()
            .into_iter()
            .filter(|file| !self.is_verified(&verified, file))
            .collect()
    }

    /// Sum of the manifest sizes of files not yet verified on this device.
    #[must_use]
    pub fn remaining_bytes(&self) -> u64 {
        self.unverified_files().iter().map(|file| file.size).sum()
    }

    fn part_bytes(&self, file: &ModelFile) -> u64 {
        fs::metadata(self.part_path(file))
            .map(|meta| meta.len().min(file.size))
            .unwrap_or(0)
    }

    /// Verified bytes plus partial bytes, over the active set.
    #[must_use]
    pub fn done_bytes(&self) -> u64 {
        let verified = self.verified_map();
        self.active_files()
            .iter()
            .map(|file| {
                if self.is_verified(&verified, file) {
                    file.size
                } else {
                    self.part_bytes(file)
                }
            })
            .sum()
    }

    fn progress(&self, seconds_left: Option<u64>) -> DownloadProgress {
        DownloadProgress {
            done_bytes: self.done_bytes(),
            total_bytes: self.set_size(),
            seconds_left,
        }
    }

    /// Status as the filesystem shows it: ready, paused (partial bytes of
    /// an unverified file) or not downloaded.
    #[must_use]
    pub fn derive_status(&self) -> ModelStatus {
        let unverified = self.unverified_files();
        let remaining: u64 = unverified.iter().map(|file| file.size).sum();
        if remaining == 0 {
            return ModelStatus::Ready {
                size_on_disk: self.set_size(),
            };
        }
        if unverified.iter().any(|file| self.part_bytes(file) > 0) {
            ModelStatus::Paused(self.progress(None))
        } else {
            ModelStatus::NotDownloaded {
                download_bytes: remaining,
            }
        }
    }

    /// Bytes still to fetch for unverified files, given their partial bytes.
    fn still_needed(&self) -> u64 {
        self.unverified_files()
            .iter()
            .map(|file| file.size - self.part_bytes(file))
            .sum()
    }

    /// Per-file details. Workers fetch in manifest order, so the first
    /// unverified file is the one transferring.
    #[must_use]
    pub fn file_details(&self, status: &ModelStatus) -> Vec<ModelFileDetail> {
        let verified = self.verified_map();
        let transferring = matches!(
            status,
            ModelStatus::Downloading(_) | ModelStatus::Reconnecting(_)
        );
        let mut first_unverified = true;
        self.active_files()
            .iter()
            .map(|file| {
                let ready = self.is_verified(&verified, file);
                let state = if ready {
                    ModelFileState::Ready
                } else if matches!(status, ModelStatus::Verifying(verify) if verify.file == file.name)
                {
                    ModelFileState::Checking
                } else if matches!(
                    status,
                    ModelStatus::Failed { error: ModelError::Checksum { file: damaged }, .. }
                        if *damaged == file.name
                ) {
                    ModelFileState::Damaged
                } else if transferring && first_unverified {
                    ModelFileState::Downloading
                } else {
                    ModelFileState::Waiting
                };
                if !ready {
                    first_unverified = false;
                }
                ModelFileDetail {
                    name: file.name.clone(),
                    label: file.label.clone(),
                    role: file.role,
                    language: file.language.clone(),
                    size: file.size,
                    stored_bytes: if ready {
                        file.size
                    } else {
                        self.part_bytes(file)
                    },
                    state,
                }
            })
            .collect()
    }

    /// Speech files of other languages that are verified (`Ready`) or have
    /// partial bytes (`Waiting`).
    #[must_use]
    pub fn other_speech_files(&self) -> Vec<ModelFileDetail> {
        let verified = self.verified_map();
        let language = self.language();
        self.manifest
            .files
            .iter()
            .filter(|file| {
                file.role == ModelRole::Speech
                    && file
                        .language
                        .as_deref()
                        .is_some_and(|code| code != language)
            })
            .filter_map(|file| {
                let (state, stored_bytes) = if self.is_verified(&verified, file) {
                    (ModelFileState::Ready, file.size)
                } else {
                    let part = self.part_bytes(file);
                    if part == 0 {
                        return None;
                    }
                    (ModelFileState::Waiting, part)
                };
                Some(ModelFileDetail {
                    name: file.name.clone(),
                    label: file.label.clone(),
                    role: file.role,
                    language: file.language.clone(),
                    size: file.size,
                    stored_bytes,
                    state,
                })
            })
            .collect()
    }

    /// Whether shared files must stay because another language's speech
    /// file is verified.
    fn shared_files_in_use(&self) -> bool {
        self.other_speech_files()
            .iter()
            .any(|file| file.state == ModelFileState::Ready)
    }

    /// Removes the active set's partial bytes, its speech file, and its
    /// shared files unless another language's speech file is verified.
    pub fn delete_language_set(&self) -> io::Result<()> {
        let keep_shared = self.shared_files_in_use();
        for file in self.active_files() {
            remove_if_present(&self.part_path(&file))?;
            if file.language.is_some() || !keep_shared {
                remove_if_present(&self.file_path(&file))?;
                self.unmark_verified(&file.name)?;
            }
        }
        self.remove_version_dir_if_empty()
    }

    /// Removes the version directory once it holds no model data.
    fn remove_version_dir_if_empty(&self) -> io::Result<()> {
        let Ok(entries) = fs::read_dir(self.version_dir()) else {
            return Ok(());
        };
        let holds_data = entries.flatten().any(|entry| {
            let name = entry.file_name();
            name != VERIFIED_FILE && name != format!("{VERIFIED_FILE}.tmp").as_str()
        });
        if holds_data {
            return Ok(());
        }
        match fs::remove_dir_all(self.version_dir()) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    /// Bytes `delete_language_set` would remove.
    #[must_use]
    pub fn language_set_deletable_bytes(&self) -> u64 {
        let keep_shared = self.shared_files_in_use();
        self.active_files()
            .iter()
            .map(|file| {
                let mut bytes = self.part_bytes(file);
                if file.language.is_some() || !keep_shared {
                    bytes += file_len(&self.file_path(file));
                }
                bytes
            })
            .sum()
    }

    /// Removes one language's speech file and its partial bytes, returning
    /// the bytes removed.
    pub fn delete_speech_file(&self, language: &str) -> io::Result<u64> {
        let Some(file) = self.manifest.speech_file(language).cloned() else {
            return Ok(0);
        };
        let file_path = self.file_path(&file);
        let part_path = self.part_path(&file);
        let freed = file_len(&file_path) + file_len(&part_path);
        remove_if_present(&file_path)?;
        remove_if_present(&part_path)?;
        if self.version_dir().exists() {
            self.unmark_verified(&file.name)?;
        }
        Ok(freed)
    }

    /// Removes every model file and partial download of every manifest
    /// version, returning the bytes freed.
    pub fn delete_all(&self) -> io::Result<u64> {
        let freed = dir_size(&self.root);
        match fs::remove_dir_all(&self.root) {
            Ok(()) => Ok(freed),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(0),
            Err(error) => Err(error),
        }
    }
}

fn file_len(path: &Path) -> u64 {
    fs::metadata(path).map(|meta| meta.len()).unwrap_or(0)
}

fn remove_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

fn dir_size(path: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(path) else {
        return 0;
    };
    entries
        .flatten()
        .map(|entry| match entry.metadata() {
            Ok(meta) if meta.is_dir() => dir_size(&entry.path()),
            Ok(meta) => meta.len(),
            Err(_) => 0,
        })
        .sum()
}

/// Reports free bytes on the volume holding a path.
pub type FreeSpaceFn = Arc<dyn Fn(&Path) -> io::Result<u64> + Send + Sync>;

/// Free space from the filesystem via `fs4`.
#[must_use]
pub fn system_free_space() -> FreeSpaceFn {
    Arc::new(|path| fs4::available_space(path))
}

pub struct ModelManagerConfig {
    /// `<app data>/models`.
    pub root: PathBuf,
    pub manifest: ModelManifest,
    pub free_space: FreeSpaceFn,
    /// Minimum time between progress events.
    pub progress_interval: Duration,
    /// Time without a received byte that counts as a stall.
    pub stall_timeout: Duration,
    /// Longest a blocking wait lasts before control and stall checks run.
    pub poll_interval: Duration,
    /// Waits between retries; the last one repeats.
    pub retry_delays: Vec<Duration>,
    /// Consecutive attempts without a byte before failing.
    pub max_silent_attempts: u32,
}

impl ModelManagerConfig {
    /// The bundled manifest, real free space, one-second progress, a 15 s
    /// stall timeout and retries after 1, 2, 4, 8, 16 then 30 s.
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            manifest: ModelManifest::bundled(),
            free_space: system_free_space(),
            progress_interval: Duration::from_secs(1),
            stall_timeout: Duration::from_secs(15),
            poll_interval: Duration::from_millis(250),
            retry_delays: [1, 2, 4, 8, 16, 30]
                .into_iter()
                .map(Duration::from_secs)
                .collect(),
            max_silent_attempts: 6,
        }
    }
}

const RUN: u8 = 0;
const PAUSE: u8 = 1;
const CANCEL: u8 = 2;

struct Worker {
    control: Arc<AtomicU8>,
    handle: JoinHandle<()>,
}

struct Inner {
    store: ModelStore,
    free_space: FreeSpaceFn,
    progress_interval: Duration,
    stall_timeout: Duration,
    poll_interval: Duration,
    retry_delays: Vec<Duration>,
    max_silent_attempts: u32,
    status: watch::Sender<ModelStatus>,
    worker: Mutex<Option<Worker>>,
    voice_turn_active: AtomicBool,
}

/// Owns downloads and status for one models directory.
#[derive(Clone)]
pub struct ModelManager {
    inner: Arc<Inner>,
}

enum FileOutcome {
    Completed,
    Paused,
    Cancelled,
}

impl ModelManager {
    #[must_use]
    pub fn new(config: ModelManagerConfig) -> Self {
        let store = ModelStore::new(config.root, config.manifest);
        let (status, _) = watch::channel(store.derive_status());
        Self {
            inner: Arc::new(Inner {
                store,
                free_space: config.free_space,
                progress_interval: config.progress_interval,
                stall_timeout: config.stall_timeout,
                poll_interval: config.poll_interval,
                retry_delays: config.retry_delays,
                max_silent_attempts: config.max_silent_attempts,
                status,
                worker: Mutex::new(None),
                voice_turn_active: AtomicBool::new(false),
            }),
        }
    }

    #[must_use]
    pub fn store(&self) -> &ModelStore {
        &self.inner.store
    }

    #[must_use]
    pub fn status(&self) -> ModelStatus {
        self.inner.status.borrow().clone()
    }

    /// Emits the current status and every change after it.
    #[must_use]
    pub fn subscribe(&self) -> watch::Receiver<ModelStatus> {
        self.inner.status.subscribe()
    }

    /// Set while a voice turn runs; delete and re-download refuse meanwhile.
    pub fn set_voice_turn_active(&self, active: bool) {
        self.inner.voice_turn_active.store(active, Ordering::SeqCst);
    }

    fn is_running(&self) -> bool {
        self.inner
            .worker
            .lock()
            .expect("worker lock")
            .as_ref()
            .is_some_and(|worker| !worker.handle.is_finished())
    }

    /// Starts or resumes the download. A no-op while downloading,
    /// reconnecting or verifying, and when ready. A worker that is still
    /// stopping is stopped and joined first, so only one worker writes.
    pub fn start_download(&self) -> Result<(), ModelError> {
        let old = {
            let mut slot = self.inner.worker.lock().expect("worker lock");
            if self.is_active(slot.as_ref()) {
                return Ok(());
            }
            slot.take()
        };
        if let Some(worker) = old {
            worker.control.store(PAUSE, Ordering::SeqCst);
            let _ = worker.handle.join();
        }
        let mut slot = self.inner.worker.lock().expect("worker lock");
        if slot
            .as_ref()
            .is_some_and(|worker| !worker.handle.is_finished())
        {
            // Another start won the race while the old worker stopped.
            return Ok(());
        }
        let store = &self.inner.store;
        let pending = store.unverified_files();
        if pending.is_empty() {
            self.inner.status.send_replace(store.derive_status());
            return Ok(());
        }
        fs::create_dir_all(store.version_dir())?;
        let needed_bytes = store.still_needed() + STORAGE_HEADROOM_BYTES;
        let available_bytes = (self.inner.free_space)(&store.version_dir())?;
        if available_bytes < needed_bytes {
            let error = ModelError::NotEnoughStorage {
                needed_bytes,
                available_bytes,
            };
            self.inner.status.send_replace(ModelStatus::Failed {
                error: error.clone(),
                progress: store.progress(None),
            });
            return Err(error);
        }
        let control = Arc::new(AtomicU8::new(RUN));
        let progress = store.progress(None);
        let first = &pending[0];
        let stored = store.part_bytes(first);
        self.inner.status.send_replace(if stored > 0 {
            ModelStatus::Verifying(VerifyProgress {
                file: first.name.clone(),
                checked_bytes: 0,
                total_bytes: stored,
                seconds_left: None,
                download: progress,
            })
        } else {
            ModelStatus::Downloading(progress)
        });
        let inner = Arc::clone(&self.inner);
        let worker_control = Arc::clone(&control);
        let handle = std::thread::Builder::new()
            .name("model-download".into())
            .spawn(move || run_download(&inner, pending, &worker_control))
            .map_err(ModelError::from)?;
        *slot = Some(Worker { control, handle });
        Ok(())
    }

    /// A live worker told to run while the status shows it working.
    fn is_active(&self, worker: Option<&Worker>) -> bool {
        worker.is_some_and(|worker| {
            !worker.handle.is_finished() && worker.control.load(Ordering::SeqCst) == RUN
        }) && matches!(
            *self.inner.status.borrow(),
            ModelStatus::Downloading(_) | ModelStatus::Reconnecting(_) | ModelStatus::Verifying(_)
        )
    }

    /// Stops within about one poll slice, keeping the stored bytes.
    pub fn pause_download(&self) {
        self.signal(PAUSE);
    }

    /// Selects the voice language's model set. An unknown code selects
    /// English. A running download stops first, keeping its stored bytes.
    pub fn set_language(&self, code: &str) {
        let store = &self.inner.store;
        let code = if store.manifest().has_language(code) {
            code
        } else {
            "en"
        };
        if store.language() == code {
            return;
        }
        self.stop_worker();
        store.set_language_code(code);
        self.inner.status.send_replace(store.derive_status());
    }

    /// Takes a live worker out of the slot, pauses it and joins it outside
    /// the lock.
    fn stop_worker(&self) {
        let old = self.inner.worker.lock().expect("worker lock").take();
        if let Some(worker) = old {
            worker.control.store(PAUSE, Ordering::SeqCst);
            let _ = worker.handle.join();
        }
    }

    /// Stops and deletes the active set's data: its partial bytes, its
    /// speech file, and shared files no other language still uses.
    pub fn cancel_download(&self) {
        self.signal(CANCEL);
        self.join_worker();
        let _ = self.inner.store.delete_language_set();
        self.inner
            .status
            .send_replace(self.inner.store.derive_status());
    }

    /// Returns whether a running worker received the signal.
    fn signal(&self, value: u8) -> bool {
        let slot = self.inner.worker.lock().expect("worker lock");
        match slot.as_ref() {
            Some(worker) if !worker.handle.is_finished() => {
                worker.control.store(value, Ordering::SeqCst);
                true
            }
            _ => false,
        }
    }

    fn join_worker(&self) {
        let worker = self.inner.worker.lock().expect("worker lock").take();
        if let Some(worker) = worker {
            let _ = worker.handle.join();
        }
    }

    /// Removes every model file and partial download, returning bytes freed.
    pub fn delete_models(&self) -> Result<u64, ModelError> {
        if self.inner.voice_turn_active.load(Ordering::SeqCst) {
            return Err(ModelError::VoiceTurnActive);
        }
        self.signal(CANCEL);
        self.join_worker();
        let freed = self.inner.store.delete_all()?;
        self.inner
            .status
            .send_replace(self.inner.store.derive_status());
        Ok(freed)
    }

    /// Deletes the active set and starts a fresh download.
    pub fn redownload_models(&self) -> Result<(), ModelError> {
        if self.inner.voice_turn_active.load(Ordering::SeqCst) {
            return Err(ModelError::VoiceTurnActive);
        }
        self.signal(CANCEL);
        self.join_worker();
        self.inner.store.delete_language_set()?;
        self.inner
            .status
            .send_replace(self.inner.store.derive_status());
        self.start_download()
    }

    /// Removes one language's speech model, returning the bytes freed.
    pub fn delete_speech_model(&self, language: &str) -> Result<u64, ModelError> {
        if self.inner.voice_turn_active.load(Ordering::SeqCst) {
            return Err(ModelError::VoiceTurnActive);
        }
        let store = &self.inner.store;
        if language == store.language() {
            self.stop_worker();
        }
        let freed = store.delete_speech_file(language)?;
        self.inner.status.send_replace(store.derive_status());
        Ok(freed)
    }

    /// Blocks until the running download, if any, stops. For tests and shutdown.
    pub fn wait(&self) {
        self.join_worker();
    }

    #[doc(hidden)]
    #[must_use]
    pub fn running(&self) -> bool {
        self.is_running()
    }
}

/// State shared by a worker and the watchdog under its transport.
#[derive(Debug)]
struct Watch {
    control: Arc<AtomicU8>,
    last_byte: Mutex<Instant>,
    poll: Duration,
    stall_timeout: Duration,
}

impl Watch {
    fn touch(&self) {
        *self.last_byte.lock().expect("watch lock") = Instant::now();
    }

    fn stalled(&self) -> bool {
        self.last_byte.lock().expect("watch lock").elapsed() >= self.stall_timeout
    }
}

/// Wraps the TCP transport so no read blocks longer than one poll slice.
#[derive(Debug)]
struct WatchdogConnector {
    watch: Arc<Watch>,
}

impl<In: Transport> Connector<In> for WatchdogConnector {
    type Out = WatchdogTransport<In>;

    fn connect(
        &self,
        _details: &ConnectionDetails,
        chained: Option<In>,
    ) -> Result<Option<Self::Out>, ureq::Error> {
        Ok(chained.map(|inner| WatchdogTransport {
            inner,
            watch: Arc::clone(&self.watch),
        }))
    }
}

#[derive(Debug)]
struct WatchdogTransport<T> {
    inner: T,
    watch: Arc<Watch>,
}

impl<T: Transport> Transport for WatchdogTransport<T> {
    fn buffers(&mut self) -> &mut dyn Buffers {
        self.inner.buffers()
    }

    fn transmit_output(&mut self, amount: usize, timeout: NextTimeout) -> Result<(), ureq::Error> {
        self.inner.transmit_output(amount, timeout)
    }

    /// Waits in poll slices. Stops with `Interrupted` once control leaves
    /// `RUN` and with `TimedOut` after a stall; a timed-out socket read
    /// consumes nothing, so looping is safe.
    fn await_input(&mut self, timeout: NextTimeout) -> Result<bool, ureq::Error> {
        let deadline = (!timeout.after.is_not_happening()).then(|| Instant::now() + *timeout.after);
        loop {
            let slice = NextTimeout {
                after: (*timeout.after).min(self.watch.poll).into(),
                reason: timeout.reason,
            };
            match self.inner.await_input(slice) {
                Ok(progress) => {
                    if progress {
                        self.watch.touch();
                    }
                    return Ok(progress);
                }
                Err(ureq::Error::Timeout(_)) => {
                    if self.watch.control.load(Ordering::SeqCst) != RUN {
                        return Err(ureq::Error::Io(io::Error::new(
                            io::ErrorKind::Interrupted,
                            "download stopped",
                        )));
                    }
                    if self.watch.stalled() {
                        return Err(ureq::Error::Io(io::Error::new(
                            io::ErrorKind::TimedOut,
                            "stalled",
                        )));
                    }
                    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                        return Err(ureq::Error::Timeout(timeout.reason));
                    }
                }
                Err(error) => return Err(error),
            }
        }
    }

    fn is_open(&mut self) -> bool {
        self.inner.is_open()
    }

    fn is_tls(&self) -> bool {
        self.inner.is_tls()
    }
}

/// Sends status events for one worker run.
struct Reporter<'a> {
    inner: &'a Inner,
    /// Start of the rate window for time-left estimates.
    started: Instant,
    window_start_bytes: u64,
    last_emit: Option<Instant>,
    /// Done bytes of every file except the current one.
    base: u64,
}

impl Reporter<'_> {
    fn due(&mut self) -> bool {
        if self
            .last_emit
            .is_some_and(|last| last.elapsed() < self.inner.progress_interval)
        {
            return false;
        }
        self.last_emit = Some(Instant::now());
        true
    }

    fn progress(&self, file_done: u64) -> DownloadProgress {
        let done_bytes = self.base + file_done;
        let total_bytes = self.inner.store.set_size();
        let window = done_bytes.saturating_sub(self.window_start_bytes);
        let elapsed = self.started.elapsed().as_secs_f64();
        let seconds_left = (window > 0 && elapsed > 0.0).then(|| {
            let rate = window as f64 / elapsed;
            (total_bytes.saturating_sub(done_bytes) as f64 / rate).ceil() as u64
        });
        DownloadProgress {
            done_bytes,
            total_bytes,
            seconds_left,
        }
    }

    /// Restarts the rate window and makes the next event immediate.
    fn restart(&mut self, file_done: u64) {
        self.started = Instant::now();
        self.window_start_bytes = self.base + file_done;
        self.last_emit = None;
    }

    fn downloading(&mut self, file_done: u64) {
        if self.due() {
            let progress = self.progress(file_done);
            self.inner
                .status
                .send_replace(ModelStatus::Downloading(progress));
        }
    }

    fn reconnecting(&mut self, file_done: u64) {
        let mut progress = self.progress(file_done);
        progress.seconds_left = None;
        self.inner
            .status
            .send_replace(ModelStatus::Reconnecting(progress));
        self.last_emit = None;
    }

    fn verifying(&mut self, file: &ModelFile, checked: u64, total: u64) {
        if !self.due() {
            return;
        }
        let elapsed = self.started.elapsed().as_secs_f64();
        let seconds_left = (checked > 0 && elapsed > 0.0).then(|| {
            let rate = checked as f64 / elapsed;
            (total.saturating_sub(checked) as f64 / rate).ceil() as u64
        });
        let mut download = self.progress(total);
        download.seconds_left = None;
        self.inner
            .status
            .send_replace(ModelStatus::Verifying(VerifyProgress {
                file: file.name.clone(),
                checked_bytes: checked,
                total_bytes: total,
                seconds_left,
                download,
            }));
    }
}

fn run_download(inner: &Inner, pending: Vec<ModelFile>, control: &Arc<AtomicU8>) {
    let store = &inner.store;
    let watch = Arc::new(Watch {
        control: Arc::clone(control),
        last_byte: Mutex::new(Instant::now()),
        poll: inner.poll_interval,
        stall_timeout: inner.stall_timeout,
    });
    let config = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .build();
    let connector = ()
        .chain(TcpConnector::default())
        .chain(WatchdogConnector {
            watch: Arc::clone(&watch),
        })
        .chain(RustlsConnector::default());
    let agent = ureq::Agent::with_parts(config, connector, DefaultResolver::default());
    let mut reporter = Reporter {
        inner,
        started: Instant::now(),
        window_start_bytes: 0,
        last_emit: None,
        base: 0,
    };
    for file in pending {
        reporter.base = store.done_bytes() - store.part_bytes(&file);
        let download = Download {
            inner,
            agent: &agent,
            watch: &watch,
            control,
        };
        match download.file(&file, &mut reporter) {
            Ok(FileOutcome::Completed) => {}
            Ok(FileOutcome::Paused) => {
                inner
                    .status
                    .send_replace(ModelStatus::Paused(store.progress(None)));
                return;
            }
            // The caller deletes the data and sends the status.
            Ok(FileOutcome::Cancelled) => return,
            Err(error) => {
                inner.status.send_replace(ModelStatus::Failed {
                    error,
                    progress: store.progress(None),
                });
                return;
            }
        }
    }
    inner.status.send_replace(store.derive_status());
}

/// Maps a control value to the outcome it asks for.
fn stop_outcome(control: &AtomicU8) -> Option<FileOutcome> {
    match control.load(Ordering::SeqCst) {
        PAUSE => Some(FileOutcome::Paused),
        CANCEL => Some(FileOutcome::Cancelled),
        _ => None,
    }
}

/// Re-hashes stored bytes in chunks, reporting progress and stopping on control.
fn hash_existing(
    path: &Path,
    hasher: &mut Sha256,
    control: &AtomicU8,
    on_progress: &mut dyn FnMut(u64),
) -> io::Result<FileOutcome> {
    let mut file = File::open(path)?;
    let mut buffer = vec![0; READ_CHUNK_BYTES];
    let mut checked = 0u64;
    on_progress(0);
    loop {
        if let Some(outcome) = stop_outcome(control) {
            return Ok(outcome);
        }
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(FileOutcome::Completed);
        }
        hasher.update(&buffer[..read]);
        checked += read as u64;
        on_progress(checked);
    }
}

/// How one request ended short of the whole file.
enum AttemptError {
    /// Worth retrying: transport error, stall or HTTP 408/429/5xx.
    Retry(String),
    Fail(ModelError),
}

struct Download<'a> {
    inner: &'a Inner,
    agent: &'a ureq::Agent,
    watch: &'a Watch,
    control: &'a AtomicU8,
}

impl Download<'_> {
    fn file(&self, file: &ModelFile, reporter: &mut Reporter) -> Result<FileOutcome, ModelError> {
        let store = &self.inner.store;
        let part = store.part_path(file);
        let mut done = fs::metadata(&part).map(|meta| meta.len()).unwrap_or(0);
        if done > file.size {
            fs::remove_file(&part)?;
            done = 0;
        }
        let mut hasher = Sha256::new();
        if done > 0 {
            reporter.restart(0);
            let outcome = hash_existing(&part, &mut hasher, self.control, &mut |checked| {
                reporter.verifying(file, checked, done);
            })?;
            if !matches!(outcome, FileOutcome::Completed) {
                return Ok(outcome);
            }
        }
        reporter.restart(done);
        reporter.downloading(done);
        let mut silent_attempts = 0u32;
        let mut delay_index = 0usize;
        while done < file.size {
            let before = done;
            let error = match self.attempt(file, &part, &mut done, &mut hasher, reporter) {
                Ok(None) if done >= file.size => break,
                Ok(None) => AttemptError::Retry("the connection closed early".into()),
                Ok(Some(outcome)) => return Ok(outcome),
                Err(error) => error,
            };
            // A stop request surfaces as a transport error; never report it as one.
            if let Some(outcome) = stop_outcome(self.control) {
                return Ok(outcome);
            }
            let message = match error {
                AttemptError::Fail(error) => return Err(error),
                AttemptError::Retry(message) => message,
            };
            if done > before {
                silent_attempts = 0;
                delay_index = 0;
            } else {
                silent_attempts += 1;
                if silent_attempts >= self.inner.max_silent_attempts {
                    return Err(ModelError::Network(message));
                }
            }
            reporter.reconnecting(done);
            let delays = &self.inner.retry_delays;
            let delay = delays
                .get(delay_index.min(delays.len().saturating_sub(1)))
                .copied()
                .unwrap_or_default();
            delay_index += 1;
            if let Some(outcome) = self.sleep(delay) {
                return Ok(outcome);
            }
        }
        let digest = hex::encode(hasher.finalize());
        if done != file.size || !digest.eq_ignore_ascii_case(&file.sha256) {
            let _ = fs::remove_file(&part);
            return Err(ModelError::Checksum {
                file: file.name.clone(),
            });
        }
        fs::rename(&part, store.file_path(file))?;
        store.mark_verified(file)?;
        Ok(FileOutcome::Completed)
    }

    /// Waits in poll slices, returning early when control asks to stop.
    fn sleep(&self, delay: Duration) -> Option<FileOutcome> {
        let end = Instant::now() + delay;
        loop {
            if let Some(outcome) = stop_outcome(self.control) {
                return Some(outcome);
            }
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return None;
            }
            std::thread::sleep(left.min(self.inner.poll_interval));
        }
    }

    /// One request from the stored length. `Ok(None)` means the body ended:
    /// the file is complete or the server closed early.
    fn attempt(
        &self,
        file: &ModelFile,
        part: &Path,
        done: &mut u64,
        hasher: &mut Sha256,
        reporter: &mut Reporter,
    ) -> Result<Option<FileOutcome>, AttemptError> {
        let io_fail = |error: io::Error| AttemptError::Fail(ModelError::from(error));
        self.watch.touch();
        let mut request = self.agent.get(&file.url);
        if *done > 0 {
            request = request.header("Range", format!("bytes={done}-"));
        }
        let response = request
            .call()
            .map_err(|error| AttemptError::Retry(error.to_string()))?;
        let append = match response.status().as_u16() {
            206 if *done > 0 => true,
            200 => false,
            status @ (408 | 429 | 500..=599) => {
                return Err(AttemptError::Retry(format!(
                    "the server answered HTTP {status}"
                )));
            }
            status => return Err(AttemptError::Fail(ModelError::HttpStatus(status))),
        };
        if !append {
            *done = 0;
            *hasher = Sha256::new();
        }
        let mut output = OpenOptions::new()
            .create(true)
            .write(true)
            .append(append)
            .truncate(!append)
            .open(part)
            .map_err(io_fail)?;
        let mut reader = response.into_body().into_reader();
        let mut buffer = vec![0; READ_CHUNK_BYTES];
        let mut unflushed = 0u64;
        loop {
            let read = match reader.read(&mut buffer) {
                Ok(read) => read,
                Err(error) => {
                    let _ = output.flush();
                    return Err(AttemptError::Retry(error.to_string()));
                }
            };
            if read == 0 {
                break;
            }
            if let Err(error) = output.write_all(&buffer[..read]) {
                return Err(self.write_error(error));
            }
            hasher.update(&buffer[..read]);
            *done += read as u64;
            unflushed += read as u64;
            if unflushed >= FLUSH_EVERY_BYTES {
                output.flush().map_err(|error| self.write_error(error))?;
                unflushed = 0;
            }
            if *done > file.size {
                break;
            }
            reporter.downloading(*done);
            if let Some(outcome) = stop_outcome(self.control) {
                output.flush().map_err(io_fail)?;
                return Ok(Some(outcome));
            }
        }
        output.flush().map_err(|error| self.write_error(error))?;
        output.sync_all().map_err(|error| self.write_error(error))?;
        Ok(None)
    }

    /// A full disk is the typed storage reason; other write errors are I/O.
    fn write_error(&self, error: io::Error) -> AttemptError {
        if error.kind() != io::ErrorKind::StorageFull {
            return AttemptError::Fail(ModelError::from(error));
        }
        let store = &self.inner.store;
        AttemptError::Fail(ModelError::NotEnoughStorage {
            needed_bytes: store.still_needed() + STORAGE_HEADROOM_BYTES,
            available_bytes: (self.inner.free_space)(&store.version_dir()).unwrap_or(0),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(version: &str, sizes: &[u64]) -> ModelManifest {
        ModelManifest {
            version: version.into(),
            files: sizes
                .iter()
                .enumerate()
                .map(|(index, size)| ModelFile {
                    name: format!("file{index}.bin"),
                    label: format!("File {index}"),
                    role: if index == 0 {
                        ModelRole::Speech
                    } else {
                        ModelRole::Understanding
                    },
                    language: (index == 0).then(|| "en".into()),
                    url: format!("http://127.0.0.1:1/file{index}.bin"),
                    size: *size,
                    sha256: "00".into(),
                })
                .collect(),
        }
    }

    fn place_verified(store: &ModelStore, index: usize) {
        let file = &store.manifest().files[index];
        fs::create_dir_all(store.version_dir()).unwrap();
        fs::write(store.file_path(file), vec![0; file.size as usize]).unwrap();
        store.mark_verified(file).unwrap();
    }

    #[test]
    fn bundled_manifest_parses_with_pinned_files() {
        let manifest = ModelManifest::bundled();
        assert_eq!(manifest.files.len(), 3);
        for file in &manifest.files {
            assert!(file.url.starts_with("https://huggingface.co/"));
            assert!(!file.url.contains("/main/"), "{} is not pinned", file.url);
            assert_eq!(file.sha256.len(), 64);
            assert!(file.size > 0);
        }
        assert_eq!(manifest.files[0].name, "ggml-base.en.bin");
        assert_eq!(manifest.files[1].name, "ggml-base.bin");
        assert_eq!(manifest.files[2].name, "qwen2.5-1.5b-instruct-q5_k_m.gguf");
        assert_eq!(manifest.files[0].label, "Whisper Base (English)");
        assert_eq!(manifest.files[0].role, ModelRole::Speech);
        assert_eq!(manifest.files[0].language.as_deref(), Some("en"));
        assert_eq!(manifest.files[1].label, "Whisper Base (Spanish)");
        assert_eq!(manifest.files[1].role, ModelRole::Speech);
        assert_eq!(manifest.files[1].language.as_deref(), Some("es"));
        assert_eq!(manifest.files[1].size, 147_951_465);
        assert_eq!(manifest.files[2].label, "Qwen2.5 1.5B Instruct");
        assert_eq!(manifest.files[2].role, ModelRole::Understanding);
        assert_eq!(manifest.files[2].language, None);
        assert_eq!(manifest.set_size("en"), 1_433_458_515);
        assert_eq!(manifest.set_size("es"), 1_433_445_769);
    }

    #[test]
    fn language_is_required_in_json() {
        let json = r#"{"version":"v","files":[{"name":"a","label":"A","role":"speech",
            "url":"u","size":1,"sha256":"00"}]}"#;
        assert!(ModelManifest::parse(json).is_err());
    }

    fn states(store: &ModelStore, status: &ModelStatus) -> Vec<(ModelFileState, u64)> {
        store
            .file_details(status)
            .into_iter()
            .map(|detail| (detail.state, detail.stored_bytes))
            .collect()
    }

    fn progress() -> DownloadProgress {
        DownloadProgress {
            done_bytes: 0,
            total_bytes: 40,
            seconds_left: None,
        }
    }

    #[test]
    fn file_details_follow_the_status() {
        let dir = tempfile::tempdir().unwrap();
        let store = ModelStore::new(dir.path().to_path_buf(), manifest("v1", &[10, 30]));
        let idle = store.derive_status();
        assert_eq!(
            states(&store, &idle),
            [(ModelFileState::Waiting, 0), (ModelFileState::Waiting, 0)]
        );
        let downloading = ModelStatus::Downloading(progress());
        assert_eq!(
            states(&store, &downloading),
            [
                (ModelFileState::Downloading, 0),
                (ModelFileState::Waiting, 0)
            ]
        );

        place_verified(&store, 0);
        fs::write(store.part_path(&store.manifest().files[1]), [0; 5]).unwrap();
        assert_eq!(
            states(&store, &ModelStatus::Reconnecting(progress())),
            [
                (ModelFileState::Ready, 10),
                (ModelFileState::Downloading, 5)
            ]
        );
        let verifying = ModelStatus::Verifying(VerifyProgress {
            file: "file1.bin".into(),
            checked_bytes: 0,
            total_bytes: 5,
            seconds_left: None,
            download: progress(),
        });
        assert_eq!(
            states(&store, &verifying),
            [(ModelFileState::Ready, 10), (ModelFileState::Checking, 5)]
        );
        let damaged = ModelStatus::Failed {
            error: ModelError::Checksum {
                file: "file1.bin".into(),
            },
            progress: progress(),
        };
        assert_eq!(
            states(&store, &damaged),
            [(ModelFileState::Ready, 10), (ModelFileState::Damaged, 5)]
        );
        assert_eq!(
            states(&store, &store.derive_status()),
            [(ModelFileState::Ready, 10), (ModelFileState::Waiting, 5)]
        );
        let detail = &store.file_details(&idle)[0];
        assert_eq!(detail.label, "File 0");
        assert_eq!(detail.role, ModelRole::Speech);
        assert_eq!(detail.language.as_deref(), Some("en"));
        assert_eq!(detail.size, 10);
    }

    #[test]
    fn empty_store_is_not_downloaded_with_the_manifest_sum() {
        let dir = tempfile::tempdir().unwrap();
        let store = ModelStore::new(
            dir.path().to_path_buf(),
            manifest("v1", &[148_000_000, 1_130_000_000]),
        );
        assert_eq!(
            store.derive_status(),
            ModelStatus::NotDownloaded {
                download_bytes: 1_278_000_000
            }
        );
    }

    #[test]
    fn remaining_size_skips_verified_files_and_parts_mean_paused() {
        let dir = tempfile::tempdir().unwrap();
        let store = ModelStore::new(dir.path().to_path_buf(), manifest("v1", &[10, 30]));
        place_verified(&store, 0);
        assert_eq!(store.remaining_bytes(), 30);
        fs::write(store.part_path(&store.manifest().files[1]), [0; 5]).unwrap();
        assert_eq!(
            store.derive_status(),
            ModelStatus::Paused(DownloadProgress {
                done_bytes: 15,
                total_bytes: 40,
                seconds_left: None
            })
        );
        place_verified(&store, 1);
        assert_eq!(
            store.derive_status(),
            ModelStatus::Ready { size_on_disk: 40 }
        );
    }

    #[test]
    fn verified_shared_file_alone_is_not_downloaded() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = manifest("v1", &[10, 20, 30]);
        manifest.files[1].role = ModelRole::Speech;
        manifest.files[1].language = Some("es".into());
        manifest.files[2].language = None;
        let store = ModelStore::new(dir.path().to_path_buf(), manifest);
        place_verified(&store, 2);
        store.set_language_code("es");
        assert_eq!(
            store.derive_status(),
            ModelStatus::NotDownloaded { download_bytes: 20 }
        );
    }

    #[test]
    fn a_new_manifest_version_is_not_ready_until_its_files_verify() {
        let dir = tempfile::tempdir().unwrap();
        let old = ModelStore::new(dir.path().to_path_buf(), manifest("v1", &[10]));
        place_verified(&old, 0);
        assert!(matches!(old.derive_status(), ModelStatus::Ready { .. }));
        let new = ModelStore::new(dir.path().to_path_buf(), manifest("v2", &[10]));
        assert_eq!(
            new.derive_status(),
            ModelStatus::NotDownloaded { download_bytes: 10 }
        );
    }

    #[test]
    fn a_verified_entry_with_a_different_digest_does_not_count() {
        let dir = tempfile::tempdir().unwrap();
        let store = ModelStore::new(dir.path().to_path_buf(), manifest("v1", &[10]));
        place_verified(&store, 0);
        let mut changed = store.manifest().clone();
        changed.files[0].sha256 = "11".into();
        let store = ModelStore::new(dir.path().to_path_buf(), changed);
        assert_eq!(store.remaining_bytes(), 10);
    }

    #[test]
    fn percent_rounds_down() {
        let progress = DownloadProgress {
            done_bytes: 494,
            total_bytes: 1300,
            seconds_left: None,
        };
        assert_eq!(progress.percent(), 38);
    }
}
