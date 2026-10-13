//! The server settings the owner changes from the apps (docs/ARCHITECTURE.md#server-settings): their names, limits,
//! defaults, the check of a change and the reading of what is stored. The storage is `store/server_settings.rs`.
//! A missing row means the default, so a value that is not in the store yet keeps the behavior it had before.

use crate::store::ApprovalMode;
use serde_json::{Map, Value, json};
use std::collections::HashMap;

pub const SCREEN_IDLE_MINUTES: &str = "screen_idle_minutes";
pub const MAX_RUNNING_AGENTS: &str = "max_running_agents";
pub const BACKUP_EVERY_HOURS: &str = "backup_every_hours";
pub const BACKUP_KEEP: &str = "backup_keep";
pub const AUTO_UPDATE: &str = "auto_update";
pub const UPDATE_CHANNEL: &str = "update_channel";
pub const DEFAULT_APPROVAL_MODE: &str = "default_approval_mode";
pub const PHONE_ACCESS: &str = "phone_access";
pub const PHONE_PORT: &str = "phone_port";

/// Every setting name, in the order `server.settings_get` lists them.
pub const KEYS: [&str; 9] = [
    SCREEN_IDLE_MINUTES,
    MAX_RUNNING_AGENTS,
    BACKUP_EVERY_HOURS,
    BACKUP_KEEP,
    AUTO_UPDATE,
    UPDATE_CHANNEL,
    DEFAULT_APPROVAL_MODE,
    PHONE_ACCESS,
    PHONE_PORT,
];

/// Allowed range of `screen_idle_minutes`, both ends included.
const SCREEN_IDLE_RANGE: (i64, i64) = (5, 240);
/// Allowed range of `max_running_agents` besides 0, which means no limit.
const MAX_RUNNING_RANGE: (i64, i64) = (1, 50);
/// The values `backup_every_hours` may take: 6 hours to a week.
const BACKUP_EVERY_HOURS_VALUES: [i64; 5] = [6, 12, 24, 48, 168];
/// Allowed range of `backup_keep`, both ends included.
const BACKUP_KEEP_RANGE: (i64, i64) = (3, 60);
/// Allowed range of `phone_port`, both ends included: no privileged ports.
const PHONE_PORT_RANGE: (i64, i64) = (1024, 65535);
/// The port of the phone listener when none is set.
pub const DEFAULT_PHONE_PORT: u16 = 7879;
const MINUTE_MS: i64 = 60_000;
const HOUR_MS: i64 = 3_600_000;

/// What the daemon does about a newer release (`auto_update`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoUpdate {
    /// No check runs by itself. A check the owner asks for still works.
    Off,
    /// The daily check runs and a newer release is written to the log (the behavior before this setting).
    Notify,
    /// As `Notify`, and a newer release is installed at night (see `update::may_install`).
    Install,
}

impl AutoUpdate {
    pub fn as_str(self) -> &'static str {
        match self {
            AutoUpdate::Off => "off",
            AutoUpdate::Notify => "notify",
            AutoUpdate::Install => "install",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "off" => AutoUpdate::Off,
            "notify" => AutoUpdate::Notify,
            "install" => AutoUpdate::Install,
            _ => return None,
        })
    }
}

/// Who may reach the daemon directly from a phone (`phone_access`, docs/ARCHITECTURE.md#phone-access).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhoneMode {
    /// No listener besides loopback (the default).
    Off,
    /// A TLS listener on this machine's Tailscale addresses only.
    Tailscale,
    /// A TLS listener on every address of this machine (the local network, and Tailscale too).
    Lan,
}

impl PhoneMode {
    pub fn as_str(self) -> &'static str {
        match self {
            PhoneMode::Off => "off",
            PhoneMode::Tailscale => "tailscale",
            PhoneMode::Lan => "lan",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "off" => PhoneMode::Off,
            "tailscale" => PhoneMode::Tailscale,
            "lan" => PhoneMode::Lan,
            _ => return None,
        })
    }
}

/// The release channel. Only `stable` exists: the daemon has no beta releases to follow.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateChannel {
    Stable,
}

impl UpdateChannel {
    pub fn as_str(self) -> &'static str {
        match self {
            UpdateChannel::Stable => "stable",
        }
    }
}

/// The settings as they apply now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerSettings {
    /// A screen with no VNC client and no agent call for this many minutes stops (5 to 240).
    pub screen_idle_minutes: u32,
    /// How many agents run a turn at once; the others wait in their queue. 0 means no limit.
    pub max_running_agents: u32,
    /// A database copy is due when the newest is older than this many hours (6, 12, 24, 48 or 168).
    pub backup_every_hours: u32,
    /// How many database copies are kept (3 to 60).
    pub backup_keep: u32,
    pub auto_update: AutoUpdate,
    pub update_channel: UpdateChannel,
    /// The approval mode of a new agent that the creating call does not set.
    pub default_approval_mode: ApprovalMode,
    /// Whether, and on which addresses, the daemon also listens for phones (TLS only).
    pub phone_access: PhoneMode,
    /// The TCP port of the phone listener (1024 to 65535).
    pub phone_port: u16,
}

/// The values a daemon with no stored settings uses: the behavior it had before the settings existed.
pub fn defaults() -> ServerSettings {
    ServerSettings {
        screen_idle_minutes: 30,
        max_running_agents: 0,
        backup_every_hours: 24,
        backup_keep: 14,
        auto_update: AutoUpdate::Notify,
        update_channel: UpdateChannel::Stable,
        default_approval_mode: ApprovalMode::Risky,
        phone_access: PhoneMode::Off,
        phone_port: DEFAULT_PHONE_PORT,
    }
}

impl ServerSettings {
    /// The number of turns that may run at once. `usize::MAX` when there is no limit.
    pub fn turn_limit(&self) -> usize {
        match self.max_running_agents {
            0 => usize::MAX,
            n => n as usize,
        }
    }

    /// How long a screen may stay unused before it stops, in ms.
    pub fn screen_idle_ms(&self) -> i64 {
        i64::from(self.screen_idle_minutes) * MINUTE_MS
    }

    /// The time between two database copies, in ms.
    pub fn backup_every_ms(&self) -> i64 {
        i64::from(self.backup_every_hours) * HOUR_MS
    }

    /// The settings as `server.settings_get` shows them: every name with its value.
    pub fn to_json(&self) -> Value {
        json!({
            SCREEN_IDLE_MINUTES: self.screen_idle_minutes,
            MAX_RUNNING_AGENTS: self.max_running_agents,
            BACKUP_EVERY_HOURS: self.backup_every_hours,
            BACKUP_KEEP: self.backup_keep,
            AUTO_UPDATE: self.auto_update.as_str(),
            UPDATE_CHANNEL: self.update_channel.as_str(),
            DEFAULT_APPROVAL_MODE: self.default_approval_mode.as_str(),
            PHONE_ACCESS: self.phone_access.as_str(),
            PHONE_PORT: self.phone_port,
        })
    }
}

/// The defaults as `server.settings_get` shows them in `defaults`.
pub fn defaults_json() -> Value {
    defaults().to_json()
}

/// A change that is refused: the name of the setting and what it must be, in one short English sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invalid {
    pub field: String,
    pub reason: String,
}

/// Checks a `server.settings_set` patch. Every key must be a known setting and every value in its range; the first
/// failure is returned and nothing is changed. On success, the values to store, as text, in the patch's order.
pub fn check_patch(patch: &Map<String, Value>) -> Result<Vec<(&'static str, String)>, Invalid> {
    let mut out = Vec::with_capacity(patch.len());
    for (field, value) in patch {
        let invalid = |reason: &str| Invalid {
            field: field.clone(),
            reason: reason.to_string(),
        };
        let Some(key) = KEYS.iter().copied().find(|k| k == field) else {
            return Err(invalid("unknown setting: see server.settings_get for the names"));
        };
        let text = match key {
            SCREEN_IDLE_MINUTES => int_in(value, SCREEN_IDLE_RANGE)
                .ok_or_else(|| invalid("must be a whole number from 5 to 240"))?
                .to_string(),
            MAX_RUNNING_AGENTS => match value.as_i64() {
                Some(0) => "0".to_string(),
                Some(n) if (MAX_RUNNING_RANGE.0..=MAX_RUNNING_RANGE.1).contains(&n) => n.to_string(),
                _ => return Err(invalid("must be 0 (no limit) or a whole number from 1 to 50")),
            },
            BACKUP_EVERY_HOURS => match value.as_i64() {
                Some(n) if BACKUP_EVERY_HOURS_VALUES.contains(&n) => n.to_string(),
                _ => return Err(invalid("must be one of 6, 12, 24, 48 or 168")),
            },
            BACKUP_KEEP => int_in(value, BACKUP_KEEP_RANGE)
                .ok_or_else(|| invalid("must be a whole number from 3 to 60"))?
                .to_string(),
            AUTO_UPDATE => match value.as_str().and_then(AutoUpdate::parse) {
                Some(mode) => mode.as_str().to_string(),
                None => return Err(invalid("must be off, notify or install")),
            },
            UPDATE_CHANNEL => match value.as_str() {
                Some("stable") => UpdateChannel::Stable.as_str().to_string(),
                Some("beta") => {
                    return Err(invalid("the beta channel is not available in this release: use stable"));
                }
                _ => return Err(invalid("must be stable")),
            },
            DEFAULT_APPROVAL_MODE => match value.as_str().and_then(ApprovalMode::parse) {
                Some(mode) => mode.as_str().to_string(),
                None => return Err(invalid("must be always, risky or never")),
            },
            PHONE_ACCESS => match value.as_str().and_then(PhoneMode::parse) {
                Some(mode) => mode.as_str().to_string(),
                None => return Err(invalid("must be off, tailscale or lan")),
            },
            PHONE_PORT => int_in(value, PHONE_PORT_RANGE)
                .ok_or_else(|| invalid("must be a whole number from 1024 to 65535"))?
                .to_string(),
            _ => unreachable!("KEYS lists only the names above"),
        };
        out.push((key, text));
    }
    Ok(out)
}

/// `value` as a whole number in `range` (both ends included), or None.
fn int_in(value: &Value, range: (i64, i64)) -> Option<i64> {
    value.as_i64().filter(|n| (range.0..=range.1).contains(n))
}

/// Builds the settings from the stored values. A missing name keeps its default. A stored value that is not valid
/// (it can only come from an edited database) is logged and replaced by its default, so the daemon keeps running.
pub fn from_stored(stored: &HashMap<String, String>) -> ServerSettings {
    let d = defaults();
    ServerSettings {
        screen_idle_minutes: stored_int(stored, SCREEN_IDLE_MINUTES, i64::from(d.screen_idle_minutes), |n| {
            (SCREEN_IDLE_RANGE.0..=SCREEN_IDLE_RANGE.1).contains(&n)
        }) as u32,
        max_running_agents: stored_int(stored, MAX_RUNNING_AGENTS, i64::from(d.max_running_agents), |n| {
            n == 0 || (MAX_RUNNING_RANGE.0..=MAX_RUNNING_RANGE.1).contains(&n)
        }) as u32,
        backup_every_hours: stored_int(stored, BACKUP_EVERY_HOURS, i64::from(d.backup_every_hours), |n| {
            BACKUP_EVERY_HOURS_VALUES.contains(&n)
        }) as u32,
        backup_keep: stored_int(stored, BACKUP_KEEP, i64::from(d.backup_keep), |n| {
            (BACKUP_KEEP_RANGE.0..=BACKUP_KEEP_RANGE.1).contains(&n)
        }) as u32,
        auto_update: stored
            .get(AUTO_UPDATE)
            .and_then(|s| AutoUpdate::parse(s))
            .unwrap_or(d.auto_update),
        update_channel: d.update_channel,
        default_approval_mode: stored
            .get(DEFAULT_APPROVAL_MODE)
            .and_then(|s| ApprovalMode::parse(s))
            .unwrap_or(d.default_approval_mode),
        phone_access: stored
            .get(PHONE_ACCESS)
            .and_then(|s| PhoneMode::parse(s))
            .unwrap_or(d.phone_access),
        phone_port: stored_int(stored, PHONE_PORT, i64::from(d.phone_port), |n| {
            (PHONE_PORT_RANGE.0..=PHONE_PORT_RANGE.1).contains(&n)
        }) as u16,
    }
}

fn stored_int(stored: &HashMap<String, String>, key: &str, default: i64, ok: impl Fn(i64) -> bool) -> i64 {
    match stored.get(key) {
        None => default,
        Some(text) => match text.parse::<i64>() {
            Ok(n) if ok(n) => n,
            _ => {
                tracing::warn!(
                    setting = key,
                    value = text,
                    "stored server setting is not valid: using the default"
                );
                default
            }
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn patch(value: Value) -> Map<String, Value> {
        value.as_object().cloned().expect("an object")
    }

    fn refused(value: Value) -> Invalid {
        check_patch(&patch(value)).expect_err("refused")
    }

    #[test]
    fn defaults_are_the_behavior_before_the_settings() {
        let d = defaults();
        assert_eq!(d.screen_idle_ms(), 30 * 60 * 1000);
        assert_eq!(d.turn_limit(), usize::MAX);
        assert_eq!(d.backup_every_ms(), 24 * HOUR_MS);
        assert_eq!(d.backup_keep, 14);
        assert_eq!(d.auto_update, AutoUpdate::Notify);
        assert_eq!(d.default_approval_mode, ApprovalMode::Risky);
        assert_eq!(
            d.phone_access,
            PhoneMode::Off,
            "a phone can reach nothing until the owner says so"
        );
        assert_eq!(d.phone_port, 7879);
        assert_eq!(from_stored(&HashMap::new()), d);
    }

    #[test]
    fn get_shows_every_name_with_its_value_and_the_defaults() {
        let json = defaults_json();
        let obj = json.as_object().unwrap();
        assert_eq!(obj.len(), KEYS.len());
        for key in KEYS {
            assert!(obj.contains_key(key), "{key} is missing");
        }
        assert_eq!(obj[SCREEN_IDLE_MINUTES], json!(30));
        assert_eq!(obj[AUTO_UPDATE], json!("notify"));
        assert_eq!(obj[UPDATE_CHANNEL], json!("stable"));
        assert_eq!(obj[DEFAULT_APPROVAL_MODE], json!("risky"));
    }

    #[test]
    fn valid_values_are_accepted_and_written_as_text() {
        let changes = check_patch(&patch(json!({
            "screen_idle_minutes": 240,
            "max_running_agents": 0,
            "backup_every_hours": 168,
            "backup_keep": 3,
            "auto_update": "install",
            "update_channel": "stable",
            "default_approval_mode": "always",
            "phone_access": "tailscale",
            "phone_port": 7900
        })))
        .unwrap();
        assert_eq!(changes.len(), 9);
        assert!(changes.contains(&(SCREEN_IDLE_MINUTES, "240".to_string())));
        assert!(changes.contains(&(AUTO_UPDATE, "install".to_string())));
        let mut stored = HashMap::new();
        for (k, v) in changes {
            stored.insert(k.to_string(), v);
        }
        let s = from_stored(&stored);
        assert_eq!(s.screen_idle_minutes, 240);
        assert_eq!(s.backup_every_hours, 168);
        assert_eq!(s.default_approval_mode, ApprovalMode::Always);
        assert_eq!(s.auto_update, AutoUpdate::Install);
        assert_eq!(s.phone_access, PhoneMode::Tailscale);
        assert_eq!(s.phone_port, 7900);
        assert!(check_patch(&patch(json!({"max_running_agents": 50}))).is_ok());
        assert!(check_patch(&patch(json!({"screen_idle_minutes": 5}))).is_ok());
        assert!(check_patch(&patch(json!({"backup_every_hours": 6}))).is_ok());
        assert!(check_patch(&patch(json!({}))).unwrap().is_empty());
    }

    #[test]
    fn invalid_values_name_the_field() {
        for (value, field) in [
            (json!({"screen_idle_minutes": 4}), "screen_idle_minutes"),
            (json!({"screen_idle_minutes": 241}), "screen_idle_minutes"),
            (json!({"screen_idle_minutes": "30"}), "screen_idle_minutes"),
            (json!({"max_running_agents": 51}), "max_running_agents"),
            (json!({"max_running_agents": -1}), "max_running_agents"),
            (json!({"backup_every_hours": 5}), "backup_every_hours"),
            (json!({"backup_keep": 2}), "backup_keep"),
            (json!({"backup_keep": 61}), "backup_keep"),
            (json!({"auto_update": "always"}), "auto_update"),
            (json!({"update_channel": "nightly"}), "update_channel"),
            (json!({"default_approval_mode": "ask"}), "default_approval_mode"),
            (json!({"phone_access": "wan"}), "phone_access"),
            (json!({"phone_access": true}), "phone_access"),
            (json!({"phone_port": 80}), "phone_port"),
            (json!({"phone_port": 65536}), "phone_port"),
            (json!({"phone_port": "7879"}), "phone_port"),
            (json!({"no_such_setting": 1}), "no_such_setting"),
        ] {
            let e = refused(value.clone());
            assert_eq!(e.field, field, "{value}");
            assert!(!e.reason.is_empty());
        }
    }

    #[test]
    fn beta_channel_is_refused_with_a_reason() {
        let e = refused(json!({"update_channel": "beta"}));
        assert_eq!(e.field, "update_channel");
        assert!(e.reason.contains("beta channel is not available"), "{}", e.reason);
    }

    #[test]
    fn a_bad_value_anywhere_refuses_the_whole_patch() {
        let e = refused(json!({"screen_idle_minutes": 60, "backup_keep": 1}));
        assert_eq!(e.field, "backup_keep");
    }

    #[test]
    fn a_bad_stored_value_falls_back_to_the_default() {
        let mut stored = HashMap::new();
        stored.insert(SCREEN_IDLE_MINUTES.to_string(), "9999".to_string());
        stored.insert(AUTO_UPDATE.to_string(), "weekly".to_string());
        stored.insert(BACKUP_KEEP.to_string(), "7".to_string());
        stored.insert(PHONE_ACCESS.to_string(), "everyone".to_string());
        stored.insert(PHONE_PORT.to_string(), "22".to_string());
        let s = from_stored(&stored);
        assert_eq!(
            s.phone_access,
            PhoneMode::Off,
            "a bad stored value never opens the daemon"
        );
        assert_eq!(s.phone_port, 7879);
        assert_eq!(s.screen_idle_minutes, 30);
        assert_eq!(s.auto_update, AutoUpdate::Notify);
        assert_eq!(s.backup_keep, 7);
    }
}
