//! Model output to patch: parse, drop `null` and duplicates (first wins), check evidence against
//! the transcript, and normalize the surviving spans.

use serde::Deserialize;
use serde_json::Value;

use crate::{FieldKind, FillOutcome, FillRequest, PatchEntry, VoiceField, normalize};

/// One entry as the model wrote it.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct RawEntry {
    pub field: String,
    pub value: Value,
    #[serde(default)]
    pub evidence: String,
}

/// What happened to the model's entries.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PatchStats {
    /// Non-null entries for known fields, after duplicates are removed.
    pub proposed: usize,
    pub evidence_rejected: usize,
    pub unconvertible: usize,
}

/// Parses the model's JSON; anything that is not a patch array reads as empty.
pub fn parse_entries(output: &str) -> Vec<RawEntry> {
    serde_json::from_str::<Vec<Value>>(output.trim())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|entry| serde_json::from_value(entry).ok())
        .collect()
}

/// Lowercase words: apostrophes vanish, other punctuation separates, whitespace collapses.
pub fn normalize_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = true;
    for c in text.chars() {
        if c == '\'' || c == '’' {
            continue;
        }
        if c.is_alphanumeric() {
            out.extend(c.to_lowercase());
            space = false;
        } else if !space {
            out.push(' ');
            space = true;
        }
    }
    if out.ends_with(' ') {
        out.pop();
    }
    out
}

/// Whether `needle`'s words occur as a contiguous run in `haystack`'s words.
fn contains_words(haystack: &str, needle: &str) -> bool {
    let needle = normalize_text(needle);
    !needle.is_empty() && format!(" {} ", normalize_text(haystack)).contains(&format!(" {needle} "))
}

/// Evidence occurs in the transcript, and the value span within the evidence.
pub fn evidence_holds(transcript: &str, evidence: &str, span: Option<&str>) -> bool {
    contains_words(transcript, evidence) && span.is_none_or(|span| contains_words(evidence, span))
}

pub fn build_patch(
    output: &str,
    transcript: &str,
    fields: &[VoiceField],
    request: &FillRequest,
) -> FillOutcome {
    let mut stats = PatchStats::default();
    let mut seen: Vec<&str> = Vec::new();
    let mut patch = Vec::new();
    for entry in parse_entries(output) {
        let Some(field) = fields.iter().find(|field| field.name == entry.field) else {
            continue;
        };
        if entry.value.is_null() || seen.contains(&field.id.as_str()) {
            continue;
        }
        seen.push(&field.id);
        stats.proposed += 1;
        let span = match &entry.value {
            Value::String(span) => Some(span.as_str()),
            Value::Bool(_) if field.kind == FieldKind::Boolean => None,
            _ => {
                stats.unconvertible += 1;
                continue;
            }
        };
        if !evidence_holds(transcript, &entry.evidence, span) {
            stats.evidence_rejected += 1;
            continue;
        }
        let value = match (&entry.value, span) {
            (Value::Bool(value), _) => Some(crate::TypedValue::Boolean(*value)),
            (_, Some(span)) => normalize::normalize(field, span, request),
            _ => None,
        };
        match value {
            Some(value) => patch.push(PatchEntry {
                field_id: field.id.clone(),
                value,
                evidence: entry.evidence.trim().to_owned(),
            }),
            None => stats.unconvertible += 1,
        }
    }
    FillOutcome { patch, stats }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TypedValue, test_support::*};

    fn patch(output: &str, transcript: &str) -> FillOutcome {
        let request = request(expense_fields());
        build_patch(output, transcript, &request.fields, &request)
    }

    #[test]
    fn invented_values_are_removed() {
        let outcome = patch(
            r#"[{"field":"amount","value":"20","evidence":"twenty"},
                {"field":"description","value":"Taxi home","evidence":"Taxi home"}]"#,
            "Taxi home yesterday",
        );
        assert_eq!(outcome.patch.len(), 1);
        assert_eq!(outcome.patch[0].field_id, "f-desc");
        assert_eq!(outcome.stats.evidence_rejected, 1);
    }

    #[test]
    fn value_must_lie_within_the_evidence() {
        let outcome = patch(
            r#"[{"field":"category","value":"transport","evidence":"taxi"}]"#,
            "taxi home",
        );
        assert!(outcome.patch.is_empty());
        assert_eq!(outcome.stats.evidence_rejected, 1);
    }

    #[test]
    fn duplicates_keep_the_first_and_null_is_not_said() {
        let outcome = patch(
            r#"[{"field":"amount","value":"12","evidence":"12 dollars"},
                {"field":"amount","value":"13","evidence":"13"},
                {"field":"category","value":null,"evidence":""},
                {"field":"nope","value":"x","evidence":"x"}]"#,
            "12 dollars or 13",
        );
        assert_eq!(
            outcome.patch,
            vec![PatchEntry {
                field_id: "f-amount".into(),
                value: TypedValue::Decimal(1200),
                evidence: "12 dollars".into(),
            }]
        );
        assert_eq!(outcome.stats.proposed, 1);
    }

    #[test]
    fn evidence_ignores_case_whitespace_and_punctuation() {
        assert!(!evidence_holds(
            "Lunch at Nando's,   twelve fifty.",
            "lunch nandos",
            None
        ));
        assert!(evidence_holds(
            "Lunch at Nando's,   twelve fifty.",
            "LUNCH at nandos",
            Some("Nando's")
        ));
        assert!(!evidence_holds("home", "", None));
        assert!(!evidence_holds("the cathedral", "cat", None));
    }

    #[test]
    fn nothing_matched_is_an_empty_patch() {
        assert!(patch("[]", "anything").patch.is_empty());
        assert!(patch("not json", "anything").patch.is_empty());
    }
}
