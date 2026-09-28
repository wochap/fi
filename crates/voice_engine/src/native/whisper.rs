//! Whisper transcription. The context is created for each turn and dropped afterwards, so the
//! Whisper and instruction models are never both at peak.

use std::path::Path;

use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use super::{CancelFlag, THREADS, check_model_file, load_failure};
use crate::{
    VoiceError,
    audio::{clean_transcript, pcm16_to_f32, trim_silence},
};

/// ggml model files start with "lmgg" (little-endian `ggml`).
const MAGIC: &[&[u8]] = &[b"lmgg", b"ggml"];

/// Transcribes 16 kHz mono PCM16. `NoSpeech` for silence or an empty transcript.
pub fn transcribe(model: &Path, pcm: &[i16], cancel: &CancelFlag) -> Result<String, VoiceError> {
    let samples = pcm16_to_f32(pcm);
    let speech = trim_silence(&samples).ok_or(VoiceError::NoSpeech)?;
    let size = check_model_file(model, MAGIC)?;
    if cancel.is_cancelled() {
        return Err(VoiceError::Cancelled);
    }
    whisper_rs::install_logging_hooks();
    let context = WhisperContext::new_with_params(model, WhisperContextParameters::default())
        .map_err(|_| load_failure(size))?;
    let mut state = context.create_state().map_err(|_| VoiceError::LowMemory)?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_language(Some("en"));
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
    let flag = cancel.clone();
    params.set_abort_callback_safe(move || flag.is_cancelled());
    let result = state.full(params, speech);
    if cancel.is_cancelled() {
        return Err(VoiceError::Cancelled);
    }
    result.map_err(|_| VoiceError::LowMemory)?;
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
