//! Secrets: values the daemon hands to agents as environment variables. They
//! never leave the daemon: list and RPC answers carry only a name and a tail.
//! See docs/ARCHITECTURE.md#secrets.

use super::{Store, now_ms};
use anyhow::{Context, Result, bail};
use rusqlite::params;
use serde::Serialize;

/// Largest value, in bytes.
pub const MAX_VALUE_BYTES: usize = 65_536;
/// Values at least this many characters long show their last few characters in lists.
const TAIL_MIN_CHARS: usize = 12;
const TAIL_CHARS: usize = 4;
/// Agent id that stands for every agent.
pub const ALL_AGENTS: &str = "*";
/// Names the child process cannot have: they would change how the CLI or the loader runs.
const RESERVED_NAMES: &[&str] = &["PATH", "HOME", "USER", "SHELL", "LD_PRELOAD", "LD_LIBRARY_PATH"];
const RESERVED_PREFIXES: &[&str] = &["DYLD_", "BANDITO_"];

/// A secret without its value. The only form in which secrets leave the store.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SecretInfo {
    pub name: String,
    /// Last 4 characters of the value if it is 12 characters or longer, else empty.
    pub tail: String,
    /// Agent ids that get the secret; `["*"]` for every agent, `[]` for none.
    pub agents: Vec<String>,
    pub updated_at: i64,
}

/// A valid name matches `^[A-Z_][A-Z0-9_]{0,63}$` and is not reserved.
pub fn check_name(name: &str) -> Result<()> {
    let mut chars = name.chars();
    let first_ok = matches!(chars.next(), Some(c) if c.is_ascii_uppercase() || c == '_');
    let rest_ok = name.len() <= 64 && chars.all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_');
    if !first_ok || !rest_ok {
        bail!("secret name must match [A-Z_][A-Z0-9_]{{0,63}}");
    }
    if RESERVED_NAMES.contains(&name) || RESERVED_PREFIXES.iter().any(|p| name.starts_with(p)) {
        bail!("{name} is reserved");
    }
    Ok(())
}

/// A value is 1 to [`MAX_VALUE_BYTES`] bytes and has no NUL byte.
pub fn check_value(value: &str) -> Result<()> {
    if value.is_empty() || value.len() > MAX_VALUE_BYTES {
        bail!("secret value must be 1 to {MAX_VALUE_BYTES} bytes");
    }
    if value.contains('\0') {
        bail!("secret value must not contain NUL");
    }
    Ok(())
}

/// Agent ids, or `["*"]` alone. `[]` is allowed: the secret reaches no agent yet.
pub fn check_agents(agents: &[String]) -> Result<()> {
    if agents.len() > 1 && agents.iter().any(|a| a == ALL_AGENTS) {
        bail!("\"*\" must be the only agent");
    }
    if agents.iter().any(|a| a.trim().is_empty()) {
        bail!("agent ids must not be empty");
    }
    Ok(())
}

fn tail_of(value: &str) -> String {
    if value.chars().count() < TAIL_MIN_CHARS {
        return String::new();
    }
    let start = value.char_indices().rev().nth(TAIL_CHARS - 1).map_or(0, |(i, _)| i);
    value[start..].to_string()
}

fn parse_agents(json: &str) -> Result<Vec<String>> {
    serde_json::from_str(json).context("secret agents are not a JSON array")
}

impl Store {
    /// Create or replace a secret. Checks the input here too, not only in the RPC layer.
    pub fn secret_set(&self, name: &str, value: &str, agents: &[String]) -> Result<SecretInfo> {
        check_name(name)?;
        check_value(value)?;
        check_agents(agents)?;
        let agents_json = serde_json::to_string(agents)?;
        let now = now_ms();
        self.conn().execute(
            "INSERT INTO secrets (name, value, agents, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)
             ON CONFLICT(name) DO UPDATE SET
                value = excluded.value,
                agents = excluded.agents,
                updated_at = excluded.updated_at",
            params![name, value, agents_json, now],
        )?;
        Ok(SecretInfo {
            name: name.to_string(),
            tail: tail_of(value),
            agents: agents.to_vec(),
            updated_at: now,
        })
    }

    /// Remove a secret. `false` when there was none.
    pub fn secret_delete(&self, name: &str) -> Result<bool> {
        let n = self.conn().execute("DELETE FROM secrets WHERE name = ?1", [name])?;
        Ok(n > 0)
    }

    /// All secrets without their values, sorted by name.
    pub fn secret_list(&self) -> Result<Vec<SecretInfo>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT name, value, agents, updated_at FROM secrets ORDER BY name")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (name, value, agents, updated_at) = row?;
            out.push(SecretInfo {
                name,
                tail: tail_of(&value),
                agents: parse_agents(&agents)?,
                updated_at,
            });
        }
        Ok(out)
    }

    /// The `(name, value)` pairs an agent's session gets: the secrets listing its id or `"*"`.
    /// Sorted by name.
    pub fn secrets_for_agent(&self, agent_id: &str) -> Result<Vec<(String, String)>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT name, value, agents FROM secrets ORDER BY name")?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (name, value, agents) = row?;
            let listed = parse_agents(&agents)?;
            if listed.iter().any(|a| a == ALL_AGENTS || a == agent_id) {
                out.push((name, value));
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Store;

    fn all() -> Vec<String> {
        vec!["*".into()]
    }

    fn only(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn names_follow_the_env_var_shape() {
        for ok in ["A", "_X", "OPENAI_API_KEY", "K1"] {
            check_name(ok).unwrap_or_else(|e| panic!("{ok}: {e:#}"));
        }
        let longest = format!("A{}", "B".repeat(63));
        assert_eq!(longest.len(), 64);
        check_name(&longest).unwrap();

        let too_long = format!("A{}", "B".repeat(64));
        let bad = ["", "lower", "Mixed", "1ABC", "A-B", "A.B", " A", too_long.as_str()];
        for name in bad {
            assert!(check_name(name).is_err(), "{name:?} must be refused");
        }
    }

    #[test]
    fn reserved_names_are_refused() {
        let reserved = [
            "PATH",
            "HOME",
            "USER",
            "SHELL",
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "BANDITO_HOME",
            "BANDITO_AGENTS_DIR",
        ];
        for name in reserved {
            assert!(check_name(name).is_err(), "{name} must be refused");
        }
    }

    #[test]
    fn values_are_1_to_65536_bytes_without_nul() {
        check_value("x").unwrap();
        check_value("ключ").unwrap();
        check_value(&"x".repeat(65536)).unwrap();
        assert!(check_value("").is_err());
        assert!(check_value(&"x".repeat(65537)).is_err());
        assert!(check_value("a\0b").is_err());
    }

    #[test]
    fn set_stores_and_list_hides_the_value() {
        let s = Store::open_in_memory().unwrap();
        let info = s
            .secret_set("OPENAI_API_KEY", "sk-live-0123456789abcdef", &all())
            .unwrap();
        assert_eq!(info.name, "OPENAI_API_KEY");
        assert_eq!(info.tail, "cdef");
        assert_eq!(info.agents, all());

        let list = s.secret_list().unwrap();
        assert_eq!(list.len(), 1);
        let json = serde_json::to_string(&list).unwrap();
        assert!(!json.contains("sk-live"), "value leaked into the list: {json}");
        assert!(!json.contains("0123456789"), "value leaked into the list: {json}");
    }

    #[test]
    fn tail_is_shown_only_for_values_of_12_chars_or_more() {
        let s = Store::open_in_memory().unwrap();
        s.secret_set("A_TWELVE", "abcdefghijkl", &all()).unwrap();
        s.secret_set("A_ELEVEN", "abcdefghijk", &all()).unwrap();
        s.secret_set("A_SHORT", "ab", &all()).unwrap();
        s.secret_set("A_UNI", &"ё".repeat(12), &all()).unwrap();

        let tails: Vec<(String, String)> = s.secret_list().unwrap().into_iter().map(|i| (i.name, i.tail)).collect();
        assert_eq!(
            tails,
            vec![
                ("A_ELEVEN".to_string(), String::new()),
                ("A_SHORT".to_string(), String::new()),
                ("A_TWELVE".to_string(), "ijkl".to_string()),
                ("A_UNI".to_string(), "ёёёё".to_string()),
            ]
        );
    }

    #[test]
    fn set_replaces_value_and_agents_and_keeps_one_row() {
        let s = Store::open_in_memory().unwrap();
        s.secret_set("K_ONE", "first-value-1234", &all()).unwrap();
        let info = s.secret_set("K_ONE", "second-value-9876", &only(&["a1"])).unwrap();
        assert_eq!(info.tail, "9876");
        assert_eq!(info.agents, only(&["a1"]));
        assert_eq!(s.secret_list().unwrap().len(), 1);
        assert_eq!(
            s.secrets_for_agent("a1").unwrap(),
            vec![("K_ONE".to_string(), "second-value-9876".to_string())]
        );
        assert!(s.secrets_for_agent("other").unwrap().is_empty());
    }

    #[test]
    fn secrets_for_agent_matches_listed_ids_and_star() {
        let s = Store::open_in_memory().unwrap();
        s.secret_set("ALL_KEYS", "value-for-everyone", &all()).unwrap();
        s.secret_set("ONLY_A", "value-for-a-only", &only(&["agent-a"])).unwrap();
        s.secret_set("NOBODY", "value-for-nobody", &[]).unwrap();

        let names =
            |id: &str| -> Vec<String> { s.secrets_for_agent(id).unwrap().into_iter().map(|(n, _)| n).collect() };
        assert_eq!(names("agent-a"), vec!["ALL_KEYS", "ONLY_A"]);
        assert_eq!(names("agent-b"), vec!["ALL_KEYS"]);
        let pair = s.secrets_for_agent("agent-a").unwrap();
        assert!(pair.contains(&("ONLY_A".to_string(), "value-for-a-only".to_string())));
    }

    #[test]
    fn delete_reports_whether_it_removed_something() {
        let s = Store::open_in_memory().unwrap();
        s.secret_set("GONE", "value-to-delete", &all()).unwrap();
        assert!(s.secret_delete("GONE").unwrap());
        assert!(!s.secret_delete("GONE").unwrap());
        assert!(s.secrets_for_agent("any").unwrap().is_empty());
    }

    #[test]
    fn agents_are_agent_ids_or_a_lone_star() {
        let s = Store::open_in_memory().unwrap();
        s.secret_set("OK_NOBODY", "value-1234567", &[]).unwrap();
        assert!(s.secret_set("BAD_MIXED", "value-1234567", &only(&["*", "a"])).is_err());
        assert!(s.secret_set("BAD_BLANK", "value-1234567", &only(&[""])).is_err());
        assert!(s.secret_set("PATH", "value-1234567", &all()).is_err());
        assert!(s.secret_set("OK_EMPTY_VALUE", "", &all()).is_err());
        let names: Vec<String> = s.secret_list().unwrap().into_iter().map(|i| i.name).collect();
        assert_eq!(names, vec!["OK_NOBODY"], "refused secrets must not be stored");
    }

    #[test]
    fn migration_keeps_rows_of_the_unused_0001_table() {
        // Migration 0001 already created `secrets(name, value)`. The new columns must be added to it, not replace it.
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        for sql in &crate::store::MIGRATIONS[..3] {
            conn.execute_batch(sql).unwrap();
        }
        conn.pragma_update(None, "user_version", 3).unwrap();
        conn.execute(
            "INSERT INTO secrets (name, value) VALUES ('OLD_KEY', 'old-value-123456')",
            [],
        )
        .unwrap();

        let s = Store::init(conn).unwrap();
        assert!(s.secrets_for_agent("any").unwrap().is_empty());
        let list = s.secret_list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].name, "OLD_KEY");
        assert!(
            list[0].agents.is_empty(),
            "an old row goes to no agent until it is set again"
        );
    }
}
