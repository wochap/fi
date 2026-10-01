//! Model downloads against a local `tiny_http` fixture server.

use std::{
    io::{self, Read},
    path::Path,
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver},
    },
    thread,
    time::{Duration, Instant},
};

use app_core::models::{
    DownloadProgress, ModelError, ModelFile, ModelManager, ModelManagerConfig, ModelManifest,
    ModelRole, ModelStatus, STORAGE_HEADROOM_BYTES,
};
use sha2::{Digest, Sha256};

const FIXTURE_LEN: usize = 256 * 1024;

fn fixture() -> Vec<u8> {
    (0..FIXTURE_LEN).map(|index| (index % 251) as u8).collect()
}

#[derive(Default)]
struct ServerLog {
    ranges: Vec<Option<String>>,
}

/// Sends the first `stall_after` bytes, then waits for the gate before the rest.
struct GatedReader {
    data: Vec<u8>,
    position: usize,
    stall_after: usize,
    gate: Option<Receiver<()>>,
}

impl Read for GatedReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.position == self.stall_after
            && let Some(gate) = self.gate.take()
        {
            let _ = gate.recv();
        }
        let limit = if self.gate.is_some() {
            self.stall_after
        } else {
            self.data.len()
        };
        let count = buffer.len().min(limit - self.position).min(16 * 1024);
        buffer[..count].copy_from_slice(&self.data[self.position..self.position + count]);
        self.position += count;
        Ok(count)
    }
}

struct Server {
    url: String,
    log: Arc<Mutex<ServerLog>>,
}

/// How the server answers one request.
enum Reply {
    /// The body (from the requested range), stalling forever after this many
    /// bytes when set.
    Body { stall_after: Option<usize> },
    /// This status with an empty body.
    Status(u16),
}

/// Serves `data` at `/model.bin`. With `ranges`, honours `Range: bytes=n-`.
/// The first response stalls after `stall_after` bytes until `gate` fires.
fn serve(data: Vec<u8>, ranges: bool, stall: Option<(usize, Receiver<()>)>) -> Server {
    serve_plan(data, ranges, stall, |_| Reply::Body { stall_after: None })
}

/// Like `serve`, with `plan` choosing the reply for each request by index.
fn serve_plan(
    data: Vec<u8>,
    ranges: bool,
    stall: Option<(usize, Receiver<()>)>,
    plan: impl Fn(usize) -> Reply + Send + 'static,
) -> Server {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}/model.bin", server.server_addr());
    let log = Arc::new(Mutex::new(ServerLog::default()));
    let server_log = Arc::clone(&log);
    thread::spawn(move || {
        let mut stall = stall;
        // Senders of gates that never open.
        let mut closed_gates = Vec::new();
        for (index, request) in server.incoming_requests().enumerate() {
            let range = request
                .headers()
                .iter()
                .find(|header| header.field.equiv("Range"))
                .map(|header| header.value.to_string());
            server_log.lock().unwrap().ranges.push(range.clone());
            let start = range
                .filter(|_| ranges)
                .and_then(|value| {
                    value
                        .strip_prefix("bytes=")?
                        .trim_end_matches('-')
                        .parse::<usize>()
                        .ok()
                })
                .unwrap_or(0);
            let planned_stall = match plan(index) {
                Reply::Status(code) => {
                    thread::spawn(move || {
                        let _ = request.respond(tiny_http::Response::empty(code));
                    });
                    continue;
                }
                Reply::Body { stall_after } => stall_after,
            };
            let body = data[start..].to_vec();
            let status = if start > 0 { 206 } else { 200 };
            let (stall_after, gate) = match (stall.take(), planned_stall) {
                (Some((after, gate)), _) => (after, Some(gate)),
                (None, Some(after)) => {
                    let (open, gate) = mpsc::channel();
                    closed_gates.push(open);
                    (after, Some(gate))
                }
                (None, None) => (body.len(), None),
            };
            let length = body.len();
            let reader = GatedReader {
                data: body,
                position: 0,
                stall_after,
                gate,
            };
            let response = tiny_http::Response::new(
                tiny_http::StatusCode(status),
                vec![],
                reader,
                Some(length),
                None,
            );
            thread::spawn(move || {
                let _ = request.respond(response);
            });
        }
    });
    Server { url, log }
}

fn manifest_for(url: &str, data: &[u8]) -> ModelManifest {
    ModelManifest {
        version: "test-1".into(),
        files: vec![model_file("model.bin", url, data)],
    }
}

fn model_file(name: &str, url: &str, data: &[u8]) -> ModelFile {
    ModelFile {
        name: name.into(),
        label: "Test model".into(),
        role: ModelRole::Speech,
        language: Some("en".into()),
        url: url.into(),
        size: data.len() as u64,
        sha256: hex::encode(Sha256::digest(data)),
    }
}

fn config(root: &Path, manifest: ModelManifest, free: u64) -> ModelManagerConfig {
    ModelManagerConfig {
        root: root.to_path_buf(),
        manifest,
        free_space: Arc::new(move |_| Ok(free)),
        progress_interval: Duration::ZERO,
        stall_timeout: Duration::from_secs(2),
        poll_interval: Duration::from_millis(10),
        retry_delays: vec![Duration::from_millis(10)],
        max_silent_attempts: 6,
    }
}

fn manager(root: &Path, manifest: ModelManifest, free: u64) -> ModelManager {
    ModelManager::new(config(root, manifest, free))
}

const PLENTY: u64 = u64::MAX / 2;

fn wait_for(manager: &ModelManager, check: impl Fn(&ModelStatus) -> bool) -> ModelStatus {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = manager.status();
        if check(&status) {
            return status;
        }
        assert!(Instant::now() < deadline, "timed out at {status:?}");
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn full_download_verifies_and_survives_restart() {
    let data = fixture();
    let server = serve(data.clone(), true, None);
    let dir = tempfile::tempdir().unwrap();
    let manifest = manifest_for(&server.url, &data);
    let models = manager(dir.path(), manifest.clone(), PLENTY);
    let events = models.subscribe();
    models.start_download().unwrap();
    models.wait();
    assert_eq!(
        models.status(),
        ModelStatus::Ready {
            size_on_disk: FIXTURE_LEN as u64
        }
    );
    assert!(events.has_changed().unwrap());
    let stored = std::fs::read(dir.path().join("test-1/model.bin")).unwrap();
    assert_eq!(stored, data);
    assert!(dir.path().join("test-1/verified.json").exists());
    assert!(!dir.path().join("test-1/model.bin.part").exists());

    let restarted = manager(dir.path(), manifest, PLENTY);
    assert!(matches!(restarted.status(), ModelStatus::Ready { .. }));
    assert_eq!(server.log.lock().unwrap().ranges.len(), 1);
}

#[test]
fn pause_then_resume_continues_from_stored_bytes() {
    let data = fixture();
    let (open_gate, gate) = mpsc::channel();
    let server = serve(data.clone(), true, Some((FIXTURE_LEN / 2, gate)));
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    models.start_download().unwrap();
    wait_for(
        &models,
        |status| matches!(status, ModelStatus::Downloading(progress) if progress.done_bytes > 0),
    );
    models.pause_download();
    open_gate.send(()).unwrap();
    models.wait();
    let ModelStatus::Paused(progress) = models.status() else {
        panic!("expected paused, got {:?}", models.status());
    };
    assert!(progress.done_bytes > 0 && progress.done_bytes < FIXTURE_LEN as u64);

    // A new manager is the app reopening at the same point.
    let reopened = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    assert!(matches!(reopened.status(), ModelStatus::Paused(_)));
    reopened.start_download().unwrap();
    reopened.wait();
    assert!(matches!(reopened.status(), ModelStatus::Ready { .. }));
    let ranges = server.log.lock().unwrap().ranges.clone();
    assert_eq!(ranges[0], None);
    assert_eq!(ranges[1], Some(format!("bytes={}-", progress.done_bytes)));
    assert_eq!(
        std::fs::read(dir.path().join("test-1/model.bin")).unwrap(),
        data
    );
}

#[test]
fn resume_without_range_support_starts_over() {
    let data = fixture();
    let server = serve(data.clone(), false, None);
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("test-1")).unwrap();
    std::fs::write(dir.path().join("test-1/model.bin.part"), &data[..1000]).unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    assert!(matches!(models.status(), ModelStatus::Paused(_)));
    models.start_download().unwrap();
    models.wait();
    assert!(matches!(models.status(), ModelStatus::Ready { .. }));
    assert_eq!(
        server.log.lock().unwrap().ranges[0],
        Some("bytes=1000-".into())
    );
    assert_eq!(
        std::fs::read(dir.path().join("test-1/model.bin")).unwrap(),
        data
    );
}

#[test]
fn checksum_mismatch_deletes_the_file_and_reports_failure() {
    let data = fixture();
    let server = serve(data.clone(), true, None);
    let dir = tempfile::tempdir().unwrap();
    let mut manifest = manifest_for(&server.url, &data);
    manifest.files[0].sha256 = "0".repeat(64);
    let models = manager(dir.path(), manifest, PLENTY);
    models.start_download().unwrap();
    models.wait();
    let ModelStatus::Failed { error, .. } = models.status() else {
        panic!("expected failure, got {:?}", models.status());
    };
    assert_eq!(
        error,
        ModelError::Checksum {
            file: "model.bin".into()
        }
    );
    assert!(!dir.path().join("test-1/model.bin").exists());
    assert!(!dir.path().join("test-1/model.bin.part").exists());
}

#[test]
fn not_enough_storage_refuses_before_downloading() {
    let data = fixture();
    let server = serve(data.clone(), true, None);
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), 1000);
    let error = models.start_download().unwrap_err();
    assert_eq!(
        error,
        ModelError::NotEnoughStorage {
            needed_bytes: FIXTURE_LEN as u64 + STORAGE_HEADROOM_BYTES,
            available_bytes: 1000
        }
    );
    assert!(server.log.lock().unwrap().ranges.is_empty());
    assert_eq!(
        models.status(),
        ModelStatus::Failed {
            error,
            progress: DownloadProgress {
                done_bytes: 0,
                total_bytes: FIXTURE_LEN as u64,
                seconds_left: None
            }
        }
    );
}

#[test]
fn http_errors_are_typed() {
    let dir = tempfile::tempdir().unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}/missing.bin", server.server_addr());
    thread::spawn(move || {
        for request in server.incoming_requests() {
            let _ = request.respond(tiny_http::Response::empty(404));
        }
    });
    let models = manager(dir.path(), manifest_for(&url, b"x"), PLENTY);
    models.start_download().unwrap();
    models.wait();
    assert!(matches!(
        models.status(),
        ModelStatus::Failed {
            error: ModelError::HttpStatus(404),
            ..
        }
    ));
}

#[test]
fn cancel_deletes_verified_files_and_partial_bytes() {
    let data = fixture();
    let server = serve_plan(data.clone(), true, None, |index| Reply::Body {
        stall_after: (index == 1).then_some(FIXTURE_LEN / 2),
    });
    let dir = tempfile::tempdir().unwrap();
    let manifest = ModelManifest {
        version: "test-1".into(),
        files: vec![
            model_file("first.bin", &server.url, &data),
            model_file("model.bin", &server.url, &data),
        ],
    };
    let models = manager(dir.path(), manifest, PLENTY);
    models.start_download().unwrap();
    wait_for(
        &models,
        |status| matches!(status, ModelStatus::Downloading(p) if p.done_bytes > FIXTURE_LEN as u64),
    );
    assert!(dir.path().join("test-1/first.bin").exists());
    models.cancel_download();
    assert!(matches!(
        models.status(),
        ModelStatus::NotDownloaded { download_bytes } if download_bytes == 2 * FIXTURE_LEN as u64
    ));
    assert!(!dir.path().join("test-1").exists());
}

#[test]
fn delete_and_redownload_refuse_during_a_voice_turn() {
    let data = fixture();
    let server = serve(data.clone(), true, None);
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    models.start_download().unwrap();
    models.wait();

    models.set_voice_turn_active(true);
    assert_eq!(models.delete_models(), Err(ModelError::VoiceTurnActive));
    assert_eq!(models.redownload_models(), Err(ModelError::VoiceTurnActive));
    assert!(matches!(models.status(), ModelStatus::Ready { .. }));

    models.set_voice_turn_active(false);
    let freed = models.delete_models().unwrap();
    assert!(freed >= FIXTURE_LEN as u64);
    assert!(matches!(
        models.status(),
        ModelStatus::NotDownloaded { download_bytes } if download_bytes == FIXTURE_LEN as u64
    ));
    assert!(!dir.path().join("test-1").exists());

    models.redownload_models().unwrap();
    models.wait();
    assert!(matches!(models.status(), ModelStatus::Ready { .. }));
    assert_eq!(server.log.lock().unwrap().ranges.len(), 2);
}

/// A stall gate that is never opened while the test runs.
fn never() -> (mpsc::Sender<()>, Receiver<()>) {
    mpsc::channel()
}

#[test]
fn a_silent_connection_reconnects_with_a_range_request() {
    let data = fixture();
    let (_keep_closed, gate) = never();
    let server = serve(data.clone(), true, Some((FIXTURE_LEN / 2, gate)));
    let dir = tempfile::tempdir().unwrap();
    let mut settings = config(dir.path(), manifest_for(&server.url, &data), PLENTY);
    settings.stall_timeout = Duration::from_millis(300);
    let models = ModelManager::new(settings);
    models.start_download().unwrap();
    let ModelStatus::Reconnecting(progress) = wait_for(&models, |status| {
        matches!(status, ModelStatus::Reconnecting(_))
    }) else {
        unreachable!()
    };
    models.wait();
    assert!(matches!(models.status(), ModelStatus::Ready { .. }));
    let ranges = server.log.lock().unwrap().ranges.clone();
    assert_eq!(ranges.len(), 2);
    assert_eq!(ranges[1], Some(format!("bytes={}-", progress.done_bytes)));
    assert_eq!(
        std::fs::read(dir.path().join("test-1/model.bin")).unwrap(),
        data
    );
}

#[test]
fn pause_and_cancel_take_effect_while_the_connection_is_silent() {
    let data = fixture();
    let server = serve_plan(data.clone(), true, None, |_| Reply::Body {
        stall_after: Some(FIXTURE_LEN / 4),
    });
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    models.start_download().unwrap();
    wait_for(
        &models,
        |status| matches!(status, ModelStatus::Downloading(p) if p.done_bytes > 0),
    );
    let paused_at = Instant::now();
    models.pause_download();
    wait_for(&models, |status| matches!(status, ModelStatus::Paused(_)));
    assert!(paused_at.elapsed() < Duration::from_secs(1));
    assert!(dir.path().join("test-1/model.bin.part").exists());

    models.start_download().unwrap();
    wait_for(&models, |status| {
        matches!(status, ModelStatus::Downloading(_))
    });
    let cancelled_at = Instant::now();
    models.cancel_download();
    assert!(cancelled_at.elapsed() < Duration::from_secs(1));
    assert!(!dir.path().join("test-1").exists());
    assert!(matches!(models.status(), ModelStatus::NotDownloaded { .. }));
}

#[test]
fn start_after_pause_restarts_even_if_the_worker_is_still_stopping() {
    let data = fixture();
    let server = serve_plan(data.clone(), true, None, |index| Reply::Body {
        stall_after: (index == 0).then_some(FIXTURE_LEN / 2),
    });
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    models.start_download().unwrap();
    wait_for(
        &models,
        |status| matches!(status, ModelStatus::Downloading(p) if p.done_bytes > 0),
    );
    models.pause_download();
    models.start_download().unwrap();
    wait_for(&models, |status| {
        matches!(status, ModelStatus::Ready { .. })
    });
    assert_eq!(
        std::fs::read(dir.path().join("test-1/model.bin")).unwrap(),
        data
    );
}

#[test]
fn repeated_silent_attempts_fail_with_a_network_error() {
    let data = fixture();
    let server = serve_plan(data.clone(), true, None, |index| Reply::Body {
        stall_after: Some(if index == 0 { FIXTURE_LEN / 2 } else { 0 }),
    });
    let dir = tempfile::tempdir().unwrap();
    let mut settings = config(dir.path(), manifest_for(&server.url, &data), PLENTY);
    settings.stall_timeout = Duration::from_millis(200);
    settings.max_silent_attempts = 3;
    let models = ModelManager::new(settings);
    models.start_download().unwrap();
    models.wait();
    assert!(
        matches!(
            models.status(),
            ModelStatus::Failed {
                error: ModelError::Network(_),
                ..
            }
        ),
        "{:?}",
        models.status()
    );
    assert_eq!(server.log.lock().unwrap().ranges.len(), 4);
    assert!(dir.path().join("test-1/model.bin.part").exists());
}

#[test]
fn http_503_is_retried_and_404_is_not() {
    let data = fixture();
    let server = serve_plan(data.clone(), true, None, |index| {
        if index == 0 {
            Reply::Status(503)
        } else {
            Reply::Body { stall_after: None }
        }
    });
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    models.start_download().unwrap();
    models.wait();
    assert!(matches!(models.status(), ModelStatus::Ready { .. }));
    assert_eq!(server.log.lock().unwrap().ranges.len(), 2);

    let missing = serve_plan(data.clone(), true, None, |_| Reply::Status(404));
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&missing.url, &data), PLENTY);
    models.start_download().unwrap();
    models.wait();
    assert!(matches!(
        models.status(),
        ModelStatus::Failed {
            error: ModelError::HttpStatus(404),
            ..
        }
    ));
    assert_eq!(missing.log.lock().unwrap().ranges.len(), 1);
}

#[test]
fn resume_reports_verifying_first() {
    // Large enough that re-hashing the stored half outlasts the checks below.
    let data: Vec<u8> = (0..16 * 1024 * 1024)
        .map(|index| (index % 251) as u8)
        .collect();
    let server = serve(data.clone(), true, None);
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("test-1")).unwrap();
    std::fs::write(
        dir.path().join("test-1/model.bin.part"),
        &data[..data.len() / 2],
    )
    .unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    let mut events = models.subscribe();
    events.borrow_and_update();
    models.start_download().unwrap();
    assert!(events.has_changed().unwrap());
    let ModelStatus::Verifying(verify) = models.status() else {
        panic!("expected verifying, got {:?}", models.status());
    };
    assert_eq!(verify.file, "model.bin");
    assert_eq!(verify.checked_bytes, 0);
    assert_eq!(verify.total_bytes, data.len() as u64 / 2);
    models.wait();
    assert!(matches!(models.status(), ModelStatus::Ready { .. }));
}
