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
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::watch;

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

/// One model file at a pinned revision.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ModelFile {
    pub name: String,
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
    Paused(DownloadProgress),
    Ready {
        size_on_disk: u64,
    },
    Failed {
        error: ModelError,
        progress: DownloadProgress,
    },
}

/// Filesystem view of one manifest version's files.
#[derive(Clone, Debug)]
pub struct ModelStore {
    root: PathBuf,
    manifest: ModelManifest,
}

impl ModelStore {
    #[must_use]
    pub fn new(root: PathBuf, manifest: ModelManifest) -> Self {
        Self { root, manifest }
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

    fn unverified_files(&self) -> Vec<ModelFile> {
        let verified = self.verified_map();
        self.manifest
            .files
            .iter()
            .filter(|file| !self.is_verified(&verified, file))
            .cloned()
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

    /// Verified bytes plus partial bytes, over the whole set.
    #[must_use]
    pub fn done_bytes(&self) -> u64 {
        let verified = self.verified_map();
        self.manifest
            .files
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
            total_bytes: self.manifest.total_size(),
            seconds_left,
        }
    }

    /// Status as the filesystem shows it: ready, paused (bytes on disk) or not downloaded.
    #[must_use]
    pub fn derive_status(&self) -> ModelStatus {
        let remaining = self.remaining_bytes();
        if remaining == 0 {
            return ModelStatus::Ready {
                size_on_disk: self.manifest.total_size(),
            };
        }
        let progress = self.progress(None);
        if progress.done_bytes > 0 {
            ModelStatus::Paused(progress)
        } else {
            ModelStatus::NotDownloaded {
                download_bytes: remaining,
            }
        }
    }

    fn delete_parts(&self) {
        for file in &self.manifest.files {
            let _ = fs::remove_file(self.part_path(file));
        }
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
}

impl ModelManagerConfig {
    /// The bundled manifest, real free space and one-second progress.
    #[must_use]
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            manifest: ModelManifest::bundled(),
            free_space: system_free_space(),
            progress_interval: Duration::from_secs(1),
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

    /// Starts or resumes the download. A no-op while running or when ready.
    pub fn start_download(&self) -> Result<(), ModelError> {
        let mut slot = self.inner.worker.lock().expect("worker lock");
        if slot
            .as_ref()
            .is_some_and(|worker| !worker.handle.is_finished())
        {
            return Ok(());
        }
        let store = &self.inner.store;
        let pending = store.unverified_files();
        if pending.is_empty() {
            self.inner.status.send_replace(store.derive_status());
            return Ok(());
        }
        fs::create_dir_all(store.version_dir())?;
        let still_needed: u64 = pending
            .iter()
            .map(|file| file.size - store.part_bytes(file))
            .sum();
        let needed_bytes = still_needed + STORAGE_HEADROOM_BYTES;
        let available_bytes = (self.inner.free_space)(&store.version_dir())?;
        if available_bytes < needed_bytes {
            return Err(ModelError::NotEnoughStorage {
                needed_bytes,
                available_bytes,
            });
        }
        let control = Arc::new(AtomicU8::new(RUN));
        self.inner
            .status
            .send_replace(ModelStatus::Downloading(store.progress(None)));
        let inner = Arc::clone(&self.inner);
        let worker_control = Arc::clone(&control);
        let handle = std::thread::Builder::new()
            .name("model-download".into())
            .spawn(move || run_download(&inner, pending, &worker_control))
            .map_err(ModelError::from)?;
        *slot = Some(Worker { control, handle });
        Ok(())
    }

    /// Stops after the current chunk, keeping the partial bytes.
    pub fn pause_download(&self) {
        self.signal(PAUSE);
    }

    /// Stops and drops partial bytes; verified files stay.
    pub fn cancel_download(&self) {
        if !self.signal(CANCEL) {
            self.join_worker();
            self.inner.store.delete_parts();
            self.inner
                .status
                .send_replace(self.inner.store.derive_status());
        }
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

    /// Deletes the models and starts a fresh download.
    pub fn redownload_models(&self) -> Result<(), ModelError> {
        self.delete_models()?;
        self.start_download()
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

fn run_download(inner: &Inner, pending: Vec<ModelFile>, control: &AtomicU8) {
    let store = &inner.store;
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .build()
        .into();
    let started = Instant::now();
    let session_start_bytes = store.done_bytes();
    let mut last_emit = Instant::now();
    for file in pending {
        let base = store.done_bytes() - store.part_bytes(&file);
        let mut on_bytes = |file_done: u64| {
            if last_emit.elapsed() < inner.progress_interval {
                return;
            }
            last_emit = Instant::now();
            let done_bytes = base + file_done;
            let total_bytes = store.manifest().total_size();
            let session = done_bytes.saturating_sub(session_start_bytes);
            let elapsed = started.elapsed().as_secs_f64();
            let seconds_left = (session > 0 && elapsed > 0.0).then(|| {
                let rate = session as f64 / elapsed;
                (total_bytes.saturating_sub(done_bytes) as f64 / rate).ceil() as u64
            });
            inner
                .status
                .send_replace(ModelStatus::Downloading(DownloadProgress {
                    done_bytes,
                    total_bytes,
                    seconds_left,
                }));
        };
        match download_file(store, &agent, &file, control, &mut on_bytes) {
            Ok(FileOutcome::Completed) => {}
            Ok(FileOutcome::Paused) => {
                inner
                    .status
                    .send_replace(ModelStatus::Paused(store.progress(None)));
                return;
            }
            Ok(FileOutcome::Cancelled) => {
                store.delete_parts();
                inner.status.send_replace(store.derive_status());
                return;
            }
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

fn hash_existing(path: &Path, hasher: &mut Sha256) -> io::Result<()> {
    let mut file = File::open(path)?;
    let mut buffer = vec![0; READ_CHUNK_BYTES];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(());
        }
        hasher.update(&buffer[..read]);
    }
}

fn download_file(
    store: &ModelStore,
    agent: &ureq::Agent,
    file: &ModelFile,
    control: &AtomicU8,
    on_bytes: &mut dyn FnMut(u64),
) -> Result<FileOutcome, ModelError> {
    let part = store.part_path(file);
    let mut done = fs::metadata(&part).map(|meta| meta.len()).unwrap_or(0);
    if done > file.size {
        fs::remove_file(&part)?;
        done = 0;
    }
    let mut hasher = Sha256::new();
    if done > 0 {
        hash_existing(&part, &mut hasher)?;
    }
    if done < file.size {
        let mut request = agent.get(&file.url);
        if done > 0 {
            request = request.header("Range", format!("bytes={done}-"));
        }
        let response = request
            .call()
            .map_err(|error| ModelError::Network(error.to_string()))?;
        let append = match response.status().as_u16() {
            206 if done > 0 => true,
            200 => false,
            status => return Err(ModelError::HttpStatus(status)),
        };
        if !append {
            done = 0;
            hasher = Sha256::new();
        }
        let mut output = OpenOptions::new()
            .create(true)
            .write(true)
            .append(append)
            .truncate(!append)
            .open(&part)?;
        let mut reader = response.into_body().into_reader();
        let mut buffer = vec![0; READ_CHUNK_BYTES];
        let mut unflushed = 0u64;
        loop {
            let read = reader
                .read(&mut buffer)
                .map_err(|error| ModelError::Network(error.to_string()))?;
            if read == 0 {
                break;
            }
            output.write_all(&buffer[..read])?;
            hasher.update(&buffer[..read]);
            done += read as u64;
            unflushed += read as u64;
            if unflushed >= FLUSH_EVERY_BYTES {
                output.flush()?;
                unflushed = 0;
            }
            if done > file.size {
                break;
            }
            on_bytes(done);
            match control.load(Ordering::SeqCst) {
                PAUSE => {
                    output.flush()?;
                    return Ok(FileOutcome::Paused);
                }
                CANCEL => {
                    drop(output);
                    let _ = fs::remove_file(&part);
                    return Ok(FileOutcome::Cancelled);
                }
                _ => {}
            }
        }
        output.flush()?;
        output.sync_all()?;
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
        assert_eq!(manifest.files.len(), 2);
        for file in &manifest.files {
            assert!(file.url.starts_with("https://huggingface.co/"));
            assert!(!file.url.contains("/main/"), "{} is not pinned", file.url);
            assert_eq!(file.sha256.len(), 64);
            assert!(file.size > 0);
        }
        assert_eq!(manifest.files[0].name, "ggml-base.en.bin");
        assert_eq!(manifest.files[1].name, "qwen2.5-1.5b-instruct-q5_k_m.gguf");
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
