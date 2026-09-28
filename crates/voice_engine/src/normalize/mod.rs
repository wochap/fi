//! Deterministic span-to-value rules. A span that does not convert yields `None` and is dropped.

mod choice;
mod dates;
mod duration;
mod numbers;

pub use choice::{levenshtein, normalize_choice};
pub use dates::{normalize_date, normalize_date_time};
pub use duration::normalize_duration;
pub use numbers::{normalize_decimal, normalize_integer, parse_number};

use crate::{FieldKind, FillRequest, TypedValue, VoiceField};

pub fn normalize(field: &VoiceField, span: &str, request: &FillRequest) -> Option<TypedValue> {
    match field.kind {
        FieldKind::Text => normalize_text(span, field.max_length).map(TypedValue::Text),
        FieldKind::Integer => normalize_integer(span).map(TypedValue::Integer),
        FieldKind::Decimal { scale } => normalize_decimal(span, scale).map(TypedValue::Decimal),
        FieldKind::Boolean => normalize_boolean(span).map(TypedValue::Boolean),
        FieldKind::Date => normalize_date(span, request.today)
            .map(|date| TypedValue::Date(dates::epoch_days(date))),
        FieldKind::DateTime => {
            normalize_date_time(span, request.today, request.now, request.utc_offset_minutes)
                .map(TypedValue::DateTime)
        }
        FieldKind::Duration => normalize_duration(span).map(TypedValue::Duration),
        FieldKind::Choice => normalize_choice(span, &field.options).map(TypedValue::Choice),
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
