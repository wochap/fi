//! Deterministic span-to-value rules. A span that does not convert yields `None` and is dropped.

mod choice;
mod dates;
mod duration;
pub mod es;
mod numbers;

pub use choice::{levenshtein, normalize_choice};
pub use dates::{normalize_date, normalize_date_time};
pub use duration::normalize_duration;
pub use numbers::{normalize_decimal, normalize_integer, parse_number};

use crate::{FieldKind, FillRequest, TypedValue, VoiceField, VoiceLanguage};

/// Converts a span with the turn's language rules. Text and Choice are shared.
pub fn normalize(field: &VoiceField, span: &str, request: &FillRequest) -> Option<TypedValue> {
    let (today, now, offset) = (request.today, request.now, request.utc_offset_minutes);
    match (field.kind.clone(), request.language) {
        (FieldKind::Text, _) => normalize_text(span, field.max_length).map(TypedValue::Text),
        (FieldKind::Choice, _) => normalize_choice(span, &field.options).map(TypedValue::Choice),
        // One label of a set; the patch gathers the labels of an entry.
        (FieldKind::Choices, _) => {
            normalize_choice(span, &field.options).map(|id| TypedValue::Choices(vec![id]))
        }
        (FieldKind::Integer, VoiceLanguage::En) => normalize_integer(span).map(TypedValue::Integer),
        (FieldKind::Integer, VoiceLanguage::Es) => {
            es::normalize_integer(span).map(TypedValue::Integer)
        }
        (FieldKind::Decimal { scale }, VoiceLanguage::En) => {
            normalize_decimal(span, scale).map(TypedValue::Decimal)
        }
        (FieldKind::Decimal { scale }, VoiceLanguage::Es) => {
            es::normalize_decimal(span, scale).map(TypedValue::Decimal)
        }
        (FieldKind::Boolean, VoiceLanguage::En) => normalize_boolean(span).map(TypedValue::Boolean),
        (FieldKind::Boolean, VoiceLanguage::Es) => {
            es::normalize_boolean(span).map(TypedValue::Boolean)
        }
        (FieldKind::Date, VoiceLanguage::En) => {
            normalize_date(span, today).map(|date| TypedValue::Date(dates::epoch_days(date)))
        }
        (FieldKind::Date, VoiceLanguage::Es) => {
            es::normalize_date(span, today).map(|date| TypedValue::Date(dates::epoch_days(date)))
        }
        (FieldKind::DateTime, VoiceLanguage::En) => {
            normalize_date_time(span, today, now, offset).map(TypedValue::DateTime)
        }
        (FieldKind::DateTime, VoiceLanguage::Es) => {
            es::normalize_date_time(span, today, now, offset).map(TypedValue::DateTime)
        }
        (FieldKind::Duration, VoiceLanguage::En) => {
            normalize_duration(span).map(TypedValue::Duration)
        }
        (FieldKind::Duration, VoiceLanguage::Es) => {
            es::normalize_duration(span).map(TypedValue::Duration)
        }
    }
}

/// The span as spoken, trimmed; dropped when empty or longer than the field allows.
pub fn normalize_text(span: &str, max_length: Option<u32>) -> Option<String> {
    let text = span.trim();
    let fits = max_length.is_none_or(|max| text.chars().count() <= max as usize);
    (!text.is_empty() && fits).then(|| text.to_owned())
}

pub fn normalize_boolean(span: &str) -> Option<bool> {
    match crate::patch::normalize_text(span).as_str() {
        "yes" | "true" | "on" | "yeah" | "yep" => Some(true),
        "no" | "false" | "off" | "nope" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn booleans() {
        for (span, value) in [
            ("yes", Some(true)),
            ("Yes.", Some(true)),
            ("true", Some(true)),
            ("on", Some(true)),
            ("no", Some(false)),
            ("False", Some(false)),
            ("off", Some(false)),
            ("maybe", None),
            ("", None),
        ] {
            assert_eq!(normalize_boolean(span), value, "{span}");
        }
    }

    #[test]
    fn normalize_dispatches_on_the_language() {
        use crate::test_support::{field, request};
        let amount = field("f-amount", "amount", FieldKind::Decimal { scale: 2 });
        let mut spanish = request(vec![amount.clone()]);
        spanish.language = VoiceLanguage::Es;
        assert_eq!(
            normalize(&amount, "doce con cincuenta", &spanish),
            Some(TypedValue::Decimal(1250))
        );
        assert_eq!(
            normalize(
                &amount,
                "doce con cincuenta",
                &request(vec![amount.clone()])
            ),
            None
        );
    }

    #[test]
    fn booleans_es() {
        for (span, value) in [
            ("sí", Some(true)),
            ("Si.", Some(true)),
            ("no", Some(false)),
            ("falso", Some(false)),
            ("yes", None),
            ("quizá", None),
        ] {
            assert_eq!(es::normalize_boolean(span), value, "{span}");
        }
    }

    #[test]
    fn text_is_trimmed_and_length_checked() {
        assert_eq!(
            normalize_text("  Taxi home ", None),
            Some("Taxi home".into())
        );
        assert_eq!(
            normalize_text("Taxi home", Some(9)),
            Some("Taxi home".into())
        );
        assert_eq!(normalize_text("Taxi home", Some(8)), None);
        assert_eq!(normalize_text("   ", None), None);
    }
}
