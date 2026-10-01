//! Whisper transcription. The context is created for each turn and dropped afterwards, so the
//! Whisper and instruction models are never both at peak.

use std::path::Path;

use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use super::{CancelFlag, THREADS, check_model_file, load_failure, run_failure};
use crate::{
    VoiceError, VoiceLanguage,
    audio::{clean_transcript, pcm16_to_f32, trim_silence},
};

/// ggml model files start with "lmgg" (little-endian `ggml`).
const MAGIC: &[&[u8]] = &[b"lmgg", b"ggml"];

/// Transcribes 16 kHz mono PCM16 in a language. `NoSpeech` for silence or an empty transcript.
pub fn transcribe(
    model: &Path,
    pcm: &[i16],
    language: VoiceLanguage,
    cancel: &CancelFlag,
) -> Result<String, VoiceError> {
    let samples = pcm16_to_f32(pcm);
    let speech = trim_silence(&samples).ok_or(VoiceError::NoSpeech)?;
    let size = check_model_file(model, MAGIC)?;
    if cancel.is_cancelled() {
        return Err(VoiceError::Cancelled);
    }
    whisper_rs::install_logging_hooks();
    let context = WhisperContext::new_with_params(model, WhisperContextParameters::default())
        .map_err(|error| load_failure("whisper context", error, size))?;
    let mut state = context
        .create_state()
        .map_err(|error| run_failure("whisper state", error))?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some(language.code()));
    params.set_n_threads(THREADS);
    params.set_no_context(true);
    params.set_single_segment(true);
    params.set_no_timestamps(true);
    params.set_suppress_blank(true);
    params.set_suppress_nst(true);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    // Not `set_abort_callback_safe`: in whisper-rs 0.16 its trampoline reads the boxed closure
    // through the wrong pointer type, so whisper aborts on garbage ("failed to encode", -6).
    // The flag outlives `full` because `cancel` is borrowed for this whole call.
    // SAFETY: the callback only reads an `AtomicBool` that stays alive until `full` returns.
    unsafe {
        params.set_abort_callback(Some(abort_if_cancelled));
        params.set_abort_callback_user_data(cancel.as_ptr().cast_mut().cast());
    }
    let result = state.full(params, speech);
    if cancel.is_cancelled() {
        return Err(VoiceError::Cancelled);
    }
    result.map_err(|error| run_failure("whisper transcribe", error))?;
    let text: String = state
        .as_iter()
        .filter_map(|segment| segment.to_str_lossy().ok().map(|text| text.into_owned()))
        .collect::<Vec<_>>()
        .join(" ");
    let cleaned = clean_transcript(&text);
    if cleaned.is_empty() {
        return Err(VoiceError::NoSpeech);
    }
    Ok(cleaned)
}

/// Whisper's abort callback: true once the turn's cancel flag is set.
unsafe extern "C" fn abort_if_cancelled(user_data: *mut std::ffi::c_void) -> bool {
    // SAFETY: `user_data` is the `AtomicBool` of the `CancelFlag` borrowed by `transcribe`.
    unsafe {
        (*user_data.cast::<std::sync::atomic::AtomicBool>())
            .load(std::sync::atomic::Ordering::SeqCst)
    }
}
