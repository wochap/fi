//! Native runner tests. They need the provisioned models in `FI_MODELS_DIR` and are skipped
//! otherwise, so `cargo test --features native` stays green without the downloads.
#![cfg(feature = "native")]

use std::path::PathBuf;

use chrono::{NaiveDate, NaiveTime};
use voice_engine::{
    ChoiceOption, FieldKind, FillRequest, ModelRunner, VoiceEngine, VoiceError, VoiceField,
    audio::wav_pcm16,
    native::{CancelFlag, LLM_MODEL, LlamaRunner, WHISPER_MODEL, transcribe},
    patch::normalize_text,
    schema::build_grammar,
};

fn models_dir() -> Option<PathBuf> {
    let dir = PathBuf::from(std::env::var_os("FI_MODELS_DIR")?);
    if !dir.join(WHISPER_MODEL).exists() || !dir.join(LLM_MODEL).exists() {
        eprintln!("FI_MODELS_DIR lacks the models; skipping");
        return None;
    }
    Some(dir)
}

fn fixture(name: &str) -> Vec<i16> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    wav_pcm16(&std::fs::read(path).unwrap()).unwrap()
}

fn expense_request() -> FillRequest {
    let field = |id: &str, name: &str, kind| VoiceField {
        id: id.into(),
        name: name.into(),
        kind,
        required: false,
        options: Vec::new(),
        max_length: None,
    };
    let mut category = field("f-cat", "category", FieldKind::Choice);
    category.options = ["food", "transport", "home", "other"]
        .iter()
        .map(|label| ChoiceOption {
            id: format!("o-{label}"),
            label: (*label).into(),
        })
        .collect();
    FillRequest {
        collection_id: "expenses".into(),
        fields: vec![
            field("f-desc", "description", FieldKind::Text),
            field("f-amount", "amount", FieldKind::Decimal { scale: 2 }),
            category,
            field("f-date", "date", FieldKind::Date),
        ],
        draft: Vec::new(),
        today: NaiveDate::from_ymd_opt(2026, 9, 28).unwrap(),
        now: NaiveTime::from_hms_opt(12, 0, 0).unwrap(),
        utc_offset_minutes: 0,
    }
}

#[test]
fn whisper_transcribes_the_fixture() {
    let Some(dir) = models_dir() else { return };
    let text = transcribe(
        &dir.join(WHISPER_MODEL),
        &fixture("lunch.wav"),
        &CancelFlag::default(),
    )
    .unwrap();
    let words = normalize_text(&text);
    for word in ["lunch", "twelve", "food", "yesterday"] {
        assert!(
            words.contains(word) || (word == "twelve" && words.contains("12")),
            "{text}"
        );
    }
}

#[test]
fn silence_is_no_speech_without_a_model() {
    // The energy gate rejects silence before any model is touched.
    let missing = PathBuf::from("/nonexistent/model.bin");
    assert_eq!(
        transcribe(&missing, &fixture("silence.wav"), &CancelFlag::default()),
        Err(VoiceError::NoSpeech)
    );
}

#[test]
fn whisper_silence_is_no_speech() {
    let Some(dir) = models_dir() else { return };
    assert_eq!(
        transcribe(
            &dir.join(WHISPER_MODEL),
            &fixture("silence.wav"),
            &CancelFlag::default()
        ),
        Err(VoiceError::NoSpeech)
    );
}

#[test]
fn a_missing_or_damaged_model_fails_to_load() {
    let dir = tempdir();
    assert_eq!(
        LlamaRunner::load(&dir.join("missing.gguf"), CancelFlag::default()).err(),
        Some(VoiceError::ModelLoadFailed)
    );
    let damaged = dir.join("damaged.gguf");
    std::fs::write(&damaged, b"not a model").unwrap();
    assert_eq!(
        LlamaRunner::load(&damaged, CancelFlag::default()).err(),
        Some(VoiceError::ModelLoadFailed)
    );
    let truncated = dir.join("truncated.gguf");
    std::fs::write(&truncated, b"GGUF\x03\x00").unwrap();
    assert_eq!(
        LlamaRunner::load(&truncated, CancelFlag::default()).err(),
        Some(VoiceError::ModelLoadFailed)
    );
}

fn tempdir() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("voice-engine-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn llama_output_follows_the_grammar() {
    let Some(dir) = models_dir() else { return };
    let mut runner = LlamaRunner::load(&dir.join(LLM_MODEL), CancelFlag::default()).unwrap();
    let request = expense_request();
    let mut engine = VoiceEngine::new();
    let transcript = "Lunch at Nando's, twelve fifty, food, yesterday.";
    let grammar = voice_engine::GrammarCache::default().get("x", &request.fields);
    assert_eq!(grammar.gbnf(), build_grammar(&request.fields));
    let prompt = voice_engine::schema::build_prompt(&request.fields, &request, transcript);
    let output = runner.complete(&prompt, &grammar).unwrap();
    let entries: Vec<serde_json::Value> = serde_json::from_str(&output).unwrap();
    for entry in &entries {
        let field = entry["field"].as_str().unwrap();
        assert!(request.fields.iter().any(|f| f.name == field), "{output}");
    }
    let outcome = engine.fill(&mut runner, transcript, &request).unwrap();
    assert!(!outcome.patch.is_empty());
}

#[test]
fn cancel_stops_generation() {
    let Some(dir) = models_dir() else { return };
    let cancel = CancelFlag::default();
    let mut runner = LlamaRunner::load(&dir.join(LLM_MODEL), cancel.clone()).unwrap();
    cancel.cancel();
    let request = expense_request();
    assert_eq!(
        VoiceEngine::new()
            .fill(&mut runner, "Taxi home", &request)
            .err(),
        Some(VoiceError::Cancelled)
    );
}
