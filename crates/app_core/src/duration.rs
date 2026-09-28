//! The one text grammar for durations, shared by the record form and voice input.
//!
//! A duration text is an optional sign (`-`, `−` or `+`) followed by one or more parts, each a
//! whole number and a unit (`h`, `m`/`min`, `s`/`sec`, `ms`), in any order, each unit at most
//! once. Units are case-insensitive and spaces between parts are optional. The value is the signed
//! sum in milliseconds.

use thiserror::Error;

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum DurationParseError {
    #[error("enter a duration")]
    Empty,
    #[error("{number} needs a unit such as h, m, s or ms")]
    MissingUnit { number: String },
    #[error("\"{unit}\" is not a duration unit; use h, m, s or ms")]
    UnknownUnit { unit: String },
    #[error("the unit {unit} appears more than once")]
    RepeatedUnit { unit: &'static str },
    #[error("unexpected \"{found}\"; use units like 1h 30m")]
    Unexpected { found: char },
    #[error("the duration is too large")]
    Overflow,
}

const UNITS: [(&str, i128); 4] = [("h", 3_600_000), ("m", 60_000), ("s", 1_000), ("ms", 1)];

/// Parses a duration text into signed milliseconds.
pub fn parse_duration(text: &str) -> Result<i64, DurationParseError> {
    let mut chars = text.trim().chars().peekable();
    let negative = match chars.peek() {
        Some('-' | '−') => {
            chars.next();
            true
        }
        Some('+') => {
            chars.next();
            false
        }
        _ => false,
    };
    let mut seen = [false; UNITS.len()];
    let mut total: i128 = 0;
    let mut parts = 0;
    loop {
        while chars.next_if(|c| c.is_whitespace()).is_some() {}
        let Some(&first) = chars.peek() else { break };
        if !first.is_ascii_digit() {
            return Err(DurationParseError::Unexpected { found: first });
        }
        let mut number = String::new();
        while let Some(digit) = chars.next_if(char::is_ascii_digit) {
            number.push(digit);
        }
        while chars.next_if(|c| c.is_whitespace()).is_some() {}
        let mut unit = String::new();
        while let Some(letter) = chars.next_if(|c| c.is_alphabetic()) {
            unit.extend(letter.to_lowercase());
        }
        if unit.is_empty() {
            return Err(DurationParseError::MissingUnit { number });
        }
        let index = match unit.as_str() {
            "h" => 0,
            "m" | "min" => 1,
            "s" | "sec" => 2,
            "ms" => 3,
            _ => return Err(DurationParseError::UnknownUnit { unit }),
        };
        if std::mem::replace(&mut seen[index], true) {
            return Err(DurationParseError::RepeatedUnit {
                unit: UNITS[index].0,
            });
        }
        let value: i128 = number.parse().map_err(|_| DurationParseError::Overflow)?;
        total = value
            .checked_mul(UNITS[index].1)
            .and_then(|part| total.checked_add(part))
            .ok_or(DurationParseError::Overflow)?;
        parts += 1;
    }
    if parts == 0 {
        return Err(DurationParseError::Empty);
    }
    let signed = if negative { -total } else { total };
    i64::try_from(signed).map_err(|_| DurationParseError::Overflow)
}

/// Formats milliseconds as the canonical short form, for example "1h 30m", "-45s" or "0s".
#[must_use]
pub fn format_duration(milliseconds: i64) -> String {
    if milliseconds == 0 {
        return "0s".into();
    }
    let mut remaining = u128::from(milliseconds.unsigned_abs());
    let mut parts = Vec::new();
    for (unit, size) in UNITS {
        let size = u128::try_from(size).expect("unit sizes are positive");
        let count = remaining / size;
        remaining %= size;
        if count > 0 {
            parts.push(format!("{count}{unit}"));
        }
    }
    let sign = if milliseconds < 0 { "-" } else { "" };
    format!("{sign}{}", parts.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hours_and_minutes() {
        assert_eq!(parse_duration("1h 30m"), Ok(5_400_000));
        assert_eq!(parse_duration("1h30m"), Ok(5_400_000));
        assert_eq!(parse_duration("90m"), Ok(5_400_000));
        assert_eq!(parse_duration("1h 5m 30s 250ms"), Ok(3_930_250));
        assert_eq!(parse_duration("30s 1h"), Ok(3_630_000));
        assert_eq!(parse_duration("2 min 3 sec"), Ok(123_000));
    }

    #[test]
    fn parses_signs() {
        assert_eq!(parse_duration("−45s"), Ok(-45_000));
        assert_eq!(parse_duration("-45s"), Ok(-45_000));
        assert_eq!(parse_duration("+45s"), Ok(45_000));
        assert_eq!(parse_duration("- 1m"), Ok(-60_000));
    }

    #[test]
    fn units_are_case_insensitive() {
        assert_eq!(parse_duration("1H 30M"), Ok(5_400_000));
        assert_eq!(parse_duration("2MIN 5Sec 7MS"), Ok(125_007));
    }

    #[test]
    fn missing_unit_is_rejected_and_named() {
        let error = parse_duration("90").unwrap_err();
        assert_eq!(
            error,
            DurationParseError::MissingUnit {
                number: "90".into()
            }
        );
        assert!(error.to_string().contains("unit"));
        assert!(matches!(
            parse_duration("1h 30"),
            Err(DurationParseError::MissingUnit { .. })
        ));
    }

    #[test]
    fn repeated_unit_is_rejected() {
        assert_eq!(
            parse_duration("1h 2h"),
            Err(DurationParseError::RepeatedUnit { unit: "h" })
        );
        assert_eq!(
            parse_duration("1m 2min"),
            Err(DurationParseError::RepeatedUnit { unit: "m" })
        );
    }

    #[test]
    fn empty_and_malformed_text_is_rejected() {
        assert_eq!(parse_duration(""), Err(DurationParseError::Empty));
        assert_eq!(parse_duration("  "), Err(DurationParseError::Empty));
        assert_eq!(parse_duration("-"), Err(DurationParseError::Empty));
        assert!(matches!(
            parse_duration("an hour"),
            Err(DurationParseError::Unexpected { found: 'a' })
        ));
        assert!(matches!(
            parse_duration("1d"),
            Err(DurationParseError::UnknownUnit { .. })
        ));
        assert!(parse_duration("1.5h").is_err());
    }

    #[test]
    fn overflow_is_rejected() {
        assert_eq!(
            parse_duration("9223372036854775808ms"),
            Err(DurationParseError::Overflow)
        );
        assert_eq!(parse_duration("-9223372036854775808ms"), Ok(i64::MIN));
        assert_eq!(
            parse_duration("3000000000000h"),
            Err(DurationParseError::Overflow)
        );
        assert_eq!(
            parse_duration("999999999999999999999999999999999999999999h"),
            Err(DurationParseError::Overflow)
        );
    }

    #[test]
    fn formats_canonically() {
        assert_eq!(format_duration(5_400_000), "1h 30m");
        assert_eq!(format_duration(-45_000), "-45s");
        assert_eq!(format_duration(0), "0s");
        assert_eq!(format_duration(250), "250ms");
        assert_eq!(format_duration(90_000_000), "25h");
    }

    #[test]
    fn formatted_values_round_trip() {
        assert_eq!(format_duration(5_430_250), "1h 30m 30s 250ms");
        for value in [5_430_250, -5_430_250, 0, 1, -1, i64::MAX, i64::MIN, 59_999] {
            assert_eq!(parse_duration(&format_duration(value)), Ok(value));
        }
    }
}
