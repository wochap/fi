//! The voice worker behind `api::voice`: the native engine when the build has it, otherwise
//! stubs that report the engine as unavailable.

#[cfg(any(
    feature = "voice-native",
    all(target_os = "android", target_arch = "aarch64")
))]
mod imp {
    use std::{
        path::PathBuf,
        sync::{Mutex, OnceLock},
    };

    use voice_engine::{
        FillRequest, VoiceEngine, VoiceError, VoiceLanguage,
        native::{
            CancelFlag, LlamaRunner, speech_model_file, transcribe, understanding_model_file,
        },
    };

    use crate::api::voice::VoiceTurnEventDto;

    pub const AVAILABLE: bool = true;

    #[derive(Default)]
    struct Slot {
        model: Option<(PathBuf, LlamaRunner)>,
        engine: VoiceEngine,
    }

    /// The loaded model. A turn holds the lock while it loads or fills, so a turn that needs the
    /// model while it is loading waits for the load.
    fn slot() -> &'static Mutex<Slot> {
        static SLOT: OnceLock<Mutex<Slot>> = OnceLock::new();
        SLOT.get_or_init(Mutex::default)
    }

    fn cancel_flag() -> &'static CancelFlag {
        static FLAG: OnceLock<CancelFlag> = OnceLock::new();
        FLAG.get_or_init(CancelFlag::default)
    }

    fn version_dir(models_dir: &str) -> PathBuf {
        crate::api::voice_models::manager(models_dir)
            .store()
            .version_dir()
    }

    fn ensure_loaded(slot: &mut Slot, path: &PathBuf) -> Result<(), VoiceError> {
        if slot
            .model
            .as_ref()
            .is_some_and(|(loaded, _)| loaded == path)
        {
            return Ok(());
        }
        slot.model = None;
        let runner = LlamaRunner::load(path, cancel_flag().clone())?;
        slot.model = Some((path.clone(), runner));
        Ok(())
    }

    pub fn prepare(models_dir: &str) {
        let path = version_dir(models_dir).join(understanding_model_file());
        if !path.exists() {
            return;
        }
        std::thread::spawn(move || {
            let mut slot = slot()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let _ = ensure_loaded(&mut slot, &path);
        });
    }

    /// Transcribes, emits the transcript, then runs `finish` with the loaded model and emits its
    /// event or the failure. Fill and dictation turns share the model slot and cancel flag.
    fn run_turn(
        models_dir: &str,
        pcm: Vec<i16>,
        language: VoiceLanguage,
        emit: impl Fn(VoiceTurnEventDto) + Send + 'static,
        finish: impl FnOnce(
            &mut VoiceEngine,
            &mut LlamaRunner,
            &str,
        ) -> Result<VoiceTurnEventDto, VoiceError>
        + Send
        + 'static,
    ) {
        let dir = version_dir(models_dir);
        cancel_flag().reset();
        std::thread::spawn(move || {
            let result = transcribe(
                &dir.join(speech_model_file(language)),
                &pcm,
                language,
                cancel_flag(),
            )
            .and_then(|transcript| {
                drop(pcm);
                emit(VoiceTurnEventDto::transcript(transcript.clone()));
                let mut slot = slot()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if cancel_flag().is_cancelled() {
                    return Err(VoiceError::Cancelled);
                }
                ensure_loaded(&mut slot, &dir.join(understanding_model_file()))?;
                let Slot { model, engine } = &mut *slot;
                let (_, runner) = model.as_mut().expect("loaded above");
                let event = finish(engine, runner, &transcript);
                if matches!(event, Err(VoiceError::LowMemory)) {
                    *model = None;
                }
                event
            });
            emit(result.unwrap_or_else(VoiceTurnEventDto::failed));
        });
    }

    pub fn fill_turn(
        models_dir: &str,
        pcm: Vec<i16>,
        request: FillRequest,
        emit: impl Fn(VoiceTurnEventDto) + Send + 'static,
    ) {
        run_turn(
            models_dir,
            pcm,
            request.language,
            emit,
            move |engine, runner, transcript| {
                engine
                    .fill(runner, transcript, &request)
                    .map(|outcome| VoiceTurnEventDto::patch(outcome.patch))
            },
        );
    }

    pub fn dictate_turn(
        models_dir: &str,
        pcm: Vec<i16>,
        language: VoiceLanguage,
        emit: impl Fn(VoiceTurnEventDto) + Send + 'static,
    ) {
        run_turn(
            models_dir,
            pcm,
            language,
            emit,
            move |engine, runner, transcript| {
                engine
                    .clean(runner, transcript, language)
                    .map(VoiceTurnEventDto::dictation)
            },
        );
    }

    pub fn cancel() {
        cancel_flag().cancel();
    }

    pub fn release() {
        std::thread::spawn(|| {
            let mut slot = slot()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            slot.model = None;
        });
    }
}

#[cfg(not(any(
    feature = "voice-native",
    all(target_os = "android", target_arch = "aarch64")
)))]
mod imp {
    use voice_engine::{FillRequest, VoiceError, VoiceLanguage};

    use crate::api::voice::VoiceTurnEventDto;

    pub const AVAILABLE: bool = false;

    pub fn prepare(_: &str) {}

    pub fn fill_turn(
        _: &str,
        _: Vec<i16>,
        _: FillRequest,
        emit: impl Fn(VoiceTurnEventDto) + Send + 'static,
    ) {
        emit(VoiceTurnEventDto::failed(VoiceError::ModelLoadFailed));
    }

    pub fn dictate_turn(
        _: &str,
        _: Vec<i16>,
        _: VoiceLanguage,
        emit: impl Fn(VoiceTurnEventDto) + Send + 'static,
    ) {
        emit(VoiceTurnEventDto::failed(VoiceError::ModelLoadFailed));
    }

    pub fn cancel() {}

    pub fn release() {}
}

pub use imp::*;
