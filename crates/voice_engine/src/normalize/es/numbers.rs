//! Digits and Spanish number words.
//!
//! The group machine matches the English one: words join a group while they can combine
//! ("treinta y dos", "dos mil trescientos"), and a word that cannot combine starts a new group
//! ("doce cincuenta" is 12 and 50). "con" and currency words close a group, so
//! "doce con cincuenta" and "doce euros cincuenta" are money pairs too.

use super::fold;
use crate::normalize::numbers::{
    Exact, Group, Last, decimal_from_groups, digits, integer_from_groups,
};

fn unit(word: &str) -> Option<i128> {
    Some(match word {
        "cero" => 0,
        "un" | "uno" | "una" => 1,
        "dos" => 2,
        "tres" => 3,
        "cuatro" => 4,
        "cinco" => 5,
        "seis" => 6,
        "siete" => 7,
        "ocho" => 8,
        "nueve" => 9,
        _ => return None,
    })
}

/// One-word forms from 10 to 29 except 20.
fn teen(word: &str) -> Option<i128> {
    Some(match word {
        "diez" => 10,
        "once" => 11,
        "doce" => 12,
        "trece" => 13,
        "catorce" => 14,
        "quince" => 15,
        "dieciseis" => 16,
        "diecisiete" => 17,
        "dieciocho" => 18,
        "diecinueve" => 19,
        "veintiun" | "veintiuno" | "veintiuna" => 21,
        "veintidos" => 22,
        "veintitres" => 23,
        "veinticuatro" => 24,
        "veinticinco" => 25,
        "veintiseis" => 26,
        "veintisiete" => 27,
        "veintiocho" => 28,
        "veintinueve" => 29,
        _ => return None,
    })
}

fn tens(word: &str) -> Option<i128> {
    Some(match word {
        "veinte" => 20,
        "treinta" => 30,
        "cuarenta" => 40,
        "cincuenta" => 50,
        "sesenta" => 60,
        "setenta" => 70,
        "ochenta" => 80,
        "noventa" => 90,
        _ => return None,
    })
}

fn hundreds(word: &str) -> Option<i128> {
    Some(match word {
        "cien" | "ciento" => 100,
        "doscientos" | "doscientas" => 200,
        "trescientos" | "trescientas" => 300,
        "cuatrocientos" | "cuatrocientas" => 400,
        "quinientos" | "quinientas" => 500,
        "seiscientos" | "seiscientas" => 600,
        "setecientos" | "setecientas" => 700,
        "ochocientos" | "ochocientas" => 800,
        "novecientos" | "novecientas" => 900,
        _ => return None,
    })
}

fn scale_word(word: &str) -> Option<i128> {
    Some(match word {
        "mil" => 1_000,
        "millon" | "millones" => 1_000_000,
        _ => return None,
    })
}

/// Currency words end a group ("doce euros cincuenta").
fn is_currency(word: &str) -> bool {
    matches!(
        word,
        "euro" | "euros" | "peso" | "pesos" | "dolar" | "dolares" | "libra" | "libras"
    )
}

/// Measure words a spoken amount may end with ("quince kilómetros", "412 páginas").
fn is_unit(word: &str) -> bool {
    matches!(
        word,
        "km" | "kilometro"
            | "kilometros"
            | "metro"
            | "metros"
            | "kg"
            | "kilo"
            | "kilos"
            | "pagina"
            | "paginas"
            | "paso"
            | "pasos"
            | "repeticion"
            | "repeticiones"
            | "grado"
            | "grados"
            | "caloria"
            | "calorias"
            | "kcal"
    )
}

/// Folded tokens. A comma between digits is the decimal point, and a period between digits
/// followed by exactly three digits is a thousands separator.
pub(crate) fn tokens_es(span: &str) -> Vec<String> {
    let chars: Vec<char> = fold(span).chars().collect();
    let mut cleaned = String::new();
    for (index, &c) in chars.iter().enumerate() {
        let digit_before = index > 0 && chars[index - 1].is_ascii_digit();
        let digit_after = chars.get(index + 1).is_some_and(char::is_ascii_digit);
        match c {
            ',' if digit_before && digit_after => cleaned.push('.'),
            '.' if digit_before && thousands_follow(&chars[index + 1..]) => {}
            '.' | ':' if digit_after => cleaned.push(c),
            '-' | '−' if digit_after && !digit_before => cleaned.push('-'),
            '¿' | '¡' | '$' | '€' | '£' => cleaned.push(' '),
            c if c.is_alphanumeric() => cleaned.push(c),
            '\'' | '’' => {}
            _ => cleaned.push(' '),
        }
    }
    cleaned.split_whitespace().map(str::to_owned).collect()
}

/// Exactly three digits, then a non-digit or the end.
fn thousands_follow(rest: &[char]) -> bool {
    rest.len() >= 3
        && rest[..3].iter().all(char::is_ascii_digit)
        && rest.get(3).is_none_or(|c| !c.is_ascii_digit())
}

/// Classifies a word that may join or start a group.
fn class(word: &str) -> Option<(Last, i128)> {
    if let Some(value) = unit(word) {
        Some((Last::Unit, value))
    } else if let Some(value) = teen(word) {
        Some((Last::Teen, value))
    } else if let Some(value) = tens(word) {
        Some((Last::Tens, value))
    } else {
        hundreds(word).map(|value| (Last::Hundred, value))
    }
}

fn close(current: &mut Option<Group>, groups: &mut Vec<Exact>) {
    if let Some(group) = current.take() {
        groups.push(Exact::whole(group.total + group.small));
    }
}

/// The groups a span reads as, or `None` when any word is not part of a number. One trailing
/// measure word is ignored.
pub fn parse_number_es(span: &str) -> Option<Vec<Exact>> {
    let mut tokens = tokens_es(span);
    if tokens.len() > 2 && tokens[tokens.len() - 2..] == ["por", "ciento"] {
        tokens.truncate(tokens.len() - 2);
    } else if tokens.len() > 1 && tokens.last().is_some_and(|word| is_unit(word)) {
        tokens.pop();
    }
    let mut groups: Vec<Exact> = Vec::new();
    let mut current: Option<Group> = None;
    let mut negative = false;
    let mut index = 0;
    while index < tokens.len() {
        let word = tokens[index].as_str();
        index += 1;
        if groups.is_empty() && current.is_none() && word == "menos" {
            negative = !negative;
            continue;
        }
        if matches!(word, "y" | "centimo" | "centimos" | "centavo" | "centavos") {
            continue;
        }
        if word == "con" || is_currency(word) {
            close(&mut current, &mut groups);
            continue;
        }
        if let Some(value) = digits(word) {
            close(&mut current, &mut groups);
            groups.push(value);
            continue;
        }
        if matches!(word, "coma" | "punto") {
            close(&mut current, &mut groups);
            let base = groups.pop()?;
            if base.exponent != 0 {
                return None;
            }
            let mut fraction = String::new();
            while tokens.get(index).is_some_and(|next| next == "cero") {
                fraction.push('0');
                index += 1;
            }
            if let Some(next) = tokens.get(index)
                && next.chars().all(|c| c.is_ascii_digit())
            {
                fraction.push_str(next);
                index += 1;
            } else {
                let start = index;
                while tokens
                    .get(index)
                    .is_some_and(|next| next == "y" || class(next).is_some())
                {
                    index += 1;
                }
                if index > start {
                    match parse_words(&tokens[start..index])?.as_slice() {
                        [single] if single.exponent == 0 && single.mantissa >= 0 => {
                            fraction.push_str(&single.mantissa.to_string());
                        }
                        _ => return None,
                    }
                }
            }
            if fraction.is_empty() {
                return None;
            }
            groups.push(digits(&format!("{}.{fraction}", base.mantissa))?);
            continue;
        }
        if let Some((kind, value)) = class(word) {
            let joins = current.is_some_and(|group| match kind {
                Last::Unit => matches!(group.last, Last::Tens | Last::Hundred | Last::Scale),
                Last::Hundred => group.last == Last::Scale,
                _ => matches!(group.last, Last::Hundred | Last::Scale),
            });
            if !joins {
                close(&mut current, &mut groups);
                current = Some(Group {
                    total: 0,
                    small: 0,
                    last: kind,
                });
            }
            let group = current.as_mut()?;
            group.small += value;
            group.last = kind;
            continue;
        }
        if let Some(scale) = scale_word(word) {
            let group = current.get_or_insert(Group {
                total: 0,
                small: 1,
                last: Last::Unit,
            });
            if group.last == Last::Scale || group.small == 0 {
                return None;
            }
            group.total += group.small * scale;
            group.small = 0;
            group.last = Last::Scale;
            continue;
        }
        return None;
    }
    close(&mut current, &mut groups);
    let first = groups.first_mut()?;
    if negative {
        first.mantissa = -first.mantissa;
    }
    Some(groups)
}

/// Number words only (the fraction after "coma"), as groups.
fn parse_words(words: &[String]) -> Option<Vec<Exact>> {
    parse_number_es(&words.join(" "))
}

/// A decimal scaled by `10^scale`, rounded half-even. Two whole groups read as a money pair
/// when the scale is 2 ("doce con cincuenta" → 12.50).
pub fn normalize_decimal(span: &str, scale: u8) -> Option<i64> {
    decimal_from_groups(&parse_number_es(span)?, scale)
}

/// A whole number; fractions are not rounded.
pub fn normalize_integer(span: &str) -> Option<i64> {
    integer_from_groups(&parse_number_es(span)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimals_es() {
        for (span, scale, expected) in [
            ("doce con cincuenta", 2, Some(1250)),
            ("doce cincuenta", 2, Some(1250)),
            ("doce euros con cincuenta", 2, Some(1250)),
            ("doce euros cincuenta", 2, Some(1250)),
            ("veintidós cuarenta", 2, Some(2240)),
            ("12,50", 2, Some(1250)),
            ("12.50", 2, Some(1250)),
            ("1.200", 0, Some(1200)),
            ("1.200,50", 2, Some(120_050)),
            ("€12,50", 2, Some(1250)),
            ("doce coma cinco", 2, Some(1250)),
            ("doce coma cincuenta", 2, Some(1250)),
            ("tres coma cero cinco", 2, Some(305)),
            ("tres", 2, Some(300)),
            ("menos cuatro", 2, Some(-400)),
            ("quince kilómetros", 1, Some(150)),
            ("mucho", 2, None),
            ("twelve fifty", 2, None),
            ("", 2, None),
        ] {
            assert_eq!(normalize_decimal(span, scale), expected, "{span} @ {scale}");
        }
    }

    #[test]
    fn integers_es() {
        for (span, expected) in [
            ("mil doscientos", Some(1200)),
            ("dos mil trescientos cuarenta", Some(2340)),
            ("treinta y dos", Some(32)),
            ("ciento cinco", Some(105)),
            ("cien", Some(100)),
            ("quinientas", Some(500)),
            ("un millón", Some(1_000_000)),
            ("veintiuno", Some(21)),
            ("dieciséis", Some(16)),
            ("dieciseis", Some(16)),
            ("412 páginas", Some(412)),
            ("doce con cincuenta", None),
            ("5,5", None),
        ] {
            assert_eq!(normalize_integer(span), expected, "{span}");
        }
    }

    #[test]
    fn tokens_handle_spanish_punctuation() {
        assert_eq!(tokens_es("¿Doce, 1.200,50?"), ["doce", "1200.50"]);
        assert_eq!(tokens_es("12.5"), ["12.5"]);
    }
}
