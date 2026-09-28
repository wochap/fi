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
    ModelError, ModelFile, ModelManager, ModelManagerConfig, ModelManifest, ModelStatus,
    STORAGE_HEADROOM_BYTES,
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

/// Serves `data` at `/model.bin`. With `ranges`, honours `Range: bytes=n-`.
/// The first response stalls after `stall_after` bytes until `gate` fires.
fn serve(data: Vec<u8>, ranges: bool, stall: Option<(usize, Receiver<()>)>) -> Server {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let url = format!("http://{}/model.bin", server.server_addr());
    let log = Arc::new(Mutex::new(ServerLog::default()));
    let server_log = Arc::clone(&log);
    thread::spawn(move || {
        let mut stall = stall;
        for request in server.incoming_requests() {
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
            let body = data[start..].to_vec();
            let status = if start > 0 { 206 } else { 200 };
            let (stall_after, gate) = match stall.take() {
                Some((after, gate)) => (after, Some(gate)),
                None => (body.len(), None),
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
        files: vec![ModelFile {
            name: "model.bin".into(),
            url: url.into(),
            size: data.len() as u64,
            sha256: hex::encode(Sha256::digest(data)),
        }],
    }
}

fn manager(root: &Path, manifest: ModelManifest, free: u64) -> ModelManager {
    ModelManager::new(ModelManagerConfig {
        root: root.to_path_buf(),
        manifest,
        free_space: Arc::new(move |_| Ok(free)),
        progress_interval: Duration::ZERO,
    })
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
    assert!(matches!(models.status(), ModelStatus::NotDownloaded { .. }));
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
fn cancel_drops_partial_bytes() {
    let data = fixture();
    let (open_gate, gate) = mpsc::channel();
    let server = serve(data.clone(), true, Some((FIXTURE_LEN / 2, gate)));
    let dir = tempfile::tempdir().unwrap();
    let models = manager(dir.path(), manifest_for(&server.url, &data), PLENTY);
    models.start_download().unwrap();
    wait_for(
        &models,
        |status| matches!(status, ModelStatus::Downloading(p) if p.done_bytes > 0),
    );
    models.cancel_download();
    open_gate.send(()).unwrap();
    models.wait();
    assert!(matches!(models.status(), ModelStatus::NotDownloaded { .. }));
    assert!(!dir.path().join("test-1/model.bin.part").exists());
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
