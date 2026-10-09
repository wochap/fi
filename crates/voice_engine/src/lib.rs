//! On-device voice fill. One spoken turn becomes a transcript, the instruction model proposes a
//! patch constrained by a grammar built from the collection's schema, and deterministic code turns
//! the proposed spans into typed values and drops anything the transcript does not back.
//!
//! Everything here except [`native`] is pure Rust and builds in the default workspace. The
//! `native` feature adds the whisper.cpp and llama.cpp runners.

pub mod audio;
pub mod dictation;
#[cfg(feature = "native")]
pub mod native;
pub mod normalize;
pub mod patch;
pub mod schema;

use chrono::{NaiveDate, NaiveTime};
use thiserror::Error;

pub use dictation::Dictation;
pub use patch::{PatchStats, RawEntry};
pub use schema::{Grammar, GrammarCache};

/// The type of a field as the engine sees it.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum FieldKind {
    Text,
    Integer,
    Decimal { scale: u8 },
    Boolean,
    Date,
    DateTime,
    Duration,
    Choice,
}

/// One live option of a Choice field.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct ChoiceOption {
    pub id: String,
    pub label: String,
}

/// One active field of the collection, in form order.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct VoiceField {
    pub id: String,
    pub name: String,
    pub kind: FieldKind,
    pub required: bool,
    /// A Choice field's live options.
    pub options: Vec<ChoiceOption>,
    pub max_length: Option<u32>,
}

/// The language a turn is spoken in.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq)]
pub enum VoiceLanguage {
    #[default]
    En,
    Es,
}

impl VoiceLanguage {
    /// The language code: "en" or "es".
    pub fn code(self) -> &'static str {
        match self {
            Self::En => "en",
            Self::Es => "es",
        }
    }

    /// "es" gives Spanish; anything else gives English.
    pub fn from_code(code: &str) -> Self {
        match code {
            "es" => Self::Es,
            _ => Self::En,
        }
    }
}

/// What one turn fills: the collection, its active fields, the draft and the device clock.
#[derive(Clone, Debug)]
pub struct FillRequest {
    pub collection_id: String,
    pub fields: Vec<VoiceField>,
    /// Current draft values as display text, by field id.
    pub draft: Vec<(String, String)>,
    /// The device's local date and minute.
    pub today: NaiveDate,
    pub now: NaiveTime,
    /// The device's UTC offset in minutes, used to store date-times as UTC.
    pub utc_offset_minutes: i32,
    /// The language the turn is spoken in; selects the normalizers.
    pub language: VoiceLanguage,
}

/// A typed value, in the core's representations.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TypedValue {
    Text(String),
    Integer(i64),
    /// Scaled by the field's scale: 12.50 at scale 2 is 1250.
    Decimal(i64),
    Boolean(bool),
    /// Days since 1970-01-01.
    Date(i64),
    /// Unix milliseconds.
    DateTime(i64),
    /// Milliseconds.
    Duration(i64),
    /// The option id.
    Choice(String),
}

/// One surviving patch entry.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PatchEntry {
    pub field_id: String,
    pub value: TypedValue,
    pub evidence: String,
}

/// The ways a turn fails inside the engine.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum VoiceError {
    #[error("no speech")]
    NoSpeech,
    #[error("nothing matched")]
    NothingMatched,
    #[error("model load failed")]
    ModelLoadFailed,
    #[error("low memory")]
    LowMemory,
    #[error("cancelled")]
    Cancelled,
}

/// Runs the instruction model: a prompt in, grammar-constrained text out.
pub trait ModelRunner {
    fn complete(&mut self, prompt: &str, grammar: &Grammar) -> Result<String, VoiceError>;
}

/// A filled turn with the counts the evaluation reports.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FillOutcome {
    pub patch: Vec<PatchEntry>,
    pub stats: PatchStats,
}

/// The pure core: grammar cache, prompt, model call, patch parsing, evidence and normalizers.
#[derive(Debug, Default)]
pub struct VoiceEngine {
    grammars: GrammarCache,
}

impl VoiceEngine {
    pub fn new() -> Self {
        Self::default()
    }

    /// Grammar compilations so far; a schema compiles once while it stays cached.
    pub fn grammar_compilations(&self) -> usize {
        self.grammars.compilations()
    }

    /// Fills one transcript. Fails with `NothingMatched` when no entry survives.
    pub fn fill(
        &mut self,
        runner: &mut dyn ModelRunner,
        transcript: &str,
        request: &FillRequest,
    ) -> Result<FillOutcome, VoiceError> {
        let fields: Vec<VoiceField> = request
            .fields
            .iter()
            .filter(|field| !field.name.trim().is_empty())
            .cloned()
            .collect();
        let grammar = self.grammars.get(&request.collection_id, &fields);
        let prompt = schema::build_prompt(&fields, request, transcript);
        let output = runner.complete(&prompt, &grammar)?;
        let outcome = patch::build_patch(&output, transcript, &fields, request);
        if outcome.patch.is_empty() {
            return Err(VoiceError::NothingMatched);
        }
        Ok(outcome)
    }

    /// Cleans one dictated transcript, deleting self-corrections and filler. Falls back to the
    /// transcript when the model's output is not the transcript with words deleted. Never fails
    /// with `NothingMatched`; runner failures pass through.
    pub fn clean(
        &mut self,
        runner: &mut dyn ModelRunner,
        transcript: &str,
        language: VoiceLanguage,
    ) -> Result<Dictation, VoiceError> {
        if transcript.trim().is_empty() {
            return Ok(Dictation::unchanged(transcript));
        }
        let prompt = dictation::build_prompt(transcript, language);
        let output = runner.complete(&prompt, &dictation::grammar())?;
        Ok(dictation::accept(transcript, &output))
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    pub fn field(id: &str, name: &str, kind: FieldKind) -> VoiceField {
        VoiceField {
            id: id.into(),
            name: name.into(),
            kind,
            required: false,
            options: Vec::new(),
            max_length: None,
        }
    }

    pub fn choice(id: &str, name: &str, labels: &[&str]) -> VoiceField {
        VoiceField {
            options: labels
                .iter()
                .map(|label| ChoiceOption {
                    id: format!("{id}-{label}"),
                    label: (*label).into(),
                })
                .collect(),
            ..field(id, name, FieldKind::Choice)
        }
    }

    pub fn expense_fields() -> Vec<VoiceField> {
        vec![
            VoiceField {
                required: true,
                ..field("f-desc", "description", FieldKind::Text)
            },
            VoiceField {
                required: true,
                ..field("f-amount", "amount", FieldKind::Decimal { scale: 2 })
            },
            choice("f-cat", "category", &["food", "transport", "home", "other"]),
            field("f-date", "date", FieldKind::Date),
        ]
    }

    /// `expense_fields` with Spanish choice labels.
    pub fn spanish_expense_fields() -> Vec<VoiceField> {
        let mut fields = expense_fields();
        fields[2] = choice(
            "f-cat",
            "category",
            &["comida", "transporte", "hogar", "otro"],
        );
        fields
    }

    pub fn request(fields: Vec<VoiceField>) -> FillRequest {
        FillRequest {
            collection_id: "c-expenses".into(),
            fields,
            draft: Vec::new(),
            // Monday.
            today: NaiveDate::from_ymd_opt(2026, 9, 28).unwrap(),
            now: NaiveTime::from_hms_opt(14, 7, 0).unwrap(),
            utc_offset_minutes: 0,
            language: VoiceLanguage::En,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;

    struct Scripted {
        output: String,
        prompts: Vec<String>,
    }

    impl ModelRunner for Scripted {
        fn complete(&mut self, prompt: &str, grammar: &Grammar) -> Result<String, VoiceError> {
            assert!(grammar.gbnf().contains("root ::="));
            self.prompts.push(prompt.to_owned());
            Ok(self.output.clone())
        }
    }

    fn scripted(output: &str) -> Scripted {
        Scripted {
            output: output.into(),
            prompts: Vec::new(),
        }
    }

    #[test]
    fn a_turn_becomes_a_typed_patch() {
        let mut engine = VoiceEngine::new();
        let mut runner = scripted(
            r#"[{"field":"description","value":"Lunch at Nando's","evidence":"Lunch at Nando's"},
                {"field":"amount","value":"twelve fifty","evidence":"twelve fifty"},
                {"field":"category","value":"food","evidence":"food"},
                {"field":"date","value":"yesterday","evidence":"yesterday"}]"#,
        );
        let outcome = engine
            .fill(
                &mut runner,
                "Lunch at Nando's, twelve fifty, food, yesterday.",
                &request(expense_fields()),
            )
            .unwrap();
        assert_eq!(
            outcome
                .patch
                .iter()
                .map(|entry| (entry.field_id.as_str(), entry.value.clone()))
                .collect::<Vec<_>>(),
            vec![
                ("f-desc", TypedValue::Text("Lunch at Nando's".into())),
                ("f-amount", TypedValue::Decimal(1250)),
                ("f-cat", TypedValue::Choice("f-cat-food".into())),
                ("f-date", TypedValue::Date(20_723)),
            ]
        );
        assert!(runner.prompts[0].contains("Monday 2026-09-28"));
    }

    #[test]
    fn a_spanish_turn_becomes_a_typed_patch() {
        let mut engine = VoiceEngine::new();
        let mut runner = scripted(
            r#"[{"field":"description","value":"Almuerzo en Nando's","evidence":"Almuerzo en Nando's"},
                {"field":"amount","value":"doce con cincuenta","evidence":"doce con cincuenta"},
                {"field":"category","value":"comida","evidence":"comida"},
                {"field":"date","value":"ayer","evidence":"ayer"}]"#,
        );
        let mut request = request(spanish_expense_fields());
        request.language = VoiceLanguage::Es;
        let outcome = engine
            .fill(
                &mut runner,
                "Almuerzo en Nando's, doce con cincuenta, comida, ayer.",
                &request,
            )
            .unwrap();
        assert_eq!(
            outcome
                .patch
                .iter()
                .map(|entry| (entry.field_id.as_str(), entry.value.clone()))
                .collect::<Vec<_>>(),
            vec![
                ("f-desc", TypedValue::Text("Almuerzo en Nando's".into())),
                ("f-amount", TypedValue::Decimal(1250)),
                ("f-cat", TypedValue::Choice("f-cat-comida".into())),
                ("f-date", TypedValue::Date(20_723)),
            ]
        );
    }

    #[test]
    fn language_codes() {
        assert_eq!(VoiceLanguage::from_code("es"), VoiceLanguage::Es);
        assert_eq!(VoiceLanguage::from_code("fr"), VoiceLanguage::En);
        assert_eq!(VoiceLanguage::from_code(""), VoiceLanguage::En);
        assert_eq!(VoiceLanguage::Es.code(), "es");
    }

    #[test]
    fn nothing_surviving_is_nothing_matched() {
        let mut engine = VoiceEngine::new();
        let mut runner = scripted(r#"[{"field":"amount","value":"20","evidence":"twenty"}]"#);
        assert_eq!(
            engine.fill(
                &mut runner,
                "Taxi home yesterday",
                &request(expense_fields())
            ),
            Err(VoiceError::NothingMatched)
        );
        let mut empty = scripted("[]");
        assert_eq!(
            engine.fill(&mut empty, "hello", &request(expense_fields())),
            Err(VoiceError::NothingMatched)
        );
    }

    #[test]
    fn runner_failures_pass_through() {
        struct Failing;
        impl ModelRunner for Failing {
            fn complete(&mut self, _: &str, _: &Grammar) -> Result<String, VoiceError> {
                Err(VoiceError::LowMemory)
            }
        }
        assert_eq!(
            VoiceEngine::new().fill(&mut Failing, "x", &request(expense_fields())),
            Err(VoiceError::LowMemory)
        );
    }

    fn clean(transcript: &str, cleaned: &str, language: VoiceLanguage) -> Dictation {
        let mut runner = scripted(&serde_json::to_string(cleaned).unwrap());
        VoiceEngine::new()
            .clean(&mut runner, transcript, language)
            .unwrap()
    }

    #[test]
    fn dictation_self_correction_removed() {
        let dictation = clean(
            "Lunch at Nando's, scratch that, lunch at Wagamama with Sam",
            "lunch at Wagamama with Sam",
            VoiceLanguage::En,
        );
        assert_eq!(dictation.cleaned, "Lunch at Wagamama with Sam");
        assert_eq!(dictation.removed, vec![0, 1, 2, 3, 4]);
    }

    #[test]
    fn dictation_invented_word_rejected() {
        let dictation = clean(
            "Lunch at Wagamama",
            "Lunch at the Wagamama",
            VoiceLanguage::En,
        );
        assert_eq!(dictation, Dictation::unchanged("Lunch at Wagamama"));
    }

    #[test]
    fn dictation_reworded_output_rejected() {
        let dictation = clean(
            "Buy oat milk, no wait, almond milk",
            "Buy almond-based milk",
            VoiceLanguage::En,
        );
        assert_eq!(dictation.cleaned, "Buy oat milk, no wait, almond milk");
        assert!(dictation.removed.is_empty());
    }

    #[test]
    fn dictation_nothing_to_clean() {
        let dictation = clean(
            "Team lunch at Wagamama",
            "Team lunch at Wagamama",
            VoiceLanguage::En,
        );
        assert_eq!(dictation.cleaned, "Team lunch at Wagamama");
        assert!(dictation.removed.is_empty());
    }

    #[test]
    fn dictation_spanish_corrections() {
        let dictation = clean(
            "Comprar leche de avena, digo, leche de almendra",
            "Comprar leche de almendra",
            VoiceLanguage::Es,
        );
        assert_eq!(dictation.cleaned, "Comprar leche de almendra");
        assert_eq!(dictation.removed.len(), 4);
        let dictation = clean(
            "Llamar el martes, mejor dicho el miércoles",
            "Llamar el miercoles",
            VoiceLanguage::Es,
        );
        assert_eq!(dictation.cleaned, "Llamar el miércoles");
    }

    #[test]
    fn dictation_empty_output_falls_back() {
        let dictation = clean("Buy eggs", "", VoiceLanguage::En);
        assert_eq!(dictation, Dictation::unchanged("Buy eggs"));
        let mut garbage = scripted("not json");
        assert_eq!(
            VoiceEngine::new()
                .clean(&mut garbage, "Buy eggs", VoiceLanguage::En)
                .unwrap(),
            Dictation::unchanged("Buy eggs")
        );
    }

    #[test]
    fn dictation_low_memory_passes_through() {
        struct Failing;
        impl ModelRunner for Failing {
            fn complete(&mut self, _: &str, _: &Grammar) -> Result<String, VoiceError> {
                Err(VoiceError::LowMemory)
            }
        }
        assert_eq!(
            VoiceEngine::new().clean(&mut Failing, "Buy eggs", VoiceLanguage::En),
            Err(VoiceError::LowMemory)
        );
    }

    #[test]
    fn the_same_schema_compiles_once() {
        let mut engine = VoiceEngine::new();
        let mut runner = scripted("[]");
        for _ in 0..2 {
            let _ = engine.fill(&mut runner, "x", &request(expense_fields()));
        }
        assert_eq!(engine.grammar_compilations(), 1);
    }
}
