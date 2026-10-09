//! Cron scheduler: sends a schedule's prompt to its agent when the schedule fires.
//!
//! Each schedule stores a precomputed `next_run_at` (unix ms). [`spawn_loop`]
//! checks for due schedules every 15 seconds. A run that is due less than
//! [`MISSED_GRACE_MS`] ago fires once; an older one (the daemon was down) is
//! skipped and only the next occurrence is scheduled. Cron patterns have five
//! fields (`min hour dom mon dow`) and are evaluated in an IANA time zone.

use crate::store::{SchedulePatch, now_ms};
use crate::supervisor::{Inbound, Supervisor};
use anyhow::{Result, anyhow, bail};
use chrono::{DateTime, Utc};
use chrono_tz::Tz;
use croner::parser::{CronParser, Seconds, Year};
use std::sync::Arc;
use std::time::Duration;

/// A run missed by more than this (the daemon was down) is skipped, not replayed.
pub const MISSED_GRACE_MS: i64 = 60 * 60 * 1000;

const TICK_INTERVAL: Duration = Duration::from_secs(15);

/// The first occurrence strictly after `after_ms` (unix ms) of a 5-field cron
/// pattern in the IANA time zone `tz` (`UTC` included).
///
/// DST, as croner 4.0.1 resolves it (checked in tests):
/// - spring forward: a time that does not exist (02:30 on the gap day) runs at the first
///   real instant after the gap (03:00 EDT), once that day;
/// - fall back: a fixed time (01:30 on the repeated day) runs at its first occurrence, and
///   asking again after that run gives the next day's occurrence, not the repeated one.
pub fn next_run(cron: &str, tz: &str, after_ms: i64) -> Result<i64> {
    let pattern = CronParser::builder()
        .seconds(Seconds::Disallowed)
        .year(Year::Disallowed)
        .build()
        .parse(cron)
        .map_err(|e| anyhow!("invalid schedule '{cron}': {e}"))?;
    let zone: Tz = tz.parse().map_err(|_| anyhow!("unknown time zone '{tz}'"))?;
    let after = DateTime::<Utc>::from_timestamp_millis(after_ms)
        .ok_or_else(|| anyhow!("timestamp out of range: {after_ms}"))?
        .with_timezone(&zone);
    let next = pattern
        .find_next_occurrence(&after, false)
        .map_err(|_| anyhow!("schedule '{cron}' never runs"))?;
    Ok(next.timestamp_millis())
}

/// Fire every due schedule. Returns how many runs were attempted.
///
/// Each due run is claimed in the store before it is sent: the claim moves `next_run_at`
/// only if it still equals the value read here and the schedule is enabled. So a run is
/// recorded at most once, and a schedule edited or disabled in the meantime is skipped.
/// A failure on one schedule is logged and does not stop the others.
pub async fn tick(sup: &Supervisor, now_ms: i64) -> Result<usize> {
    let store = &sup.hub().store;
    let mut fired = 0;
    for s in store.schedule_due(now_ms)? {
        let Some(due_at) = s.next_run_at else {
            continue;
        };
        let next = match next_run(&s.cron, &s.tz, now_ms) {
            Ok(next) => next,
            Err(e) => {
                tracing::warn!(schedule = %s.id, "disabling broken schedule: {e:#}");
                let disable = SchedulePatch {
                    enabled: Some(false),
                    ..Default::default()
                };
                if let Err(e) = store.schedule_update(&s.id, disable, None) {
                    tracing::warn!(schedule = %s.id, "could not disable broken schedule: {e:#}");
                }
                continue;
            }
        };
        if now_ms - due_at <= MISSED_GRACE_MS {
            match store.schedule_claim(&s.id, due_at, now_ms, Some(next)) {
                Ok(true) => {}
                Ok(false) => {
                    tracing::info!(schedule = %s.id, "schedule changed during tick, run skipped");
                    continue;
                }
                Err(e) => {
                    tracing::warn!(schedule = %s.id, "could not claim scheduled run: {e:#}");
                    continue;
                }
            }
            // At-most-once: the run is already recorded, so a failed send is only logged.
            if let Err(e) = sup.send(&s.agent_id, Inbound::schedule(s.prompt.clone())).await {
                tracing::warn!(schedule = %s.id, agent = %s.agent_id, "scheduled run failed: {e:#}");
            }
            fired += 1;
        } else {
            match store.schedule_reschedule(&s.id, due_at, Some(next)) {
                Ok(true) => tracing::info!(schedule = %s.id, "skipped a run missed while the daemon was down"),
                Ok(false) => tracing::info!(schedule = %s.id, "schedule changed during tick, missed run left alone"),
                Err(e) => tracing::warn!(schedule = %s.id, "could not reschedule missed run: {e:#}"),
            }
        }
    }
    Ok(fired)
}

/// Fire one schedule now, as an explicit user action. Its next occurrence stays as it was.
///
/// Unlike [`tick`], this does not claim the run first. A failed send is returned to the
/// caller and nothing is recorded (`last_run_at` is written only after a successful send),
/// so the error is visible at once and the user can retry.
pub async fn run_now(sup: &Supervisor, id: &str) -> Result<()> {
    let store = &sup.hub().store;
    let Some(s) = store.schedule_get(id)? else {
        bail!("no schedule {id}");
    };
    sup.send(&s.agent_id, Inbound::schedule(s.prompt.clone())).await?;
    store.schedule_mark_run(&s.id, now_ms(), s.next_run_at)?;
    Ok(())
}

/// Run [`tick`] every 15 seconds for the life of the daemon.
pub fn spawn_loop(sup: Arc<Supervisor>) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(TICK_INTERVAL);
        loop {
            interval.tick().await;
            if let Err(e) = tick(&sup, now_ms()).await {
                tracing::warn!("scheduler tick: {e:#}");
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::EventBody;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, NewSchedule, Store};
    use crate::supervisor::Runtimes;

    fn ms(rfc3339: &str) -> i64 {
        DateTime::parse_from_rfc3339(rfc3339).unwrap().timestamp_millis()
    }

    #[test]
    fn next_run_utc_hourly_daily() {
        let after = ms("2026-10-09T00:00:00Z");
        assert_eq!(next_run("0 2 * * *", "UTC", after).unwrap(), ms("2026-10-09T02:00:00Z"));
    }

    #[test]
    fn next_run_uses_time_zone() {
        let after = ms("2026-10-09T00:00:00Z");
        // 02:00 in Tokyo (UTC+9) is 17:00 UTC the day before.
        assert_eq!(
            next_run("0 2 * * *", "Asia/Tokyo", after).unwrap(),
            ms("2026-10-09T17:00:00Z")
        );
    }

    #[test]
    fn next_run_is_strictly_after() {
        let at = ms("2026-10-09T02:00:00Z");
        assert_eq!(next_run("0 2 * * *", "UTC", at).unwrap(), ms("2026-10-10T02:00:00Z"));
    }

    #[test]
    fn next_run_every_fifteen_minutes() {
        assert_eq!(
            next_run("*/15 * * * *", "UTC", ms("2026-10-09T10:07:00Z")).unwrap(),
            ms("2026-10-09T10:15:00Z")
        );
    }

    #[test]
    fn next_run_weekday() {
        // 2026-10-09 is a Friday; the next Monday is the 12th.
        assert_eq!(
            next_run("0 9 * * 1", "UTC", ms("2026-10-09T12:00:00Z")).unwrap(),
            ms("2026-10-12T09:00:00Z")
        );
    }

    #[test]
    fn next_run_new_york_daylight_time() {
        // Still EDT (UTC-4) on 2026-10-09.
        assert_eq!(
            next_run("0 9 * * *", "America/New_York", ms("2026-10-09T00:00:00Z")).unwrap(),
            ms("2026-10-09T13:00:00Z")
        );
    }

    #[test]
    fn next_run_rejects_bad_cron() {
        let err = next_run("61 * * * *", "UTC", 0).unwrap_err().to_string();
        assert!(err.contains("invalid schedule"), "{err}");
        assert!(err.contains("'61 * * * *'"), "{err}");
    }

    #[test]
    fn next_run_rejects_six_fields() {
        let err = next_run("0 0 0 0 0 0", "UTC", 0).unwrap_err().to_string();
        assert!(err.contains("invalid schedule"), "{err}");
    }

    #[test]
    fn next_run_rejects_unknown_zone() {
        let err = next_run("0 2 * * *", "Mars/Base", 0).unwrap_err().to_string();
        assert_eq!(err, "unknown time zone 'Mars/Base'");
    }

    #[test]
    fn next_run_reports_never() {
        // February 30th does not exist.
        let err = next_run("0 0 30 2 *", "UTC", 0).unwrap_err().to_string();
        assert_eq!(err, "schedule '0 0 30 2 *' never runs");
    }

    #[test]
    fn next_run_new_york_spring_gap_runs_once_that_day() {
        // 2026-03-08: 02:00 EST jumps to 03:00 EDT at 07:00Z, so 02:30 does not exist.
        // Observed croner 4.0.1 behaviour: the run lands on the first real instant after the gap.
        let first = next_run("30 2 * * *", "America/New_York", ms("2026-03-08T05:00:00Z")).unwrap();
        assert_eq!(first, ms("2026-03-08T07:00:00Z"));
        // The run after that is the next day's 02:30 EDT: one run on 03-08, none lost.
        let second = next_run("30 2 * * *", "America/New_York", first).unwrap();
        assert_eq!(second, ms("2026-03-09T06:30:00Z"));
    }

    #[test]
    fn next_run_new_york_fall_back_does_not_repeat_the_day() {
        // 2026-11-01: 01:00-01:59 happens twice: EDT (05:00-05:59Z), then EST (06:00-06:59Z).
        // Observed croner 4.0.1 behaviour: a fixed time runs at its first occurrence only.
        let oct31 = next_run("30 1 * * *", "America/New_York", ms("2026-10-31T05:00:00Z")).unwrap();
        assert_eq!(oct31, ms("2026-10-31T05:30:00Z"));
        // Nov 1, first 01:30 (EDT): one run for the day.
        let nov1 = next_run("30 1 * * *", "America/New_York", oct31).unwrap();
        assert_eq!(nov1, ms("2026-11-01T05:30:00Z"));
        // Asking again after that run must not return the repeated 01:30 EST (06:30Z) of Nov 1.
        let nov2 = next_run("30 1 * * *", "America/New_York", nov1).unwrap();
        assert_eq!(nov2, ms("2026-11-02T06:30:00Z"));
        // The same holds when the tick asks from inside the repeated hour.
        let inside = next_run("30 1 * * *", "America/New_York", ms("2026-11-01T06:10:00Z")).unwrap();
        assert_eq!(inside, ms("2026-11-02T06:30:00Z"));
    }

    const NOW: &str = "2026-10-09T10:00:00Z";

    fn setup() -> (Arc<Supervisor>, Arc<Store>, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
            })
            .unwrap();
        // No runtimes: a send fails after emitting an `error` event, which
        // proves the run was attempted.
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        (sup, store, agent.id)
    }

    fn new_schedule(agent: &str, cron: &str, enabled: bool) -> NewSchedule {
        NewSchedule {
            agent_id: agent.into(),
            cron: cron.into(),
            tz: "UTC".into(),
            prompt: "report".into(),
            enabled,
        }
    }

    fn agent_events(store: &Store, agent: &str) -> Vec<EventBody> {
        store
            .events_since(0, 100, Some(agent))
            .unwrap()
            .into_iter()
            .map(|e| e.body)
            .collect()
    }

    #[tokio::test]
    async fn tick_fires_due_schedule_and_advances_it() {
        let (sup, store, agent) = setup();
        let now = ms(NOW);
        let s = store
            .schedule_create(new_schedule(&agent, "0 * * * *", true), Some(now - 1000))
            .unwrap();

        assert_eq!(tick(&sup, now).await.unwrap(), 1);

        let events = agent_events(&store, &agent);
        assert!(
            events
                .iter()
                .any(|b| matches!(b, EventBody::Error { message } if message.contains("could not start the agent"))),
            "{events:?}"
        );
        let after = store.schedule_get(&s.id).unwrap().unwrap();
        assert_eq!(after.last_run_at, Some(now));
        assert_eq!(after.next_run_at, Some(ms("2026-10-09T11:00:00Z")));
    }

    #[tokio::test]
    async fn tick_skips_run_missed_by_more_than_grace() {
        let (sup, store, agent) = setup();
        let now = ms(NOW);
        let s = store
            .schedule_create(new_schedule(&agent, "0 * * * *", true), Some(now - 2 * 60 * 60 * 1000))
            .unwrap();

        assert_eq!(tick(&sup, now).await.unwrap(), 0);

        assert!(agent_events(&store, &agent).is_empty());
        let after = store.schedule_get(&s.id).unwrap().unwrap();
        assert_eq!(after.last_run_at, None);
        assert_eq!(after.next_run_at, Some(ms("2026-10-09T11:00:00Z")));
        assert!(after.next_run_at.unwrap() > now);
    }

    #[tokio::test]
    async fn tick_ignores_disabled_schedule() {
        let (sup, store, agent) = setup();
        let now = ms(NOW);
        let s = store
            .schedule_create(new_schedule(&agent, "0 * * * *", false), Some(now - 1000))
            .unwrap();

        assert_eq!(tick(&sup, now).await.unwrap(), 0);

        assert!(agent_events(&store, &agent).is_empty());
        assert_eq!(store.schedule_get(&s.id).unwrap().unwrap().last_run_at, None);
    }

    #[tokio::test]
    async fn tick_disables_broken_schedule() {
        let (sup, store, agent) = setup();
        let now = ms(NOW);
        let s = store
            .schedule_create(new_schedule(&agent, "bad", true), Some(now - 1000))
            .unwrap();

        assert_eq!(tick(&sup, now).await.unwrap(), 0);

        let after = store.schedule_get(&s.id).unwrap().unwrap();
        assert!(!after.enabled);
        assert_eq!(after.next_run_at, None);
        assert!(agent_events(&store, &agent).is_empty());
    }

    #[tokio::test]
    async fn tick_does_not_fire_twice_for_the_same_now() {
        let (sup, store, agent) = setup();
        let now = ms(NOW);
        store
            .schedule_create(new_schedule(&agent, "0 * * * *", true), Some(now - 1000))
            .unwrap();

        assert_eq!(tick(&sup, now).await.unwrap(), 1);
        assert_eq!(tick(&sup, now).await.unwrap(), 0);

        let events = agent_events(&store, &agent);
        let attempts = events.iter().filter(|b| matches!(b, EventBody::Error { .. })).count();
        assert_eq!(attempts, 1, "{events:?}");
    }

    #[tokio::test]
    async fn tick_broken_schedule_does_not_stop_others() {
        let (sup, store, agent) = setup();
        let now = ms(NOW);
        // The broken one is due first, so it is handled before the good one.
        let bad = store
            .schedule_create(new_schedule(&agent, "bad", true), Some(now - 2000))
            .unwrap();
        let good = store
            .schedule_create(new_schedule(&agent, "0 * * * *", true), Some(now - 1000))
            .unwrap();

        assert_eq!(tick(&sup, now).await.unwrap(), 1);

        assert!(!store.schedule_get(&bad.id).unwrap().unwrap().enabled);
        let after = store.schedule_get(&good.id).unwrap().unwrap();
        assert_eq!(after.last_run_at, Some(now));
        assert_eq!(after.next_run_at, Some(ms("2026-10-09T11:00:00Z")));
    }

    #[tokio::test]
    async fn run_now_sends_and_keeps_next_run() {
        let (sup, store, agent) = setup();
        let next = ms("2026-10-09T11:00:00Z");
        let s = store
            .schedule_create(new_schedule(&agent, "0 * * * *", true), Some(next))
            .unwrap();
        let err = run_now(&sup, &s.id).await;
        // The send fails (no runtime), so the run is not recorded.
        assert!(err.is_err());
        assert_eq!(store.schedule_get(&s.id).unwrap().unwrap().last_run_at, None);

        assert!(
            run_now(&sup, "missing")
                .await
                .unwrap_err()
                .to_string()
                .contains("no schedule missing")
        );
    }
}
