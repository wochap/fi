//! Dates, times and date-times relative to the device's local date.

use chrono::{Datelike, Days, NaiveDate, NaiveTime, Weekday};

use super::numbers::{normalize_integer, tokens};

pub fn epoch_days(date: NaiveDate) -> i64 {
    (date - NaiveDate::from_ymd_opt(1970, 1, 1).expect("valid")).num_days()
}

fn weekday(word: &str) -> Option<Weekday> {
    Some(match word {
        "monday" | "mon" => Weekday::Mon,
        "tuesday" | "tue" | "tues" => Weekday::Tue,
        "wednesday" | "wed" => Weekday::Wed,
        "thursday" | "thu" | "thur" | "thurs" => Weekday::Thu,
        "friday" | "fri" => Weekday::Fri,
        "saturday" | "sat" => Weekday::Sat,
        "sunday" | "sun" => Weekday::Sun,
        _ => return None,
    })
}

fn month(word: &str) -> Option<u32> {
    Some(match word {
        "january" | "jan" => 1,
        "february" | "feb" => 2,
        "march" | "mar" => 3,
        "april" | "apr" => 4,
        "may" => 5,
        "june" | "jun" => 6,
        "july" | "jul" => 7,
        "august" | "aug" => 8,
        "september" | "sep" | "sept" => 9,
        "october" | "oct" => 10,
        "november" | "nov" => 11,
        "december" | "dec" => 12,
        _ => return None,
    })
}

fn ordinal_word(word: &str) -> Option<u32> {
    Some(match word {
        "first" => 1,
        "second" => 2,
        "third" => 3,
        "fourth" => 4,
        "fifth" => 5,
        "sixth" => 6,
        "seventh" => 7,
        "eighth" => 8,
        "ninth" => 9,
        "tenth" => 10,
        "eleventh" => 11,
        "twelfth" => 12,
        "thirteenth" => 13,
        "fourteenth" => 14,
        "fifteenth" => 15,
        "sixteenth" => 16,
        "seventeenth" => 17,
        "eighteenth" => 18,
        "nineteenth" => 19,
        "twentieth" => 20,
        "thirtieth" => 30,
        _ => return None,
    })
}

/// A day of the month: "22", "22nd", "twenty second", "twenty two".
fn day_of_month(words: &[&str]) -> Option<u32> {
    let day = match words {
        [] => return None,
        [word] => {
            let digits = word.trim_end_matches(|c: char| c.is_ascii_alphabetic());
            if !digits.is_empty() && digits.len() < word.len() {
                let suffix = &word[digits.len()..];
                if !matches!(suffix, "st" | "nd" | "rd" | "th") {
                    return None;
                }
            }
            if !digits.is_empty() {
                digits.parse().ok()?
            } else {
                ordinal_word(word).or_else(|| normalize_integer(word)?.try_into().ok())?
            }
        }
        [tens @ ("twenty" | "thirty"), last] => {
            let tens = if *tens == "twenty" { 20 } else { 30 };
            tens + ordinal_word(last)
                .or_else(|| normalize_integer(last)?.try_into().ok())
                .filter(|unit| *unit < 10)?
        }
        _ => return None,
    };
    (1..=31).contains(&day).then_some(day)
}

fn nearest_past(today: NaiveDate, month: u32, day: u32) -> Option<NaiveDate> {
    let this_year = NaiveDate::from_ymd_opt(today.year(), month, day);
    match this_year {
        Some(date) if date <= today => Some(date),
        _ => NaiveDate::from_ymd_opt(today.year() - 1, month, day),
    }
}

fn month_day(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    let index = words.iter().position(|word| month(word).is_some())?;
    let month = month(words[index])?;
    let (mut day_words, year) = if index == 0 {
        let rest = &words[1..];
        match rest.split_last() {
            Some((last, head)) if last.len() == 4 && last.parse::<i32>().is_ok() => {
                (head.to_vec(), last.parse().ok())
            }
            _ => (rest.to_vec(), None),
        }
    } else {
        let year = match &words[index + 1..] {
            [] => None,
            [year] if year.len() == 4 => Some(year.parse().ok()?),
            _ => return None,
        };
        (words[..index].to_vec(), year)
    };
    day_words.retain(|word| *word != "the");
    let day = day_of_month(&day_words)?;
    match year {
        Some(year) => NaiveDate::from_ymd_opt(year, month, day),
        None => nearest_past(today, month, day),
    }
}

fn parse_date_words(words: &[&str], today: NaiveDate) -> Option<NaiveDate> {
    let words: Vec<&str> = words
        .iter()
        .copied()
        .filter(|word| !matches!(*word, "on" | "of" | "this"))
        .collect();
    match words.as_slice() {
        ["today" | "tonight"] => Some(today),
        ["tomorrow"] => today.checked_add_days(Days::new(1)),
        ["yesterday"] => today.checked_sub_days(Days::new(1)),
        ["the", "day", "before", "yesterday"] | ["day", "before", "yesterday"] => {
            today.checked_sub_days(Days::new(2))
        }
        [name] if weekday(name).is_some() => {
            let back = (today.weekday().num_days_from_monday() + 7
                - weekday(name)?.num_days_from_monday())
                % 7;
            today.checked_sub_days(Days::new(back.into()))
        }
        ["last", name] => {
            let back = (today.weekday().num_days_from_monday() + 7
                - weekday(name)?.num_days_from_monday())
                % 7;
            today.checked_sub_days(Days::new(if back == 0 { 7 } else { back.into() }))
        }
        ["next", name] => {
            let ahead = (weekday(name)?.num_days_from_monday() + 7
                - today.weekday().num_days_from_monday())
                % 7;
            today.checked_add_days(Days::new(if ahead == 0 { 7 } else { ahead.into() }))
        }
        [] => None,
        words => month_day(words, today),
    }
}

/// A date phrase: relative words, weekdays, month and day, or ISO.
pub fn normalize_date(span: &str, today: NaiveDate) -> Option<NaiveDate> {
    let trimmed = span.trim().trim_end_matches('.');
    if let Ok(date) = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d") {
        return Some(date);
    }
    let tokens = tokens(span);
    let words: Vec<&str> = tokens.iter().map(String::as_str).collect();
    parse_date_words(&words, today)
}

fn hour_word(word: &str) -> Option<u32> {
    let value = normalize_integer(word)?;
    u32::try_from(value).ok().filter(|hour| *hour <= 24)
}

/// A time phrase: "3pm", "3:30 pm", "15:30", "at noon", "three thirty pm", "at 8".
fn parse_time_words(words: &[&str]) -> Option<NaiveTime> {
    let mut words: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    let anchored = words.first().is_some_and(|word| word == "at");
    if anchored {
        words.remove(0);
    }
    match words
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>()
        .as_slice()
    {
        ["noon" | "midday"] => return NaiveTime::from_hms_opt(12, 0, 0),
        ["midnight"] => return NaiveTime::from_hms_opt(0, 0, 0),
        _ => {}
    }
    // Split a glued meridiem ("3pm", "3:30am") into its own word.
    if let Some(last) = words.last().cloned() {
        for suffix in ["am", "pm"] {
            if let Some(head) = last.strip_suffix(suffix)
                && head.chars().next().is_some_and(|c| c.is_ascii_digit())
            {
                words.pop();
                words.push(head.to_owned());
                words.push(suffix.to_owned());
                break;
            }
        }
    }
    let mut meridiem = None;
    let tail: Vec<&str> = words.iter().map(String::as_str).collect();
    let mut body: &[&str] = &tail;
    for (ending, value) in [
        (&["am"][..], "am"),
        (&["pm"][..], "pm"),
        (&["a", "m"][..], "am"),
        (&["p", "m"][..], "pm"),
        (&["in", "the", "morning"][..], "am"),
        (&["in", "the", "afternoon"][..], "pm"),
        (&["in", "the", "evening"][..], "pm"),
        (&["at", "night"][..], "pm"),
    ] {
        if let Some(head) = body.strip_suffix(ending) {
            body = head;
            meridiem = Some(value);
            break;
        }
    }
    let oclock = body.last() == Some(&"oclock");
    if oclock {
        body = &body[..body.len() - 1];
    }
    let (hour, minute) = match body {
        [single] if single.contains(':') => {
            let (hour, minute) = single.split_once(':')?;
            if minute.len() != 2 {
                return None;
            }
            (hour.parse().ok()?, minute.parse().ok()?)
        }
        [hour] => (hour_word(hour)?, 0),
        [hour, "oh" | "o", minute] => (hour_word(hour)?, hour_word(minute).filter(|m| *m < 10)?),
        [hour, rest @ ..] => {
            let minute = normalize_integer(&rest.join(" "))?;
            (hour_word(hour)?, u32::try_from(minute).ok()?)
        }
        [] => return None,
    };
    if !(anchored || oclock || meridiem.is_some() || body.len() == 1 && body[0].contains(':')) {
        return None;
    }
    let hour = match meridiem {
        Some(_) if !(1..=12).contains(&hour) => return None,
        Some("am") => hour % 12,
        Some(_) => hour % 12 + 12,
        None => hour,
    };
    NaiveTime::from_hms_opt(hour, minute, 0)
}

/// A date phrase plus an optional time, as Unix milliseconds for the local UTC offset.
/// "now" is the current minute; a time alone is today; a date alone is midnight.
pub fn normalize_date_time(
    span: &str,
    today: NaiveDate,
    now: NaiveTime,
    utc_offset_minutes: i32,
) -> Option<i64> {
    let tokens = tokens(span);
    let words: Vec<&str> = tokens.iter().map(String::as_str).collect();
    let local = if matches!(words.as_slice(), ["now"] | ["right", "now"]) {
        today.and_time(NaiveTime::from_hms_opt(
            chrono::Timelike::hour(&now),
            chrono::Timelike::minute(&now),
            0,
        )?)
    } else {
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
                    parse_time_words(time)?
                };
                Some(date.and_time(time))
            };
            if words.is_empty() {
                return None;
            }
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
    fn dates_relative_to_monday_2026_09_28() {
        let today = date(2026, 9, 28);
        for (span, expected) in [
            ("today", Some(date(2026, 9, 28))),
            ("Tomorrow", Some(date(2026, 9, 29))),
            ("yesterday", Some(date(2026, 9, 27))),
            ("yesterday.", Some(date(2026, 9, 27))),
            ("the day before yesterday", Some(date(2026, 9, 26))),
            ("Monday", Some(date(2026, 9, 28))),
            ("on Tuesday", Some(date(2026, 9, 22))),
            ("Sunday", Some(date(2026, 9, 27))),
            ("last Tuesday", Some(date(2026, 9, 22))),
            ("last Monday", Some(date(2026, 9, 21))),
            ("next Monday", Some(date(2026, 10, 5))),
            ("next Wednesday", Some(date(2026, 9, 30))),
            ("September 22", Some(date(2026, 9, 22))),
            ("Sep 22nd", Some(date(2026, 9, 22))),
            ("22 September", Some(date(2026, 9, 22))),
            ("the 22nd of September", Some(date(2026, 9, 22))),
            ("September twenty second", Some(date(2026, 9, 22))),
            ("October 3", Some(date(2025, 10, 3))),
            ("September 28", Some(date(2026, 9, 28))),
            ("March 3, 2027", Some(date(2027, 3, 3))),
            ("3 March 2024", Some(date(2024, 3, 3))),
            ("2026-09-01", Some(date(2026, 9, 1))),
            ("September 31", None),
            ("someday", None),
            ("", None),
        ] {
            assert_eq!(normalize_date(span, today), expected, "{span}");
        }
    }

    #[test]
    fn epoch_days_counts_from_1970() {
        assert_eq!(epoch_days(date(1970, 1, 2)), 1);
        assert_eq!(epoch_days(date(1969, 12, 31)), -1);
    }

    #[test]
    fn date_times() {
        let today = date(2026, 9, 28);
        let now = NaiveTime::from_hms_opt(14, 7, 42).unwrap();
        let at = |d: NaiveDate, h, m| d.and_hms_opt(h, m, 0).unwrap().and_utc().timestamp_millis();
        for (span, expected) in [
            ("now", Some(at(today, 14, 7))),
            ("yesterday at 3pm", Some(at(date(2026, 9, 27), 15, 0))),
            ("3pm yesterday", Some(at(date(2026, 9, 27), 15, 0))),
            ("today 15:30", Some(at(today, 15, 30))),
            ("at noon", Some(at(today, 12, 0))),
            ("tomorrow at midnight", Some(at(date(2026, 9, 29), 0, 0))),
            (
                "last Tuesday at 9:15 a.m.",
                Some(at(date(2026, 9, 22), 9, 15)),
            ),
            ("at three thirty pm", Some(at(today, 15, 30))),
            ("at 8", Some(at(today, 8, 0))),
            ("seven in the evening", Some(at(today, 19, 0))),
            ("September 22", Some(at(date(2026, 9, 22), 0, 0))),
            ("13pm", None),
            ("later", None),
        ] {
            assert_eq!(normalize_date_time(span, today, now, 0), expected, "{span}");
        }
        assert_eq!(
            normalize_date_time("today at noon", today, now, 120),
            Some(at(today, 10, 0))
        );
    }
}
