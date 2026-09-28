//! Schema to GBNF grammar and prompt.
//!
//! A patch is a JSON array of `{"field":…,"value":…,"evidence":…}` entries. Each entry
//! alternative fixes one field name and the value shape of its kind. Plain GBNF cannot forbid a
//! field appearing twice without combinatorial growth, so duplicates are removed when the patch is
//! parsed (first wins).

use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    sync::Arc,
};

use app_core::schema::{FieldDefinition, FieldType};
use chrono::Datelike;

use crate::{ChoiceOption, FieldKind, FillRequest, VoiceField};

const CACHE_SIZE: usize = 8;

/// A compiled patch grammar for one schema version.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Grammar {
    gbnf: Arc<str>,
    key: u64,
}

impl Grammar {
    /// The GBNF text; its start rule is `root`.
    pub fn gbnf(&self) -> &str {
        &self.gbnf
    }

    /// The schema hash, stable while the schema does not change.
    pub fn key(&self) -> u64 {
        self.key
    }
}

/// An LRU of compiled grammars keyed by collection id and schema hash.
#[derive(Debug, Default)]
pub struct GrammarCache {
    entries: Vec<(String, u64, Grammar)>,
    compilations: usize,
}

impl GrammarCache {
    pub fn get(&mut self, collection_id: &str, fields: &[VoiceField]) -> Grammar {
        let hash = schema_hash(fields);
        if let Some(index) = self
            .entries
            .iter()
            .position(|(id, key, _)| id == collection_id && *key == hash)
        {
            let entry = self.entries.remove(index);
            let grammar = entry.2.clone();
            self.entries.push(entry);
            return grammar;
        }
        self.compilations += 1;
        let grammar = Grammar {
            gbnf: build_grammar(fields).into(),
            key: hash,
        };
        if self.entries.len() == CACHE_SIZE {
            self.entries.remove(0);
        }
        self.entries
            .push((collection_id.to_owned(), hash, grammar.clone()));
        grammar
    }

    pub fn compilations(&self) -> usize {
        self.compilations
    }
}

fn schema_hash(fields: &[VoiceField]) -> u64 {
    let mut hasher = DefaultHasher::new();
    fields.hash(&mut hasher);
    hasher.finish()
}

/// The engine's fields for a schema: active fields in form order, with live options only.
pub fn voice_fields(definitions: &[FieldDefinition]) -> Vec<VoiceField> {
    let mut active: Vec<&FieldDefinition> = definitions.iter().filter(|f| !f.deleted).collect();
    active.sort_by_key(|field| field.order);
    active
        .into_iter()
        .map(|field| {
            let mut options: Vec<_> = field.enum_options.iter().filter(|o| !o.deleted).collect();
            options.sort_by_key(|option| option.order);
            VoiceField {
                id: field.id.to_string(),
                name: field.name.clone(),
                kind: match field.field_type {
                    FieldType::Text => FieldKind::Text,
                    FieldType::Integer => FieldKind::Integer,
                    FieldType::FixedDecimal { scale } => FieldKind::Decimal { scale },
                    FieldType::Boolean => FieldKind::Boolean,
                    FieldType::Date => FieldKind::Date,
                    FieldType::DateTime => FieldKind::DateTime,
                    FieldType::Duration => FieldKind::Duration,
                    FieldType::Enum => FieldKind::Choice,
                },
                required: field.required,
                options: options
                    .into_iter()
                    .map(|option| ChoiceOption {
                        id: option.id.to_string(),
                        label: option.label.clone(),
                    })
                    .collect(),
                max_length: field.validation.max_length,
            }
        })
        .collect()
}

/// A GBNF string literal matching the JSON encoding of `text`.
fn json_literal(text: &str) -> String {
    let json = serde_json::to_string(text).expect("strings serialize");
    let mut out = String::from("\"");
    for c in json.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn build_grammar(fields: &[VoiceField]) -> String {
    let mut rules = Vec::new();
    let mut entries = Vec::new();
    for (index, field) in fields.iter().enumerate() {
        let value = match field.kind {
            FieldKind::Boolean => "(\"true\" | \"false\" | \"null\")".to_owned(),
            FieldKind::Choice => {
                let mut labels: Vec<String> = field
                    .options
                    .iter()
                    .map(|option| json_literal(&option.label))
                    .collect();
                labels.push("\"null\"".into());
                format!("({})", labels.join(" | "))
            }
            _ => "(span | \"null\")".to_owned(),
        };
        let name = format!("e{index}");
        rules.push(format!(
            "{name} ::= \"{{\" ws \"\\\"field\\\"\" ws \":\" ws {} ws \",\" ws \"\\\"value\\\"\" ws \":\" ws {value} ws \",\" ws \"\\\"evidence\\\"\" ws \":\" ws string ws \"}}\"",
            json_literal(&field.name)
        ));
        entries.push(name);
    }
    let mut gbnf = String::new();
    if entries.is_empty() {
        gbnf.push_str("root ::= \"[]\"\n");
    } else {
        gbnf.push_str("root ::= \"[\" ws ( entry ( ws \",\" ws entry )* )? ws \"]\"\n");
        gbnf.push_str(&format!("entry ::= {}\n", entries.join(" | ")));
        for rule in rules {
            gbnf.push_str(&rule);
            gbnf.push('\n');
        }
    }
    gbnf.push_str("span ::= \"\\\"\" char+ \"\\\"\"\n");
    gbnf.push_str("string ::= \"\\\"\" char* \"\\\"\"\n");
    gbnf.push_str(
        "char ::= [^\"\\\\\\x7F\\x00-\\x1F] | \"\\\\\" ([\"\\\\/bfnrt] | \"u\" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])\n",
    );
    gbnf.push_str("ws ::= [ \\n]?\n");
    gbnf
}

fn kind_label(field: &VoiceField) -> String {
    match &field.kind {
        FieldKind::Text => "text".into(),
        FieldKind::Integer => "whole number".into(),
        FieldKind::Decimal { .. } => "decimal".into(),
        FieldKind::Boolean => "yes/no".into(),
        FieldKind::Date => "date".into(),
        FieldKind::DateTime => "date and time".into(),
        FieldKind::Duration => "duration".into(),
        FieldKind::Choice => format!(
            "choice: {}",
            field
                .options
                .iter()
                .map(|option| option.label.as_str())
                .collect::<Vec<_>>()
                .join("|")
        ),
    }
}

const SYSTEM: &str = "You fill form fields from a spoken note. Output JSON only: an array of \
{\"field\",\"value\",\"evidence\"} entries, at most one per field. Use null for anything not said; \
never guess. Copy value and evidence words exactly from the transcript. Evidence is the shortest \
part of the transcript that states the value.";

/// The Qwen chat prompt for one turn. Empty draft values are omitted to keep it short.
pub fn build_prompt(fields: &[VoiceField], request: &FillRequest, transcript: &str) -> String {
    let mut user = format!(
        "Today: {} {}\nFields:\n",
        request.today.weekday_name(),
        request.today.format("%Y-%m-%d")
    );
    for field in fields {
        user.push_str(&format!("- {} ({}", field.name, kind_label(field)));
        if field.required {
            user.push_str(", required");
        }
        user.push(')');
        if let Some((_, value)) = request
            .draft
            .iter()
            .find(|(id, value)| *id == field.id && !value.trim().is_empty())
        {
            user.push_str(&format!(" = {value}"));
        }
        user.push('\n');
    }
    user.push_str(&format!("Transcript: {}", transcript.trim()));
    format!(
        "<|im_start|>system\n{SYSTEM}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n"
    )
}

trait WeekdayName {
    fn weekday_name(&self) -> &'static str;
}

impl WeekdayName for chrono::NaiveDate {
    fn weekday_name(&self) -> &'static str {
        match self.weekday() {
            chrono::Weekday::Mon => "Monday",
            chrono::Weekday::Tue => "Tuesday",
            chrono::Weekday::Wed => "Wednesday",
            chrono::Weekday::Thu => "Thursday",
            chrono::Weekday::Fri => "Friday",
            chrono::Weekday::Sat => "Saturday",
            chrono::Weekday::Sun => "Sunday",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use app_core::schema::{
        DisplayMetadata, EnumOption, EnumOptionId, FieldId, ValidationMetadata,
    };

    fn definition(name: &str, field_type: FieldType, order: i64, deleted: bool) -> FieldDefinition {
        FieldDefinition {
            id: FieldId::new(),
            name: name.into(),
            field_type,
            required: false,
            default: None,
            default_relative_days: None,
            validation: ValidationMetadata::default(),
            display: DisplayMetadata::default(),
            order,
            deleted,
            enum_options: Vec::new(),
        }
    }

    #[test]
    fn grammar_names_every_active_field_and_choice_label() {
        let mut category = definition("category", FieldType::Enum, 2, false);
        category.enum_options = ["food", "transport", "home", "gone"]
            .iter()
            .enumerate()
            .map(|(order, label)| EnumOption {
                id: EnumOptionId::new(),
                label: (*label).into(),
                order: order as i64,
                deleted: *label == "gone",
            })
            .collect();
        let definitions = vec![
            definition("amount", FieldType::FixedDecimal { scale: 2 }, 1, false),
            category,
            definition("old notes", FieldType::Text, 3, true),
            definition("paid", FieldType::Boolean, 4, false),
        ];
        let fields = voice_fields(&definitions);
        let gbnf = build_grammar(&fields);
        for name in ["amount", "category", "paid"] {
            assert!(gbnf.contains(&format!("\"\\\"{name}\\\"\"")), "{name}");
        }
        for label in ["food", "transport", "home"] {
            assert!(gbnf.contains(&format!("\"\\\"{label}\\\"\"")), "{label}");
        }
        assert!(!gbnf.contains("old notes"));
        assert!(!gbnf.contains("gone"));
        assert!(gbnf.contains("(\"true\" | \"false\" | \"null\")"));
    }

    #[test]
    fn names_with_quotes_are_escaped() {
        let gbnf = build_grammar(&[field("f", "say \"hi\"", FieldKind::Text)]);
        assert!(gbnf.contains(r#""\"say \\\"hi\\\"\"""#), "{gbnf}");
    }

    #[test]
    fn cache_compiles_once_per_schema_and_evicts_least_recent() {
        let mut cache = GrammarCache::default();
        let fields = expense_fields();
        let first = cache.get("c1", &fields);
        assert_eq!(cache.get("c1", &fields), first);
        assert_eq!(cache.compilations(), 1);
        let mut changed = fields.clone();
        changed.pop();
        cache.get("c1", &changed);
        assert_eq!(cache.compilations(), 2);
        for index in 0..CACHE_SIZE {
            cache.get(&format!("other{index}"), &fields);
        }
        cache.get("c1", &fields);
        assert_eq!(cache.compilations(), 2 + CACHE_SIZE + 1);
    }

    #[test]
    fn prompt_lists_fields_draft_and_today() {
        let mut request = request(expense_fields());
        request.draft = vec![
            ("f-desc".into(), "Taxi".into()),
            ("f-date".into(), " ".into()),
        ];
        let prompt = build_prompt(&request.fields, &request, " Taxi home ");
        assert!(prompt.contains("Today: Monday 2026-09-28"));
        assert!(prompt.contains("- description (text, required) = Taxi\n"));
        assert!(prompt.contains("- amount (decimal, required)\n"));
        assert!(prompt.contains("- category (choice: food|transport|home|other)\n"));
        assert!(prompt.contains("- date (date)\n"));
        assert!(prompt.contains("Transcript: Taxi home<|im_end|>"));
        assert!(prompt.contains("null"));
        assert!(prompt.ends_with("<|im_start|>assistant\n"));
    }
}
