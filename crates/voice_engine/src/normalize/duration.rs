//! Durations: the core duration grammar, plus spoken forms rewritten into it
//! ("45 minutes" → `45m`, "an hour and a half" → `1h 30m`, "ninety seconds" → `90s`).

use app_core::duration::parse_duration;

use super::numbers::{normalize_integer, tokens};

/// Unit index into `h, m, s, ms`.
fn unit(word: &str) -> Option<usize> {
    Some(match word {
        "h" | "hr" | "hrs" | "hour" | "hours" => 0,
        "m" | "min" | "mins" | "minute" | "minutes" => 1,
        "s" | "sec" | "secs" | "second" | "seconds" => 2,
        "ms" | "millisecond" | "milliseconds" => 3,
        _ => return None,
    })
}

/// Half of one unit, in the next smaller unit.
const HALF: [(usize, i64); 3] = [(1, 30), (2, 30), (3, 500)];

/// Rewrites a spoken duration into the core grammar.
fn rewrite(span: &str) -> Option<String> {
    let tokens = tokens(span);
    let words: Vec<&str> = tokens.iter().map(String::as_str).collect();
    let mut parts = [0i64; 4];
    let mut any = false;
    let mut number: Vec<&str> = Vec::new();
    let mut index = 0;
    while index < words.len() {
        let word = words[index];
        index += 1;
        let Some(unit) = unit(word) else {
            number.push(word);
            continue;
        };
        // "half an hour": the number is a half.
        let (count, half) = match number.as_slice() {
            ["half", "an" | "a"] => (0, true),
            ["a" | "an"] => (1, false),
            [] => return None,
            words => {
                let (words, half) = match words {
                    [head @ .., "and", "a", "half"] => (head, true),
                    words => (words, false),
                };
                let words: Vec<&str> = words.iter().copied().filter(|w| *w != "and").collect();
                if words.is_empty() {
                    return None;
                }
                (normalize_integer(&words.join(" "))?, half)
            }
        };
        number.clear();
        parts[unit] = parts[unit].checked_add(count)?;
        // "an hour and a half": the half follows the unit.
        let trailing = words[index..].starts_with(&["and", "a", "half"]);
        if trailing {
            index += 3;
        }
        if half || trailing {
            let (smaller, amount) = *HALF.get(unit)?;
            parts[smaller] = parts[smaller].checked_add(amount)?;
        }
        any = true;
    }
    if !number.iter().all(|word| *word == "and") || !any {
        return None;
    }
    let names = ["h", "m", "s", "ms"];
    let text: Vec<String> = parts
        .iter()
        .zip(names)
        .filter(|(count, _)| **count != 0)
        .map(|(count, name)| format!("{count}{name}"))
        .collect();
    Some(if text.is_empty() {
        "0s".into()
    } else {
        text.join(" ")
    })
}

/// Milliseconds.
pub fn normalize_duration(span: &str) -> Option<i64> {
    parse_duration(span)
        .ok()
        .or_else(|| parse_duration(&rewrite(span)?).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        for (span, expected) in [
            ("1h 30m", Some(5_400_000)),
            ("45m", Some(2_700_000)),
            ("45 minutes", Some(2_700_000)),
            ("an hour and a half", Some(5_400_000)),
            ("one and a half hours", Some(5_400_000)),
            ("half an hour", Some(1_800_000)),
            ("ninety seconds", Some(90_000)),
            ("2 hours 15 minutes", Some(8_100_000)),
            ("two hours and fifteen minutes", Some(8_100_000)),
            ("a minute and a half", Some(90_000)),
            ("an hour", Some(3_600_000)),
            ("a while", None),
            ("minutes", None),
            ("twenty", None),
        ] {
            assert_eq!(normalize_duration(span), expected, "{span}");
        }
    }
}
