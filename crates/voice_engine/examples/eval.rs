//! Evaluation harness: fills a fixed set of utterances against sample schemas with the
//! provisioned instruction model and reports field accuracy, invented-field rate, evidence
//! rejection rate and median fill latency. Exits non-zero below the acceptance bar. It also cleans
//! a few dictated utterances and reports the cleanup acceptance rate (informational, no bar).
//! `FI_EVAL_LANGUAGE` picks the utterance set: `en` (default) or `es`.
//!
//! ```sh
//! FI_MODELS_DIR=~/.cache/fi-models cargo run --release -p voice_engine --features native --example eval
//! FI_EVAL_LANGUAGE=es FI_MODELS_DIR=~/.cache/fi-models cargo run --release -p voice_engine --features native --example eval
//! ```

use std::{collections::BTreeMap, path::PathBuf, process::ExitCode, time::Instant};

use chrono::{DateTime, NaiveDate, NaiveTime};
use serde::Deserialize;
use voice_engine::{
    ChoiceOption, FieldKind, FillRequest, Grammar, ModelRunner, TypedValue, VoiceEngine,
    VoiceError, VoiceField, VoiceLanguage,
    native::{CancelFlag, LlamaRunner, understanding_model_file},
    patch::normalize_text,
};

const MIN_ACCURACY: f64 = 0.85;
const MAX_INVENTED: f64 = 0.05;

#[derive(Deserialize)]
struct Fixture {
    today: NaiveDate,
    now: String,
    schemas: BTreeMap<String, Vec<FieldSpec>>,
    #[serde(default)]
    dictation: Vec<DictationCase>,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct FieldSpec {
    name: String,
    kind: String,
    #[serde(default)]
    scale: u8,
    #[serde(default)]
    required: bool,
    #[serde(default)]
    options: Vec<String>,
}

#[derive(Deserialize)]
struct DictationCase {
    text: String,
    expect: String,
}

#[derive(Deserialize)]
struct Case {
    schema: String,
    text: String,
    expect: BTreeMap<String, String>,
}

/// Keeps the model's raw output so misses can show it.
struct Recording<'a> {
    inner: &'a mut LlamaRunner,
    last: String,
}

impl ModelRunner for Recording<'_> {
    fn complete(&mut self, prompt: &str, grammar: &Grammar) -> Result<String, VoiceError> {
        let output = self.inner.complete(prompt, grammar)?;
        self.last.clone_from(&output);
        Ok(output)
    }
}

fn fields(specs: &[FieldSpec]) -> Vec<VoiceField> {
    specs
        .iter()
        .map(|spec| VoiceField {
            id: spec.name.clone(),
            name: spec.name.clone(),
            kind: match spec.kind.as_str() {
                "text" => FieldKind::Text,
                "integer" => FieldKind::Integer,
                "decimal" => FieldKind::Decimal { scale: spec.scale },
                "boolean" => FieldKind::Boolean,
                "date" => FieldKind::Date,
                "datetime" => FieldKind::DateTime,
                "duration" => FieldKind::Duration,
                "choice" => FieldKind::Choice,
                other => panic!("unknown kind {other}"),
            },
            required: spec.required,
            options: spec
                .options
                .iter()
                .map(|label| ChoiceOption {
                    id: label.clone(),
                    label: label.clone(),
                })
                .collect(),
            max_length: None,
        })
        .collect()
}

/// The value in the fixture's notation.
fn render(value: &TypedValue, kind: &FieldKind) -> String {
    match (value, kind) {
        (TypedValue::Text(text), _) => normalize_text(text),
        (TypedValue::Integer(value), _) => value.to_string(),
        (TypedValue::Decimal(value), FieldKind::Decimal { scale }) => {
            let divisor = 10i64.pow(u32::from(*scale));
            if *scale == 0 {
                value.to_string()
            } else {
                format!(
                    "{}.{:0width$}",
                    value / divisor,
                    (value % divisor).abs(),
                    width = usize::from(*scale)
                )
            }
        }
        (TypedValue::Boolean(value), _) => value.to_string(),
        (TypedValue::Date(days), _) => (NaiveDate::from_ymd_opt(1970, 1, 1).unwrap()
            + chrono::Days::new(*days as u64))
        .to_string(),
        (TypedValue::DateTime(ms), _) => DateTime::from_timestamp_millis(*ms)
            .unwrap()
            .naive_utc()
            .format("%Y-%m-%dT%H:%M")
            .to_string(),
        (TypedValue::Duration(ms), _) => ms.to_string(),
        (TypedValue::Choice(id), _) => id.clone(),
        (value, _) => format!("{value:?}"),
    }
}

fn main() -> ExitCode {
    let Some(dir) = std::env::var_os("FI_MODELS_DIR").map(PathBuf::from) else {
        eprintln!(
            "set FI_MODELS_DIR to the directory holding {}",
            understanding_model_file()
        );
        return ExitCode::from(2);
    };
    let language = VoiceLanguage::from_code(
        &std::env::var("FI_EVAL_LANGUAGE").unwrap_or_else(|_| "en".into()),
    );
    let fixture: Fixture = serde_json::from_str(match language {
        VoiceLanguage::En => include_str!("../tests/fixtures/eval.json"),
        VoiceLanguage::Es => include_str!("../tests/fixtures/eval_es.json"),
    })
    .expect("the eval fixture parses");
    println!("language: {}", language.code());
    let now = NaiveTime::parse_from_str(&fixture.now, "%H:%M").unwrap();
    let load = Instant::now();
    let mut runner =
        match LlamaRunner::load(&dir.join(understanding_model_file()), CancelFlag::default()) {
            Ok(runner) => runner,
            Err(error) => {
                eprintln!("model load failed: {error}");
                return ExitCode::from(2);
            }
        };
    println!("model loaded in {:.1}s", load.elapsed().as_secs_f64());
    let mut engine = VoiceEngine::new();
    let (mut expected, mut correct, mut returned, mut invented) = (0usize, 0, 0, 0);
    let (mut proposed, mut rejected) = (0usize, 0);
    let mut latencies = Vec::new();
    for case in &fixture.cases {
        let fields = fields(&fixture.schemas[&case.schema]);
        let request = FillRequest {
            collection_id: case.schema.clone(),
            fields: fields.clone(),
            draft: Vec::new(),
            today: fixture.today,
            now,
            utc_offset_minutes: 0,
            language,
        };
        let started = Instant::now();
        let mut recording = Recording {
            inner: &mut runner,
            last: String::new(),
        };
        let outcome = engine.fill(&mut recording, &case.text, &request);
        latencies.push(started.elapsed().as_secs_f64());
        let (patch, stats) = match outcome {
            Ok(outcome) => (outcome.patch, Some(outcome.stats)),
            Err(VoiceError::NothingMatched) => (Vec::new(), None),
            Err(error) => {
                eprintln!("fill failed: {error}");
                return ExitCode::from(2);
            }
        };
        if let Some(stats) = stats {
            proposed += stats.proposed;
            rejected += stats.evidence_rejected;
        }
        let got: BTreeMap<&str, String> = patch
            .iter()
            .map(|entry| {
                let field = fields.iter().find(|f| f.id == entry.field_id).unwrap();
                (field.name.as_str(), render(&entry.value, &field.kind))
            })
            .collect();
        let mut misses = Vec::new();
        for (name, want) in &case.expect {
            expected += 1;
            let want = if fields
                .iter()
                .any(|f| &f.name == name && f.kind == FieldKind::Text)
            {
                normalize_text(want)
            } else {
                want.clone()
            };
            match got.get(name.as_str()) {
                Some(value) if *value == want => correct += 1,
                other => misses.push(format!("{name}: want {want}, got {other:?}")),
            }
        }
        returned += got.len();
        for name in got.keys() {
            if !case.expect.contains_key(*name) {
                invented += 1;
                misses.push(format!("{name}: invented {}", got[name]));
            }
        }
        if !misses.is_empty() {
            println!("✗ {}\n    {}", case.text, misses.join("\n    "));
            if std::env::var_os("FI_EVAL_VERBOSE").is_some() {
                println!("    model: {}", recording.last);
            }
        }
    }
    let (mut cleaned_ok, mut accepted) = (0usize, 0usize);
    for case in &fixture.dictation {
        let mut recording = Recording {
            inner: &mut runner,
            last: String::new(),
        };
        let dictation = match engine.clean(&mut recording, &case.text, language) {
            Ok(dictation) => dictation,
            Err(error) => {
                eprintln!("cleanup failed: {error}");
                return ExitCode::from(2);
            }
        };
        let fell_back = dictation.removed.is_empty()
            && normalize_text(&recording.last.replace('"', "")) != normalize_text(&case.text);
        if !fell_back {
            accepted += 1;
        }
        if normalize_text(&dictation.cleaned) == normalize_text(&case.expect) {
            cleaned_ok += 1;
        } else {
            println!(
                "✗ dictation {}\n    want {}, got {}",
                case.text, case.expect, dictation.cleaned
            );
            if std::env::var_os("FI_EVAL_VERBOSE").is_some() {
                println!("    model: {}", recording.last);
            }
        }
    }
    if !fixture.dictation.is_empty() {
        let total = fixture.dictation.len();
        println!(
            "dictation cleanup accepted: {:.1}% ({accepted}/{total})\ndictation cleanup correct: {:.1}% ({cleaned_ok}/{total})",
            accepted as f64 * 100.0 / total as f64,
            cleaned_ok as f64 * 100.0 / total as f64,
        );
    }
    latencies.sort_by(f64::total_cmp);
    let accuracy = correct as f64 / expected.max(1) as f64;
    let invented_rate = invented as f64 / returned.max(1) as f64;
    let rejection_rate = rejected as f64 / proposed.max(1) as f64;
    println!(
        "utterances: {}\nfield accuracy: {:.1}% ({correct}/{expected})\ninvented fields: {:.1}% ({invented}/{returned})\nevidence rejections: {:.1}% ({rejected}/{proposed})\nmedian fill latency: {:.2}s",
        fixture.cases.len(),
        accuracy * 100.0,
        invented_rate * 100.0,
        rejection_rate * 100.0,
        latencies[latencies.len() / 2],
    );
    if accuracy >= MIN_ACCURACY && invented_rate <= MAX_INVENTED {
        ExitCode::SUCCESS
    } else {
        println!(
            "below the bar: accuracy ≥ {:.0}% and invented ≤ {:.0}% required",
            MIN_ACCURACY * 100.0,
            MAX_INVENTED * 100.0
        );
        ExitCode::FAILURE
    }
}
