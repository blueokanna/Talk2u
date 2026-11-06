use std::time::{SystemTime, UNIX_EPOCH};

use tzcraft::{Ticks, Zone, Zoned};

/// Milliseconds since the Unix epoch.
///
/// The whole core stores instants as `i64` milliseconds because that is the
/// only representation Flutter can transport without loss. `tzcraft::Ticks` is
/// the arithmetic type: 128-bit nanoseconds, floor semantics before the epoch,
/// and a distinct `Duration` so instants and spans cannot be mixed.
pub(crate) fn now_millis() -> i64 {
    if let Ok(ticks) = Ticks::now() {
        if let Ok(millis) = ticks.timestamp_millis() {
            return millis;
        }
    }
    // A clock set before 1970 is the only way `Ticks::now` fails here; the
    // fallback keeps message ordering usable instead of stamping everything 0.
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

pub(crate) fn to_ticks(millis: i64) -> Ticks {
    Ticks::from_unix_nanos(i128::from(millis) * 1_000_000)
}

/// `YYYY-MM-DD HH:MM:SS UTC`, used where a log line needs a human timestamp.
pub(crate) fn format_utc(millis: i64) -> String {
    let zoned = Zoned::new(to_ticks(millis), Zone::Utc);
    zoned
        .format("%Y-%m-%d %H:%M:%S UTC")
        .unwrap_or_else(|_| format!("{millis}ms"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn now_millis_tracks_the_system_clock() {
        let before = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let now = now_millis();
        assert!(now >= before, "clock went backwards");
        assert!(now - before < 5_000, "clock jumped unexpectedly");
    }

    #[test]
    fn ticks_round_trip_through_milliseconds() {
        let millis = 1_760_000_000_123;
        assert_eq!(to_ticks(millis).timestamp_millis().unwrap(), millis);
    }

    #[test]
    fn utc_formatting_is_stable() {
        assert_eq!(format_utc(0), "1970-01-01 00:00:00 UTC");
        assert_eq!(format_utc(1_760_000_000_000), "2025-10-09 08:53:20 UTC");
    }

}
