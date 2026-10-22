use std::time::{SystemTime, UNIX_EPOCH};

use ::time::format_description::well_known::Rfc3339;
use ::time::{Date, Month, OffsetDateTime};

pub(crate) fn unix_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

pub(crate) fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

pub(crate) fn parse_rfc3339_unix_seconds(timestamp: &str) -> anyhow::Result<f64> {
    Ok(OffsetDateTime::parse(timestamp, &Rfc3339)?.unix_timestamp_nanos() as f64 / 1_000_000_000.0)
}

pub(crate) fn parse_rfc3339_seconds(timestamp: &str) -> Option<i64> {
    parse_rfc3339_millis(timestamp).map(|millis| millis.div_euclid(1_000))
}

pub(crate) fn parse_rfc3339_millis(timestamp: &str) -> Option<i64> {
    let timestamp = OffsetDateTime::parse(timestamp, &Rfc3339).ok()?;
    i64::try_from(timestamp.unix_timestamp_nanos().div_euclid(1_000_000)).ok()
}

pub(crate) fn civil_from_days(days: i64) -> u32 {
    let date = OffsetDateTime::from_unix_timestamp(days * 86_400)
        .expect("civil day inside supported timestamp range")
        .date();
    (date.year() as u32) * 10_000 + u32::from(date.month() as u8) * 100 + u32::from(date.day())
}

pub(crate) fn days_from_civil(day: u32) -> Option<i64> {
    let year = i32::try_from(day / 10_000).ok()?;
    let month = Month::try_from(u8::try_from((day / 100) % 100).ok()?).ok()?;
    let day = u8::try_from(day % 100).ok()?;
    Some(i64::from(
        Date::from_calendar_date(year, month, day)
            .ok()?
            .to_julian_day()
            - 2_440_588,
    ))
}

pub(crate) fn rfc3339_millis(unix_seconds: f64) -> String {
    let days = (unix_seconds / 86_400.0).floor() as i64;
    let date = OffsetDateTime::from_unix_timestamp(days * 86_400)
        .expect("journal date inside supported timestamp range")
        .date();
    let seconds_of_day = unix_seconds - (days as f64) * 86_400.0;
    let millis = (seconds_of_day * 1_000.0).floor() as i64;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        date.year(),
        date.month() as u8,
        date.day(),
        millis / 3_600_000,
        (millis / 60_000) % 60,
        (millis / 1_000) % 60,
        millis % 1_000
    )
}
