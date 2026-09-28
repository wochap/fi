//! Duration text shared with the Flutter duration input; see `app_core::duration`.

use flutter_rust_bridge::frb;

/// Parses duration text such as "1h 30m" into signed milliseconds; `None` when it does not parse.
#[frb(sync)]
#[must_use]
pub fn parse_duration_text(text: String) -> Option<i64> {
    app_core::duration::parse_duration(&text).ok()
}

/// Why duration text does not parse, or `None` when it does.
#[frb(sync)]
#[must_use]
pub fn duration_text_error(text: String) -> Option<String> {
    app_core::duration::parse_duration(&text)
        .err()
        .map(|error| error.to_string())
}

/// The canonical short form of a duration, for example "1h 30m".
#[frb(sync)]
#[must_use]
pub fn format_duration_text(milliseconds: i64) -> String {
    app_core::duration::format_duration(milliseconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_functions_share_the_core_grammar() {
        assert_eq!(parse_duration_text("1h 30m".into()), Some(5_400_000));
        assert_eq!(parse_duration_text("an hour".into()), None);
        assert!(duration_text_error("90".into()).is_some());
        assert_eq!(duration_text_error("90m".into()), None);
        assert_eq!(format_duration_text(-45_000), "-45s");
    }
}
