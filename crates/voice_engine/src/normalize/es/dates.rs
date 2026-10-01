//! Spanish dates, times and date-times relative to the device's local date.

use chrono::{Datelike, Days, NaiveDate, NaiveTime, Timelike, Weekday};

use super::numbers::{normalize_integer, tokens_es};

fn weekday(word: &str) -> Option<Weekday> {
    Some(match word {
        "lunes" => Weekday::Mon,
        "martes" => Weekday::Tue,
        "miercoles" => Weekday::Wed,
        "jueves" => Weekday::Thu,
        "viernes" => Weekday::Fri,
        "sabado" => Weekday::Sat,
        "domingo" => Weekday::Sun,
        _ => return None,
    })
}

fn month(word: &str) -> Option<u32> {
    Some(match word {
        "enero" => 1,
        "febrero" => 2,
        "marzo" => 3,
        "abril" => 4,
        "mayo" => 5,
        "junio" => 6,
        "julio" => 7,
        "agosto" => 8,
        "septiembre" | "setiembre" => 9,
        "octubre" => 10,
        "noviembre" => 11,
        "diciembre" => 12,
        _ => return None,
    })
}

/// A day of the month: "12", "doce", "primero".
fn day_of_month(words: &[&str]) -> Option<u32> {
    let day = match words {
        [] => return None,
        ["primero"] => 1,
        words => u32::try_from(normalize_integer(&words.join(" "))?).ok()?,
    };
    (1..=31).contains(&day).then_some(day)
}

fn nearest_past(today: NaiveDate, month: u32, day: u32) -> Option<NaiveDate> {
    match NaiveDate::from_ymd_opt(today.year(), month, day) {
        Some(date) if date <= today => Some(date),
        _ => NaiveDate::from_ymd_opt(today.year() - 1, month, day),
    }
}

/// `<day> de <month> [de <year>]`.
fn month_day(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    let index = words.iter().position(|word| month(word).is_some())?;
    let month = month(words[index])?;
    let day_words = match &words[..index] {
        [head @ .., "de"] => head,
        head => head,
    };
    let day = day_of_month(day_words)?;
    let year = match &words[index + 1..] {
        [] => None,
        ["de", year] | [year] if year.len() == 4 => Some(year.parse().ok()?),
        _ => return None,
    };
    match year {
        Some(year) => NaiveDate::from_ymd_opt(year, month, day),
        None => nearest_past(today, month, day),
    }
}

fn days_back(today: NaiveDate, name: &str) -> Option<u32> {
    Some((today.weekday().num_days_from_monday() + 7 - weekday(name)?.num_days_from_monday()) % 7)
}

fn parse_date_words(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    let words: Vec<&str> = words
        .iter()
        .copied()
        .filter(|word| !matches!(*word, "el" | "la" | "del" | "este"))
        .collect();
    match words.as_slice() {
        ["hoy"] => Some(today),
        ["manana" | "mañana"] => today.checked_add_days(Days::new(1)),
        ["pasado", "manana" | "mañana"] => today.checked_add_days(Days::new(2)),
        ["ayer"] => today.checked_sub_days(Days::new(1)),
        ["anteayer" | "antier"] | ["antes", "de", "ayer"] => today.checked_sub_days(Days::new(2)),
        [name] if weekday(name).is_some() => {
            today.checked_sub_days(Days::new(days_back(today, name)?.into()))
        }
        [name, "pasado"] | ["pasado", name] if weekday(name).is_some() => {
            let back = days_back(today, name)?;
            today.checked_sub_days(Days::new(if back == 0 { 7 } else { back.into() }))
        }
        ["proximo", name] | [name, "que", "viene"] if weekday(name).is_some() => {
            let ahead = (weekday(name)?.num_days_from_monday() + 7
                - today.weekday().num_days_from_monday())
                % 7;
            today.checked_add_days(Days::new(if ahead == 0 { 7 } else { ahead.into() }))
        }
        [] => None,
        words => month_day(words, today),
    }
}

/// A Spanish date phrase: relative words, weekdays, day and month, or ISO.
pub fn normalize_date(span: &str, today: NaiveDate) -> Option<NaiveDate> {
    let trimmed = span.trim().trim_end_matches('.');
    if let Ok(date) = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d") {
        return Some(date);
    }
    let tokens = tokens_es(span);
    let words: Vec<&str> = tokens.iter().map(String::as_str).collect();
    parse_date_words(&words, today)
}

fn hour_word(word: &str) -> Option<u32> {
    let value = normalize_integer(word)?;
    u32::try_from(value).ok().filter(|hour| *hour <= 24)
}

/// A time phrase: "a las tres y media", "a las 15:30", "al mediodía", "ocho de la tarde".
fn parse_time_words_es(words: &[&str]) -> Option<NaiveTime> {
    match words {
        ["al" | "a", "mediodia"] | ["mediodia"] => return NaiveTime::from_hms_opt(12, 0, 0),
        ["a", "medianoche"] | ["medianoche"] => return NaiveTime::from_hms_opt(0, 0, 0),
        _ => {}
    }
    let (anchored, mut body) = match words {
        ["a", "las" | "la", rest @ ..] => (true, rest),
        rest => (false, rest),
    };
    let mut meridiem = None;
    for (ending, value) in [
        (&["de", "la", "manana"][..], "am"),
        (&["de", "la", "mañana"][..], "am"),
        (&["de", "la", "madrugada"][..], "am"),
        (&["de", "la", "tarde"][..], "pm"),
        (&["de", "la", "noche"][..], "pm"),
    ] {
        if let Some(head) = body.strip_suffix(ending) {
            body = head;
            meridiem = Some(value);
            break;
        }
    }
    let colon = matches!(body, [single] if single.contains(':'));
    let (hour, minute, quarter_to) = match body {
        [single] if single.contains(':') => {
            let (hour, minute) = single.split_once(':')?;
            if minute.len() != 2 {
                return None;
            }
            (hour.parse().ok()?, minute.parse().ok()?, false)
        }
        [hour] => (hour_word(hour)?, 0, false),
        [hour, "y", "media"] => (hour_word(hour)?, 30, false),
        [hour, "y", "cuarto"] => (hour_word(hour)?, 15, false),
        [hour, "menos", "cuarto"] => (hour_word(hour)?, 45, true),
        [hour, "y", rest @ ..] if !rest.is_empty() => {
            let minute = normalize_integer(&rest.join(" "))?;
            (hour_word(hour)?, u32::try_from(minute).ok()?, false)
        }
        _ => return None,
    };
    if !(anchored || meridiem.is_some() || colon) || minute >= 60 {
        return None;
    }
    let hour = match meridiem {
        Some(_) if !(1..=12).contains(&hour) => return None,
        Some("am") => hour % 12,
        Some(_) if hour == 12 => 12,
        Some(_) => hour + 12,
        None => hour,
    };
    let hour = if quarter_to { (hour + 23) % 24 } else { hour };
    NaiveTime::from_hms_opt(hour, minute, 0)
}

/// A Spanish date phrase plus an optional time, as Unix milliseconds for the local UTC offset.
/// "ahora" is the current minute; a time alone is today; a date alone is midnight.
pub fn normalize_date_time(
    span: &str,
    today: NaiveDate,
    now: NaiveTime,
    utc_offset_minutes: i32,
) -> Option<i64> {
    let tokens = tokens_es(span);
    let words: Vec<&str> = tokens.iter().map(String::as_str).collect();
    let local = if matches!(words.as_slice(), ["ahora"] | ["ahora", "mismo"]) {
        today.and_time(NaiveTime::from_hms_opt(now.hour(), now.minute(), 0)?)
    } else {
        if words.is_empty() {
            return None;
        }
        (0..=words.len()).find_map(|split| {
            let (first, second) = words.split_at(split);
            let date_time = |date: &[&str], time: &[&str]| {
                let date = if date.is_empty() {
                    today
                } else {
                    parse_date_words(date, today)?
                };
                let time = if time.is_empty() {
                    NaiveTime::MIN
                } else {
                    parse_time_words_es(time)?
                };
                Some(date.and_time(time))
            };
            date_time(first, second).or_else(|| date_time(second, first))
        })?
    };
    let utc = local.and_utc().timestamp_millis();
    Some(utc - i64::from(utc_offset_minutes) * 60_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(y: i32, m: u32, d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    #[test]
    fn dates_es_relative_to_monday_2026_09_28() {
        let today = date(2026, 9, 28);
        for (span, expected) in [
            ("hoy", Some(date(2026, 9, 28))),
            ("mañana", Some(date(2026, 9, 29))),
            ("manana", Some(date(2026, 9, 29))),
            ("ayer", Some(date(2026, 9, 27))),
            ("anteayer", Some(date(2026, 9, 26))),
            ("pasado mañana", Some(date(2026, 9, 30))),
            ("lunes", Some(date(2026, 9, 28))),
            ("el martes", Some(date(2026, 9, 22))),
            ("el martes pasado", Some(date(2026, 9, 22))),
            ("el lunes pasado", Some(date(2026, 9, 21))),
            ("el próximo lunes", Some(date(2026, 10, 5))),
            ("el miércoles que viene", Some(date(2026, 9, 30))),
            ("12 de marzo", Some(date(2026, 3, 12))),
            ("doce de marzo", Some(date(2026, 3, 12))),
            ("el 3 de octubre", Some(date(2025, 10, 3))),
            ("primero de marzo de 2027", Some(date(2027, 3, 1))),
            ("2026-09-01", Some(date(2026, 9, 1))),
            ("31 de septiembre", None),
            ("yesterday", None),
            ("algún día", None),
        ] {
            assert_eq!(normalize_date(span, today), expected, "{span}");
        }
    }

    #[test]
    fn date_times_es() {
        let today = date(2026, 9, 28);
        let now = NaiveTime::from_hms_opt(14, 7, 42).unwrap();
        let at = |d: NaiveDate, h, m| d.and_hms_opt(h, m, 0).unwrap().and_utc().timestamp_millis();
        for (span, expected) in [
            ("ahora", Some(at(today, 14, 7))),
            (
                "ayer a las tres de la tarde",
                Some(at(date(2026, 9, 27), 15, 0)),
            ),
            ("hoy a las 15:30", Some(at(today, 15, 30))),
            ("al mediodía", Some(at(today, 12, 0))),
            ("mañana a medianoche", Some(at(date(2026, 9, 29), 0, 0))),
            (
                "el martes pasado a las nueve y cuarto de la mañana",
                Some(at(date(2026, 9, 22), 9, 15)),
            ),
            (
                "a las ocho menos cuarto de la tarde",
                Some(at(today, 19, 45)),
            ),
            ("a las tres y media", Some(at(today, 3, 30))),
            ("a las 8", Some(at(today, 8, 0))),
            ("13 de la tarde", None),
            ("luego", None),
        ] {
            assert_eq!(normalize_date_time(span, today, now, 0), expected, "{span}");
        }
    }
}
