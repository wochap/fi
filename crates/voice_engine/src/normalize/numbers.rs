//! Digits and English number words.
//!
//! A span reads as one or more groups. Words join a group while they can combine ("twenty two",
//! "one hundred and five", "two thousand three hundred"); a word that cannot combine starts a new
//! group ("twelve fifty" is 12 and 50). Two whole groups are a money pair for a scale-2 field.

/// An exact decimal: `mantissa × 10^-exponent`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Exact {
    pub mantissa: i128,
    pub exponent: u32,
}

impl Exact {
    pub(crate) fn whole(value: i128) -> Self {
        Self {
            mantissa: value,
            exponent: 0,
        }
    }

    pub(crate) fn is_whole(self) -> bool {
        self.mantissa % 10i128.pow(self.exponent) == 0
    }

    /// Rounds half-even to `scale` places, as an integer scaled by `10^scale`.
    pub fn scaled(self, scale: u32) -> Option<i128> {
        if self.exponent <= scale {
            return self
                .mantissa
                .checked_mul(10i128.checked_pow(scale - self.exponent)?);
        }
        let divisor = 10i128.checked_pow(self.exponent - scale)?;
        let quotient = self.mantissa.div_euclid(divisor);
        let remainder = self.mantissa.rem_euclid(divisor);
        let twice = remainder * 2;
        let up = twice > divisor || (twice == divisor && quotient % 2 != 0);
        Some(quotient + i128::from(up))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Last {
    Unit,
    Teen,
    Tens,
    Hundred,
    Scale,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Group {
    pub(crate) total: i128,
    pub(crate) small: i128,
    pub(crate) last: Last,
}

fn unit(word: &str) -> Option<i128> {
    Some(match word {
        "zero" => 0,
        "one" => 1,
        "two" => 2,
        "three" => 3,
        "four" => 4,
        "five" => 5,
        "six" => 6,
        "seven" => 7,
        "eight" => 8,
        "nine" => 9,
        _ => return None,
    })
}

fn teen(word: &str) -> Option<i128> {
    Some(match word {
        "ten" => 10,
        "eleven" => 11,
        "twelve" => 12,
        "thirteen" => 13,
        "fourteen" => 14,
        "fifteen" => 15,
        "sixteen" => 16,
        "seventeen" => 17,
        "eighteen" => 18,
        "nineteen" => 19,
        _ => return None,
    })
}

fn tens(word: &str) -> Option<i128> {
    Some(match word {
        "twenty" => 20,
        "thirty" => 30,
        "forty" => 40,
        "fifty" => 50,
        "sixty" => 60,
        "seventy" => 70,
        "eighty" => 80,
        "ninety" => 90,
        _ => return None,
    })
}

fn scale_word(word: &str) -> Option<i128> {
    Some(match word {
        "thousand" => 1_000,
        "million" => 1_000_000,
        _ => return None,
    })
}

/// Currency words end a group ("twelve dollars fifty").
fn is_currency(word: &str) -> bool {
    matches!(
        word,
        "dollar" | "dollars" | "buck" | "bucks" | "euro" | "euros" | "pound" | "pounds" | "usd"
    )
}

/// Lowercase tokens; hyphens and stray punctuation split, thousands commas and currency signs go.
pub(crate) fn tokens(span: &str) -> Vec<String> {
    let chars: Vec<char> = span.chars().collect();
    let mut cleaned = String::new();
    for (index, &c) in chars.iter().enumerate() {
        let digit_before = index > 0 && chars[index - 1].is_ascii_digit();
        let digit_after = chars.get(index + 1).is_some_and(char::is_ascii_digit);
        match c {
            ',' if digit_before && digit_after => {}
            '.' | ':' if digit_after => cleaned.push(c),
            '-' | '−' if digit_after && !digit_before => cleaned.push('-'),
            '$' | '€' | '£' => cleaned.push(' '),
            c if c.is_alphanumeric() => cleaned.extend(c.to_lowercase()),
            '\'' | '’' => {}
            _ => cleaned.push(' '),
        }
    }
    cleaned.split_whitespace().map(str::to_owned).collect()
}

pub(crate) fn digits(token: &str) -> Option<Exact> {
    let (negative, body) = match token.strip_prefix('-') {
        Some(body) => (true, body),
        None => (false, token),
    };
    let (whole, fraction) = body.split_once('.').unwrap_or((body, ""));
    if whole.is_empty() && fraction.is_empty()
        || !whole.chars().all(|c| c.is_ascii_digit())
        || !fraction.chars().all(|c| c.is_ascii_digit())
        || whole.len() + fraction.len() > 30
    {
        return None;
    }
    let mantissa: i128 = format!("0{whole}{fraction}").parse().ok()?;
    Some(Exact {
        mantissa: if negative { -mantissa } else { mantissa },
        exponent: fraction.len() as u32,
    })
}

/// Measure words a spoken amount may end with ("5 kilometers", "412 pages").
fn is_unit(word: &str) -> bool {
    matches!(
        word,
        "km" | "kms"
            | "kilometer"
            | "kilometers"
            | "kilometre"
            | "kilometres"
            | "k"
            | "mile"
            | "miles"
            | "meter"
            | "meters"
            | "metre"
            | "metres"
            | "kg"
            | "kilo"
            | "kilos"
            | "kilograms"
            | "page"
            | "pages"
            | "rep"
            | "reps"
            | "step"
            | "steps"
            | "percent"
            | "degrees"
            | "calories"
            | "kcal"
    )
}

/// The groups a span reads as, or `None` when any word is not part of a number. One trailing
/// measure word is ignored.
pub fn parse_number(span: &str) -> Option<Vec<Exact>> {
    let mut tokens = tokens(span);
    if tokens.len() > 1 && tokens.last().is_some_and(|word| is_unit(word)) {
        tokens.pop();
    }
    let mut groups: Vec<Exact> = Vec::new();
    let mut current: Option<Group> = None;
    let mut negative = false;
    let mut index = 0;
    let close = |current: &mut Option<Group>, groups: &mut Vec<Exact>| {
        if let Some(group) = current.take() {
            groups.push(Exact::whole(group.total + group.small));
        }
    };
    while index < tokens.len() {
        let word = tokens[index].as_str();
        index += 1;
        if groups.is_empty() && current.is_none() && matches!(word, "minus" | "negative") {
            negative = !negative;
            continue;
        }
        if matches!(word, "and" | "cents" | "cent") {
            continue;
        }
        if is_currency(word) {
            close(&mut current, &mut groups);
            continue;
        }
        if let Some(value) = digits(word) {
            close(&mut current, &mut groups);
            groups.push(value);
            continue;
        }
        if word == "point" {
            close(&mut current, &mut groups);
            let base = groups.pop()?;
            if !base.is_whole() || base.exponent != 0 {
                return None;
            }
            let mut fraction = String::new();
            while let Some(next) = tokens.get(index) {
                let digit = match next.as_str() {
                    "oh" | "o" => Some(0),
                    word => unit(word).or_else(|| {
                        (word.len() == 1)
                            .then(|| word.parse::<i128>().ok())
                            .flatten()
                    }),
                };
                let Some(digit) = digit else { break };
                fraction.push_str(&digit.to_string());
                index += 1;
            }
            if fraction.is_empty() {
                return None;
            }
            groups.push(digits(&format!("{}.{fraction}", base.mantissa))?);
            continue;
        }
        let one_before_scale = matches!(word, "a" | "an")
            && tokens
                .get(index)
                .is_some_and(|next| next == "hundred" || scale_word(next).is_some());
        let class = if one_before_scale {
            Some((Last::Unit, 1))
        } else if let Some(value) = unit(word) {
            Some((Last::Unit, value))
        } else if let Some(value) = teen(word) {
            Some((Last::Teen, value))
        } else {
            tens(word).map(|value| (Last::Tens, value))
        };
        if let Some((kind, value)) = class {
            let joins = current.is_some_and(|group| match kind {
                Last::Unit => matches!(group.last, Last::Tens | Last::Hundred | Last::Scale),
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
        if word == "hundred" {
            let group = current.get_or_insert(Group {
                total: 0,
                small: 1,
                last: Last::Unit,
            });
            if group.last == Last::Hundred || group.small >= 100 || group.small == 0 {
                return None;
            }
            group.small *= 100;
            group.last = Last::Hundred;
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

/// A decimal scaled by `10^scale`, rounded half-even. Two whole groups read as a money pair
/// when the scale is 2 ("twelve fifty" → 12.50).
pub fn normalize_decimal(span: &str, scale: u8) -> Option<i64> {
    decimal_from_groups(&parse_number(span)?, scale)
}

/// The decimal rule over parsed groups: one group, or a money pair at scale 2.
pub(crate) fn decimal_from_groups(groups: &[Exact], scale: u8) -> Option<i64> {
    let scale = u32::from(scale);
    let value = match groups {
        [single] => single.scaled(scale)?,
        [whole, cents]
            if scale == 2
                && whole.exponent == 0
                && cents.exponent == 0
                && (0..100).contains(&cents.mantissa) =>
        {
            let sign = if whole.mantissa < 0 { -1 } else { 1 };
            whole.mantissa.checked_mul(100)? + sign * cents.mantissa
        }
        _ => return None,
    };
    i64::try_from(value).ok()
}

/// A whole number; fractions are not rounded.
pub fn normalize_integer(span: &str) -> Option<i64> {
    integer_from_groups(&parse_number(span)?)
}

/// The integer rule over parsed groups: exactly one whole group.
pub(crate) fn integer_from_groups(groups: &[Exact]) -> Option<i64> {
    match groups {
        [single] if single.is_whole() => {
            i64::try_from(single.mantissa / 10i128.pow(single.exponent)).ok()
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decimals() {
        for (span, scale, expected) in [
            ("twelve fifty", 2, Some(1250)),
            ("twenty two forty", 2, Some(2240)),
            ("nineteen ninety nine", 2, Some(1999)),
            ("three", 2, Some(300)),
            ("12.50", 2, Some(1250)),
            ("$12.50", 2, Some(1250)),
            ("1,250", 2, Some(125_000)),
            ("twelve dollars and fifty cents", 2, Some(1250)),
            ("12 dollars", 2, Some(1200)),
            ("three point five", 2, Some(350)),
            ("zero point two five", 1, Some(2)),
            ("0.35", 1, Some(4)),
            ("0.125", 2, Some(12)),
            ("0.135", 2, Some(14)),
            ("minus four", 2, Some(-400)),
            ("-4.5", 1, Some(-45)),
            ("one hundred and five", 0, Some(105)),
            ("a hundred", 2, Some(10_000)),
            ("two thousand three hundred forty five", 0, Some(2345)),
            ("15.5 kilometers", 1, Some(155)),
            ("five km", 1, Some(50)),
            ("kilometers", 1, None),
            ("twelve fifty", 1, None),
            ("a lot", 2, None),
            ("", 2, None),
            ("one two three", 2, None),
        ] {
            assert_eq!(normalize_decimal(span, scale), expected, "{span} @ {scale}");
        }
    }

    #[test]
    fn integers() {
        for (span, expected) in [
            ("three", Some(3)),
            ("42", Some(42)),
            ("forty-two", Some(42)),
            ("twenty one thousand", Some(21_000)),
            ("5.0", Some(5)),
            ("5.5", None),
            ("412 pages", Some(412)),
            ("twelve fifty", None),
            ("many", None),
        ] {
            assert_eq!(normalize_integer(span), expected, "{span}");
        }
    }

    #[test]
    fn half_even_rounding() {
        let exact = |mantissa, exponent| Exact { mantissa, exponent };
        assert_eq!(exact(125, 3).scaled(2), Some(12));
        assert_eq!(exact(135, 3).scaled(2), Some(14));
        assert_eq!(exact(-125, 3).scaled(2), Some(-12));
        assert_eq!(exact(126, 3).scaled(2), Some(13));
    }
}
