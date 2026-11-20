//! Coordinate formatting and parsing for `Location` fields.
//!
//! Shared between CSV import, Rust validation, and the Flutter `Type coordinates` sheet via
//! `app_bridge`.

use thiserror::Error;

use crate::values::{
    LocationValue, MAX_LATITUDE_MICRODEG, MAX_LONGITUDE_MICRODEG, MIN_LATITUDE_MICRODEG,
    MIN_LONGITUDE_MICRODEG,
};

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum LocationParseError {
    #[error("Not a coordinate. Try 38.7139, -9.1334")]
    InvalidSyntax,
    #[error("Latitude goes from -90 to 90")]
    LatitudeOutOfRange,
    #[error("Longitude goes from -180 to 180")]
    LongitudeOutOfRange,
    #[error("Resolving a short map link requires internet")]
    ShortLinkNeedsResolution(String),
}

/// Formats a single microdegree coordinate with `decimals` fractional digits (typically 4 or 6),
/// rounding half away from zero when `decimals < 6`.
#[must_use]
pub fn format_microdeg(microdeg: i64, decimals: u8) -> String {
    let decimals = decimals.min(6);
    let divisor = 10_i64.pow(u32::from(6 - decimals));
    let rounded_units = if divisor == 1 {
        microdeg
    } else {
        let half = divisor / 2;
        if microdeg >= 0 {
            (microdeg + half) / divisor
        } else {
            (microdeg - half) / divisor
        }
    };
    let negative = rounded_units < 0;
    let abs_units = rounded_units.unsigned_abs();
    if decimals == 0 {
        return format!("{}{}", if negative { "-" } else { "" }, abs_units);
    }
    let scale = 10_u64.pow(u32::from(decimals));
    let whole = abs_units / scale;
    let frac = abs_units % scale;
    format!(
        "{}{whole}.{frac:0width$}",
        if negative { "-" } else { "" },
        width = usize::from(decimals)
    )
}

/// Formats a `LocationValue` to 6 decimal places: `"38.710841, -9.137265"`.
#[must_use]
pub fn format_location_6dp(location: LocationValue) -> String {
    format!(
        "{}, {}",
        format_microdeg(location.latitude_microdeg, 6),
        format_microdeg(location.longitude_microdeg, 6),
    )
}

/// Formats a `LocationValue` to 4 decimal places: `"38.7108, -9.1373"`.
#[must_use]
pub fn format_location_4dp(location: LocationValue) -> String {
    format!(
        "{}, {}",
        format_microdeg(location.latitude_microdeg, 4),
        format_microdeg(location.longitude_microdeg, 4),
    )
}

/// Formats a `LocationValue` using 4 decimals if marked approximate, otherwise 6 decimals.
#[must_use]
pub fn format_location_canonical(location: LocationValue) -> String {
    if location.approximate {
        format_location_4dp(location)
    } else {
        format_location_6dp(location)
    }
}

/// Parses a user-supplied coordinate string or map link into a validated [`LocationValue`].
pub fn parse_location_input(input: &str) -> Result<LocationValue, LocationParseError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(LocationParseError::InvalidSyntax);
    }

    // 1. Short Google Maps links that require online redirect resolution.
    if let Some(url) = detect_short_google_maps_link(trimmed) {
        return Err(LocationParseError::ShortLinkNeedsResolution(url));
    }

    // 2. `geo:` URIs (RFC 5870 + Android `?q=lat,lng`).
    if trimmed.len() >= 4 && trimmed[..4].eq_ignore_ascii_case("geo:") {
        return parse_geo_uri(&trimmed[4..]);
    }

    // 3. Full map URLs (Google Maps, Waze, OpenStreetMap).
    if looks_like_url(trimmed) {
        return parse_map_url(trimmed);
    }

    // 4. DMS pairs (`38°42'50"N 9°08'00"W`).
    if trimmed.contains('°') || trimmed.contains('\'') || trimmed.contains('′') {
        if let Some(result) = try_parse_dms_pair(trimmed) {
            return result;
        }
    }

    // 5. Plain decimal pairs (`38.7139, -9.1334` or `38.7139 -9.1334`).
    parse_decimal_pair(trimmed)
}

fn detect_short_google_maps_link(input: &str) -> Option<String> {
    let token = input.split_whitespace().find(|part| {
        let lower = part.to_ascii_lowercase();
        lower.starts_with("https://maps.app.goo.gl/")
            || lower.starts_with("http://maps.app.goo.gl/")
            || lower.starts_with("maps.app.goo.gl/")
            || lower.starts_with("https://goo.gl/maps/")
            || lower.starts_with("http://goo.gl/maps/")
            || lower.starts_with("goo.gl/maps/")
    })?;
    let cleaned = token.trim_end_matches(|c: char| matches!(c, ')' | ']' | '.' | ',' | ';'));
    let lower = cleaned.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        Some(cleaned.to_owned())
    } else {
        Some(format!("https://{cleaned}"))
    }
}

fn looks_like_url(input: &str) -> bool {
    let lower = input.to_ascii_lowercase();
    lower.contains("://")
        || lower.starts_with("maps.google.")
        || lower.starts_with("www.google.")
        || lower.starts_with("google.")
        || lower.starts_with("waze.com")
        || lower.starts_with("www.waze.com")
        || lower.starts_with("ul.waze.com")
        || lower.starts_with("openstreetmap.org")
        || lower.starts_with("www.openstreetmap.org")
        || lower.starts_with("osm.org")
}

fn parse_geo_uri(rest: &str) -> Result<LocationValue, LocationParseError> {
    let (coords_and_params, query) = match rest.split_once('?') {
        Some((before, q)) => (before, Some(q)),
        None => (rest, None),
    };
    let coords_part = coords_and_params
        .split_once(';')
        .map_or(coords_and_params, |(c, _)| c);

    let base_parsed = parse_geo_coords_prefix(coords_part);
    if let Some(q) = query {
        if let Some(q_val) = query_param(q, "q") {
            // Strip optional `(Label)` suffix in Android geo URIs: `38.7139,-9.1334(My Place)`.
            let stripped = q_val.split_once('(').map_or(q_val.as_str(), |(c, _)| c);
            if let Ok(q_loc) = parse_decimal_pair(stripped.trim()) {
                // Prefer `?q=lat,lng` when base is `0,0` or missing.
                match base_parsed {
                    Ok(base) if base.latitude_microdeg == 0 && base.longitude_microdeg == 0 => {
                        return Ok(q_loc);
                    }
                    Err(_) => return Ok(q_loc),
                    Ok(base) => return Ok(base),
                }
            }
        }
    }
    base_parsed
}

fn parse_geo_coords_prefix(coords: &str) -> Result<LocationValue, LocationParseError> {
    let mut parts = coords.split(',');
    let lat = parts.next().ok_or(LocationParseError::InvalidSyntax)?;
    let lng = parts.next().ok_or(LocationParseError::InvalidSyntax)?;
    // Optional 3rd altitude component is ignored per RFC 5870.
    if parts.nth(1).is_some() {
        return Err(LocationParseError::InvalidSyntax);
    }
    from_decimal_strings(lat.trim(), lng.trim())
}

fn parse_map_url(input: &str) -> Result<LocationValue, LocationParseError> {
    // 1. Google Maps exact pin coordinates: `!3d<lat>!4d<lng>` (take last occurrence).
    if let Some(result) = parse_google_3d_4d(input) {
        return result;
    }

    // 2. Query parameters (`mlat`/`mlon` marker preferred over viewport `#map=`, plus `q`, `query`, `ll`, etc.).
    if let Some((_, after_q)) = input.split_once('?') {
        let query = after_q.split_once('#').map_or(after_q, |(q, _)| q);
        if let (Some(mlat), Some(mlon)) = (query_param(query, "mlat"), query_param(query, "mlon")) {
            return from_decimal_strings(&mlat, &mlon);
        }
        for key in ["q", "query", "ll", "center", "destination", "daddr"] {
            if let Some(val) = query_param(query, key) {
                let candidate = val.trim().trim_start_matches("loc:");
                match parse_decimal_pair(candidate) {
                    Ok(loc) => return Ok(loc),
                    Err(
                        err @ (LocationParseError::LatitudeOutOfRange
                        | LocationParseError::LongitudeOutOfRange),
                    ) => return Err(err),
                    Err(_) => {}
                }
            }
        }
    }

    // 3. OpenStreetMap hash fragment: `#map=<zoom>/<lat>/<lng>`.
    if let Some((_, fragment)) = input.split_once('#') {
        if let Some(result) = parse_osm_hash(fragment) {
            return result;
        }
    }

    // 4. Google Maps path patterns: `/search/<lat>,<lng>` or `/place/<lat>,<lng>`.
    for marker in ["/search/", "/place/"] {
        if let Some(idx) = input.find(marker) {
            let after = &input[idx + marker.len()..];
            let segment = after
                .split(['/', '?', '#'])
                .next()
                .unwrap_or_default();
            let decoded = percent_decode(segment);
            if let Ok(loc) = parse_decimal_pair(decoded.trim()) {
                return Ok(loc);
            }
        }
    }

    // 5. Google Maps viewport center: `@<lat>,<lng>,<zoom>z`.
    if let Some(idx) = input.find('@') {
        let after = &input[idx + 1..];
        let mut parts = after.split(',');
        if let (Some(lat), Some(lng_rest)) = (parts.next(), parts.next()) {
            let lng = lng_rest
                .split(['/', '?', '#', ','])
                .next()
                .unwrap_or(lng_rest);
            return from_decimal_strings(lat.trim(), lng.trim());
        }
    }

    Err(LocationParseError::InvalidSyntax)
}

fn parse_google_3d_4d(input: &str) -> Option<Result<LocationValue, LocationParseError>> {
    let mut best: Option<(String, String)> = None;
    let mut search = input;
    while let Some(idx) = search.find("!3d") {
        let after_3d = &search[idx + 3..];
        let lat_end = after_3d.find(['!', '?', '#', '&', '/']).unwrap_or(after_3d.len());
        let lat_str = &after_3d[..lat_end];
        let rest = &after_3d[lat_end..];
        if let Some(after_4d) = rest.strip_prefix("!4d") {
            let lng_end = after_4d
                .find(['!', '?', '#', '&', '/'])
                .unwrap_or(after_4d.len());
            let lng_str = &after_4d[..lng_end];
            if !lat_str.is_empty() && !lng_str.is_empty() {
                best = Some((lat_str.to_owned(), lng_str.to_owned()));
            }
        }
        search = &search[idx + 3..];
    }
    best.map(|(lat, lng)| from_decimal_strings(&lat, &lng))
}

fn parse_osm_hash(fragment: &str) -> Option<Result<LocationValue, LocationParseError>> {
    let map_part = fragment
        .split('&')
        .find_map(|kv| kv.strip_prefix("map="))?;
    let mut parts = map_part.split('/');
    let _zoom = parts.next()?;
    let lat = parts.next()?;
    let lng = parts.next()?;
    Some(from_decimal_strings(lat.trim(), lng.trim()))
}

fn query_param(query: &str, name: &str) -> Option<String> {
    for pair in query.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k.eq_ignore_ascii_case(name) {
                return Some(percent_decode(v));
            }
        }
    }
    None
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                if let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                    out.push((hi << 4) | lo);
                    i += 3;
                } else {
                    out.push(b'%');
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

const fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn parse_decimal_pair(input: &str) -> Result<LocationValue, LocationParseError> {
    let trimmed = input.trim();
    let (lat_raw, lng_raw) = if let Some((a, b)) = trimmed.split_once(',') {
        if b.contains(',') {
            return Err(LocationParseError::InvalidSyntax);
        }
        (a.trim(), b.trim())
    } else {
        let mut parts = trimmed.split_whitespace();
        let a = parts.next().ok_or(LocationParseError::InvalidSyntax)?;
        let b = parts.next().ok_or(LocationParseError::InvalidSyntax)?;
        if parts.next().is_some() {
            return Err(LocationParseError::InvalidSyntax);
        }
        (a, b)
    };
    from_decimal_strings(lat_raw, lng_raw)
}

fn from_decimal_strings(lat_str: &str, lng_str: &str) -> Result<LocationValue, LocationParseError> {
    let lat = parse_decimal_to_microdeg(lat_str)?;
    let lng = parse_decimal_to_microdeg(lng_str)?;
    validate_microdeg_pair(lat, lng)
}

fn validate_microdeg_pair(lat: i64, lng: i64) -> Result<LocationValue, LocationParseError> {
    if !(MIN_LATITUDE_MICRODEG..=MAX_LATITUDE_MICRODEG).contains(&lat) {
        return Err(LocationParseError::LatitudeOutOfRange);
    }
    if !(MIN_LONGITUDE_MICRODEG..=MAX_LONGITUDE_MICRODEG).contains(&lng) {
        return Err(LocationParseError::LongitudeOutOfRange);
    }
    Ok(LocationValue::new(lat, lng, None, false))
}

/// Parses a signed decimal degree string into microdegrees, rounding half away from zero at the
/// 7th fractional digit. Rejects NaN, infinities, and non-numeric strings.
pub fn parse_decimal_to_microdeg(raw: &str) -> Result<i64, LocationParseError> {
    let s = raw.trim();
    if s.is_empty() {
        return Err(LocationParseError::InvalidSyntax);
    }
    let (negative, unsigned) = match s.as_bytes()[0] {
        b'-' => (true, &s[1..]),
        b'+' => (false, &s[1..]),
        _ => (false, s),
    };
    if unsigned.is_empty() {
        return Err(LocationParseError::InvalidSyntax);
    }
    let mut parts = unsigned.split('.');
    let whole_str = parts.next().unwrap_or_default();
    let frac_str = parts.next();
    if parts.next().is_some() {
        return Err(LocationParseError::InvalidSyntax);
    }
    if whole_str.is_empty() && frac_str.is_none_or(str::is_empty) {
        return Err(LocationParseError::InvalidSyntax);
    }
    if !whole_str.bytes().all(|b| b.is_ascii_digit())
        || frac_str.is_some_and(|f| !f.bytes().all(|b| b.is_ascii_digit()))
    {
        return Err(LocationParseError::InvalidSyntax);
    }
    let whole: i128 = if whole_str.is_empty() {
        0
    } else {
        whole_str
            .parse()
            .map_err(|_| LocationParseError::InvalidSyntax)?
    };
    if whole > 1_000_000 {
        // Clearly out of range; let caller classify lat vs lng.
        let clamped = if negative { -1_000_000_000_000 } else { 1_000_000_000_000 };
        return Ok(clamped);
    }
    let mut frac_micro: i128 = 0;
    if let Some(frac) = frac_str {
        let bytes = frac.as_bytes();
        let take = bytes.len().min(6);
        let mut mul = 100_000_i128;
        for &b in &bytes[..take] {
            frac_micro += i128::from(b - b'0') * mul;
            mul /= 10;
        }
        if bytes.len() > 6 && bytes[6] >= b'5' {
            frac_micro += 1;
        }
    }
    let total = whole * 1_000_000 + frac_micro;
    let signed = if negative { -total } else { total };
    i64::try_from(signed).map_err(|_| LocationParseError::InvalidSyntax)
}

fn try_parse_dms_pair(input: &str) -> Option<Result<LocationValue, LocationParseError>> {
    // Split into two DMS parts by comma or after N/S hemisphere letter.
    let (first, second) = split_dms_parts(input)?;
    let (v1, h1) = parse_single_dms(first)?;
    let (v2, h2) = parse_single_dms(second)?;

    let (lat_deg, lng_deg) = match (h1, h2) {
        (Some('N'), Some('E')) => (v1, v2),
        (Some('N'), Some('W')) => (v1, -v2),
        (Some('S'), Some('E')) => (-v1, v2),
        (Some('S'), Some('W')) => (-v1, -v2),
        (Some('E'), Some('N')) => (v2, v1),
        (Some('W'), Some('N')) => (v2, -v1),
        (Some('E'), Some('S')) => (-v2, v1),
        (Some('W'), Some('S')) => (-v2, -v1),
        (None, None) => (v1, v2),
        _ => return Some(Err(LocationParseError::InvalidSyntax)),
    };

    let lat_micro = (lat_deg * 1_000_000.0).round() as i64;
    let lng_micro = (lng_deg * 1_000_000.0).round() as i64;
    Some(validate_microdeg_pair(lat_micro, lng_micro))
}

fn split_dms_parts(input: &str) -> Option<(&str, &str)> {
    if let Some((a, b)) = input.split_once(',') {
        return Some((a.trim(), b.trim()));
    }
    // Find first hemisphere marker (N/S/E/W) followed by whitespace.
    for (idx, ch) in input.char_indices() {
        if matches!(ch.to_ascii_uppercase(), 'N' | 'S' | 'E' | 'W') {
            let next_idx = idx + ch.len_utf8();
            let rest = &input[next_idx..];
            if !rest.trim().is_empty() {
                return Some((input[..next_idx].trim(), rest.trim()));
            }
        }
    }
    None
}

fn parse_single_dms(part: &str) -> Option<(f64, Option<char>)> {
    let mut s = part.trim();
    if s.is_empty() {
        return None;
    }
    let mut hemisphere = None;
    if let Some(last) = s.chars().last() {
        if matches!(last.to_ascii_uppercase(), 'N' | 'S' | 'E' | 'W') {
            hemisphere = Some(last.to_ascii_uppercase());
            s = s[..s.len() - last.len_utf8()].trim();
        }
    }
    if hemisphere.is_none() {
        if let Some(first) = s.chars().next() {
            if matches!(first.to_ascii_uppercase(), 'N' | 'S' | 'E' | 'W') {
                hemisphere = Some(first.to_ascii_uppercase());
                s = s[first.len_utf8()..].trim();
            }
        }
    }

    let (deg_str, after_deg) = s.split_once('°')?;
    let deg: f64 = deg_str.trim().parse().ok()?;
    let negative = deg < 0.0 || deg_str.trim().starts_with('-');
    let deg_abs = deg.abs();

    let after_deg = after_deg.trim();
    let (min_val, sec_val) = if after_deg.is_empty() {
        (0.0, 0.0)
    } else if let Some((min_str, after_min)) = split_once_any(after_deg, &['\'', '′']) {
        let min_val: f64 = min_str.trim().parse().ok()?;
        let after_min = after_min.trim();
        let sec_val = if after_min.is_empty() {
            0.0
        } else {
            let sec_str = after_min
                .trim_end_matches(['"', '″'])
                .trim();
            if sec_str.is_empty() {
                0.0
            } else {
                sec_str.parse::<f64>().ok()?
            }
        };
        (min_val, sec_val)
    } else {
        return None;
    };

    if min_val < 0.0 || min_val >= 60.0 || sec_val < 0.0 || sec_val >= 60.0 {
        return None;
    }
    let magnitude = deg_abs + (min_val / 60.0) + (sec_val / 3600.0);
    let value = if negative && hemisphere.is_none() {
        -magnitude
    } else {
        magnitude
    };
    Some((value, hemisphere))
}

fn split_once_any<'a>(s: &'a str, delimiters: &[char]) -> Option<(&'a str, &'a str)> {
    for (idx, ch) in s.char_indices() {
        if delimiters.contains(&ch) {
            return Some((&s[..idx], &s[idx + ch.len_utf8()..]));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_six_and_four_decimal_places_with_exact_rounding() {
        let exact = LocationValue::new(38_710_841, -9_137_265, Some(12), false);
        assert_eq!(format_location_6dp(exact), "38.710841, -9.137265");
        assert_eq!(format_location_4dp(exact), "38.7108, -9.1373");
        assert_eq!(format_location_canonical(exact), "38.710841, -9.137265");

        let approx = LocationValue::new(38_710_200, -9_138_000, Some(1_900), true);
        assert_eq!(format_location_canonical(approx), "38.7102, -9.1380");

        let near_zero = LocationValue::new(-500, 500, None, false);
        assert_eq!(format_location_6dp(near_zero), "-0.000500, 0.000500");
    }

    #[test]
    fn parses_decimal_pairs_and_bounds() {
        assert_eq!(
            parse_location_input("38.7139, -9.1334").unwrap(),
            LocationValue::new(38_713_900, -9_133_400, None, false)
        );
        assert_eq!(
            parse_location_input("  38.7139   -9.1334 ").unwrap(),
            LocationValue::new(38_713_900, -9_133_400, None, false)
        );
        assert_eq!(
            parse_location_input("95.0, -9.1334"),
            Err(LocationParseError::LatitudeOutOfRange)
        );
        assert_eq!(
            parse_location_input("38.7139, 181.0"),
            Err(LocationParseError::LongitudeOutOfRange)
        );
        assert_eq!(
            parse_location_input("not a coordinate"),
            Err(LocationParseError::InvalidSyntax)
        );
    }

    #[test]
    fn parses_dms_coordinates() {
        assert_eq!(
            parse_location_input(r#"38°42'50"N 9°08'00"W"#).unwrap(),
            LocationValue::new(38_713_889, -9_133_333, None, false)
        );
        assert_eq!(
            parse_location_input("33°51′54.5″S, 151°12′35.6″E").unwrap(),
            LocationValue::new(-33_865_139, 151_209_889, None, false)
        );
    }

    #[test]
    fn parses_geo_uris_and_full_map_links() {
        let expected = LocationValue::new(38_713_900, -9_133_400, None, false);
        assert_eq!(parse_location_input("geo:38.7139,-9.1334").unwrap(), expected);
        assert_eq!(
            parse_location_input("geo:0,0?q=38.7139,-9.1334(Lisbon)").unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input("maps.google.com/?q=38.7139,-9.1334").unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input(
                "https://www.google.com/maps/place/Test/@38.7100,-9.1300,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d38.7139!4d-9.1334"
            )
            .unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input("https://www.google.com/maps/@38.7139,-9.1334,15z").unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input("https://waze.com/ul?ll=38.7139,-9.1334&navigate=yes").unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input("https://www.openstreetmap.org/#map=16/38.7139/-9.1334").unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input(
                "https://www.openstreetmap.org/?mlat=38.7139&mlon=-9.1334#map=16/38.7000/-9.1000"
            )
            .unwrap(),
            expected
        );
        assert_eq!(
            parse_location_input("https://www.openstreetmap.org/?mlat=38.7139&mlon=-9.1334")
                .unwrap(),
            expected
        );
    }

    #[test]
    fn detects_short_google_maps_links() {
        assert_eq!(
            parse_location_input("https://maps.app.goo.gl/Hxixt5WMth3JkB8J7f"),
            Err(LocationParseError::ShortLinkNeedsResolution(
                "https://maps.app.goo.gl/Hxixt5WMth3JkB8J7f".into()
            ))
        );
        assert_eq!(
            parse_location_input("goo.gl/maps/abc123"),
            Err(LocationParseError::ShortLinkNeedsResolution(
                "https://goo.gl/maps/abc123".into()
            ))
        );
    }
}
