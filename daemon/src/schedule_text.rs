//! Turns the agent's schedule forms into cron, and a cron back into words for the app (see
//! docs/ARCHITECTURE.md#scheduler). Pure functions: no store, no clock.

/// `every` as cron, clock-aligned: `15m` → `*/15 * * * *`, `2h` → `0 */2 * * *`, `1d` → `0 0 * * *` (midnight).
/// Only steps that divide the hour or the day are allowed, so the gaps are even: minutes 5 to 60, hours 1 to 12
/// (1, 2, 3, 4, 6, 8, 12), and 1 day.
pub fn cron_every(every: &str) -> Result<String, String> {
    const HOURS: [u32; 7] = [1, 2, 3, 4, 6, 8, 12];
    let bad = || "every must be 5m to 60m, 1h to 12h (1, 2, 3, 4, 6, 8, 12) or 1d".to_string();
    let e = every.trim().to_ascii_lowercase();
    let unit = e.chars().last().ok_or_else(bad)?;
    let n: u32 = e[..e.len() - unit.len_utf8()].parse().map_err(|_| bad())?;
    match unit {
        'm' if n == 60 => Ok("0 * * * *".into()),
        'm' if (5..60).contains(&n) && 60 % n == 0 => Ok(format!("*/{n} * * * *")),
        'h' if n == 1 => Ok("0 * * * *".into()),
        'h' if HOURS.contains(&n) => Ok(format!("0 */{n} * * *")),
        'd' if n == 1 => Ok("0 0 * * *".into()),
        _ => Err(bad()),
    }
}

/// `at` (`HH:MM`) and optional `days` (`mon`…`sun`) as cron. No days means every day.
pub fn cron_at(at: &str, days: Option<&[String]>) -> Result<String, String> {
    let (h, m) = at
        .trim()
        .split_once(':')
        .filter(|(h, m)| h.len() <= 2 && m.len() == 2)
        .and_then(|(h, m)| Some((h.parse::<u32>().ok()?, m.parse::<u32>().ok()?)))
        .filter(|(h, m)| *h < 24 && *m < 60)
        .ok_or_else(|| "at must be a time as HH:MM, for example 09:00".to_string())?;
    let dow = match days {
        None => "*".to_string(),
        Some([]) => return Err("days is empty: leave it out for every day".into()),
        Some(list) => {
            let mut nums: Vec<u32> = list
                .iter()
                .map(|d| {
                    Ok(match d.trim().to_ascii_lowercase().as_str() {
                        "sun" => 0,
                        "mon" => 1,
                        "tue" => 2,
                        "wed" => 3,
                        "thu" => 4,
                        "fri" => 5,
                        "sat" => 6,
                        other => return Err(format!("unknown day {other}: use mon, tue, wed, thu, fri, sat, sun")),
                    })
                })
                .collect::<Result<_, String>>()?;
            nums.sort_unstable();
            nums.dedup();
            if nums.len() == 7 {
                "*".to_string()
            } else if nums == [1, 2, 3, 4, 5] {
                "1-5".to_string()
            } else {
                nums.iter().map(u32::to_string).collect::<Vec<_>>().join(",")
            }
        }
    };
    Ok(format!("{m} {h} * * {dow}"))
}

/// The cron as words, `(english, russian)`. Covers the forms [`cron_every`] and [`cron_at`] make, plus
/// every day and weekdays at a time; any other cron is returned as it is, in both.
pub fn describe(cron: &str) -> (String, String) {
    let plain = || (cron.to_string(), cron.to_string());
    let fields: Vec<&str> = cron.split_whitespace().collect();
    let [min, hour, dom, mon, dow] = fields[..] else {
        return plain();
    };
    if dom != "*" || mon != "*" {
        return plain();
    }
    // Only the steps `cron_every` makes: uneven ones (`*/7`) are not described as an interval.
    if let Some(n) = min.strip_prefix("*/").and_then(|n| n.parse::<u32>().ok())
        && hour == "*"
        && dow == "*"
        && (n == 1 || ((5..60).contains(&n) && 60 % n == 0))
    {
        return if n == 1 {
            ("every minute".into(), "каждую минуту".into())
        } else {
            (
                format!("every {n} minutes"),
                format!("каждые {}", ru_count(n, "минуту", "минуты", "минут")),
            )
        };
    }
    if min == "0" && hour == "*" && dow == "*" {
        return ("every hour".into(), "каждый час".into());
    }
    if min == "0"
        && let Some(n) = hour.strip_prefix("*/").and_then(|n| n.parse::<u32>().ok())
        && dow == "*"
        && [2, 3, 4, 6, 8, 12].contains(&n)
    {
        return (
            format!("every {n} hours"),
            format!("каждые {}", ru_count(n, "час", "часа", "часов")),
        );
    }
    let (Ok(h), Ok(m)) = (hour.parse::<u32>(), min.parse::<u32>()) else {
        return plain();
    };
    if h > 23 || m > 59 {
        return plain();
    }
    let at = format!("{h:02}:{m:02}");
    match dow {
        "*" => (format!("every day at {at}"), format!("каждый день в {at}")),
        "1-5" | "1,2,3,4,5" => (format!("weekdays at {at}"), format!("по будням в {at}")),
        _ => plain(),
    }
}

/// `n` with the Russian noun in the right form: 1 минуту, 2 минуты, 5 минут.
fn ru_count(n: u32, one: &str, few: &str, many: &str) -> String {
    let (m10, m100) = (n % 10, n % 100);
    let word = if m10 == 1 && m100 != 11 {
        one
    } else if (2..=4).contains(&m10) && !(12..=14).contains(&m100) {
        few
    } else {
        many
    };
    format!("{n} {word}")
}

/// The owner's zone for `at` schedules: `TZ`, else the zone of `/etc/localtime`, else UTC.
pub fn local_zone() -> String {
    let known = |name: &str| name.parse::<chrono_tz::Tz>().is_ok().then(|| name.to_string());
    std::env::var("TZ")
        .ok()
        .and_then(|tz| known(tz.trim_start_matches(':')))
        .or_else(|| {
            let link = std::fs::read_link("/etc/localtime").ok()?;
            let link = link.to_string_lossy().into_owned();
            known(link.split("zoneinfo/").nth(1)?)
        })
        .unwrap_or_else(|| "UTC".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_becomes_a_clock_aligned_step() {
        assert_eq!(cron_every("15m").unwrap(), "*/15 * * * *");
        assert_eq!(cron_every(" 5M ").unwrap(), "*/5 * * * *");
        assert_eq!(cron_every("60m").unwrap(), "0 * * * *");
        assert_eq!(cron_every("1h").unwrap(), "0 * * * *");
        assert_eq!(cron_every("2h").unwrap(), "0 */2 * * *");
        assert_eq!(cron_every("12h").unwrap(), "0 */12 * * *");
        assert_eq!(cron_every("1d").unwrap(), "0 0 * * *");
    }

    #[test]
    fn every_refuses_gaps_that_do_not_even_out_and_the_under_five_minutes() {
        for bad in [
            "4m", "7m", "61m", "0m", "5", "", "5s", "5x", "5h", "5 h", "2d", "-5m", "é",
        ] {
            assert!(cron_every(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn at_and_days_become_cron() {
        assert_eq!(cron_at("09:00", None).unwrap(), "0 9 * * *");
        assert_eq!(cron_at("9:30", None).unwrap(), "30 9 * * *");
        assert_eq!(cron_at("23:59", None).unwrap(), "59 23 * * *");
        let weekdays: Vec<String> = ["mon", "Tue", "wed", "thu", "fri"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(cron_at("09:00", Some(&weekdays)).unwrap(), "0 9 * * 1-5");
        let weekend: Vec<String> = vec!["sat".into(), "sun".into()];
        assert_eq!(cron_at("10:00", Some(&weekend)).unwrap(), "0 10 * * 0,6");
        let all: Vec<String> = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(cron_at("08:00", Some(&all)).unwrap(), "0 8 * * *");
    }

    #[test]
    fn at_and_days_refuse_bad_input() {
        for bad in ["24:00", "12:60", "9", "9:0", "ab:cd", "", "123:00"] {
            assert!(cron_at(bad, None).is_err(), "{bad:?}");
        }
        let none: Vec<String> = vec![];
        assert!(cron_at("09:00", Some(&none)).is_err());
        let typo: Vec<String> = vec!["monday".into()];
        assert!(cron_at("09:00", Some(&typo)).is_err());
    }

    #[test]
    fn describe_says_the_forms_in_both_languages() {
        assert_eq!(
            describe("*/15 * * * *"),
            ("every 15 minutes".into(), "каждые 15 минут".into())
        );
        assert_eq!(describe("*/5 * * * *").1, "каждые 5 минут");
        assert_eq!(describe("*/20 * * * *").1, "каждые 20 минут");
        assert_eq!(describe("*/21 * * * *").1, "*/21 * * * *");
        assert_eq!(describe("*/1 * * * *"), ("every minute".into(), "каждую минуту".into()));
        assert_eq!(describe("0 * * * *"), ("every hour".into(), "каждый час".into()));
        assert_eq!(
            describe("0 */2 * * *"),
            ("every 2 hours".into(), "каждые 2 часа".into())
        );
        assert_eq!(describe("0 */6 * * *").1, "каждые 6 часов");
        assert_eq!(
            describe("0 9 * * 1-5"),
            ("weekdays at 09:00".into(), "по будням в 09:00".into())
        );
        assert_eq!(describe("0 9 * * 1,2,3,4,5").0, "weekdays at 09:00");
        assert_eq!(
            describe("0 0 * * *"),
            ("every day at 00:00".into(), "каждый день в 00:00".into())
        );
    }

    #[test]
    fn describe_gives_other_crons_back_as_they_are() {
        for cron in [
            "0 9 * * 0,6",
            "0 9 1 * *",
            "0 9 * * 1",
            "*/7 * * * *",
            "0 9,17 * * *",
            "bad cron",
        ] {
            assert_eq!(describe(cron), (cron.to_string(), cron.to_string()), "{cron}");
        }
    }

    #[test]
    fn a_made_cron_describes_back_to_its_words() {
        let every = cron_every("15m").unwrap();
        assert_eq!(describe(&every).0, "every 15 minutes");
        let weekdays = cron_at(
            "09:00",
            Some(&["mon".into(), "fri".into(), "tue".into(), "wed".into(), "thu".into()]),
        )
        .unwrap();
        assert_eq!(describe(&weekdays).0, "weekdays at 09:00");
    }

    #[test]
    fn local_zone_is_a_zone_name_chrono_tz_knows() {
        assert!(local_zone().parse::<chrono_tz::Tz>().is_ok());
    }
}
