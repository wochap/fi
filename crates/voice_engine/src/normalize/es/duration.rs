//! Spanish durations, rewritten into the core duration grammar
//! ("45 minutos" → `45m`, "una hora y media" → `1h 30m`, "media hora" → `30m`).

use app_core::duration::parse_duration;

use super::numbers::{normalize_integer, tokens_es};

/// Unit index into `h, m, s, ms`.
fn unit(word: &str) -> Option<usize> {
    Some(match word {
        "h" | "hora" | "horas" => 0,
        "min" | "minuto" | "minutos" => 1,
        "s" | "seg" | "segundo" | "segundos" => 2,
        "ms" | "milisegundo" | "milisegundos" => 3,
        _ => return None,
    })
}

/// Half of one unit, in the next smaller unit.
const HALF: [(usize, i64); 3] = [(1, 30), (2, 30), (3, 500)];

/// Rewrites a spoken Spanish duration into the core grammar.
fn rewrite(span: &str) -> Option<String> {
    let tokens = tokens_es(span);
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
        let rest = &words[index..];
        let trailing_half = rest.starts_with(&["y", "media"]) || rest.starts_with(&["y", "medio"]);
        let trailing_quarter = unit == 0 && rest.starts_with(&["y", "cuarto"]);
        let (count, half) = match number.as_slice() {
            ["media" | "medio"] => (0, true),
            ["un" | "una" | "uno"] => (1, false),
            // A bare leading "hora y media" is one hour.
            [] if !any && (trailing_half || trailing_quarter) => (1, false),
            [] => return None,
            words => {
                let words: Vec<&str> = words.iter().copied().filter(|w| *w != "y").collect();
                if words.is_empty() {
                    return None;
                }
                (normalize_integer(&words.join(" "))?, false)
            }
        };
        number.clear();
        parts[unit] = parts[unit].checked_add(count)?;
        if trailing_half || trailing_quarter {
            index += 2;
        }
        if half || trailing_half {
            let (smaller, amount) = *HALF.get(unit)?;
            parts[smaller] = parts[smaller].checked_add(amount)?;
        }
        if trailing_quarter {
            parts[1] = parts[1].checked_add(15)?;
        }
        any = true;
    }
    if !number.iter().all(|word| *word == "y") || !any {
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
    fn durations_es() {
        for (span, expected) in [
            ("1h 30m", Some(5_400_000)),
            ("45 minutos", Some(2_700_000)),
            ("una hora y media", Some(5_400_000)),
            ("hora y media", Some(5_400_000)),
            ("media hora", Some(1_800_000)),
            ("una hora y cuarto", Some(4_500_000)),
            ("noventa segundos", Some(90_000)),
            ("dos horas y quince minutos", Some(8_100_000)),
            ("dos horas 15 minutos", Some(8_100_000)),
            ("un minuto y medio", Some(90_000)),
            ("una hora", Some(3_600_000)),
            ("un rato", None),
            ("minutos", None),
            ("veinte", None),
            ("an hour", None),
        ] {
            assert_eq!(normalize_duration(span), expected, "{span}");
        }
    }
}
