use super::{Store, new_id, now_ms};
use anyhow::Result;
use rusqlite::{Row, params};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleAction {
    Allow,
    Ask,
    Deny,
}

impl RuleAction {
    pub fn as_str(self) -> &'static str {
        match self {
            RuleAction::Allow => "allow",
            RuleAction::Ask => "ask",
            RuleAction::Deny => "deny",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "allow" => RuleAction::Allow,
            "ask" => RuleAction::Ask,
            "deny" => RuleAction::Deny,
            _ => return None,
        })
    }
}

/// A user rule. `agent_id = None` means it applies to every agent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Rule {
    pub id: String,
    pub agent_id: Option<String>,
    /// Glob over the call title: `*` = any run of chars, case-sensitive,
    /// whole string must match (see `policy::glob_match`).
    pub pattern: String,
    pub action: RuleAction,
    pub created_at: i64,
}

const COLS: &str = "id, agent_id, pattern, action, created_at";

/// An unknown action in the DB is treated as `Ask`: the human decides.
fn from_row(r: &Row) -> rusqlite::Result<Rule> {
    let action: String = r.get(3)?;
    Ok(Rule {
        id: r.get(0)?,
        agent_id: r.get(1)?,
        pattern: r.get(2)?,
        action: RuleAction::parse(&action).unwrap_or(RuleAction::Ask),
        created_at: r.get(4)?,
    })
}

impl Store {
    /// Adds a rule. If the same (agent_id, pattern) exists, replace its action
    /// instead of adding a duplicate, and return the updated rule.
    pub fn rule_set(&self, agent_id: Option<&str>, pattern: &str, action: RuleAction) -> Result<Rule> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let updated = tx.execute(
            "UPDATE rules SET action = ?3 WHERE agent_id IS ?1 AND pattern = ?2",
            params![agent_id, pattern, action.as_str()],
        )?;
        let rule = if updated > 0 {
            tx.query_row(
                &format!(
                    "SELECT {COLS} FROM rules WHERE agent_id IS ?1 AND pattern = ?2 ORDER BY created_at, id LIMIT 1"
                ),
                params![agent_id, pattern],
                from_row,
            )?
        } else {
            let rule = Rule {
                id: new_id(),
                agent_id: agent_id.map(str::to_owned),
                pattern: pattern.to_owned(),
                action,
                created_at: now_ms(),
            };
            tx.execute(
                "INSERT INTO rules (id, agent_id, pattern, action, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    rule.id,
                    rule.agent_id,
                    rule.pattern,
                    rule.action.as_str(),
                    rule.created_at
                ],
            )?;
            rule
        };
        tx.commit()?;
        Ok(rule)
    }

    /// Rules that apply to `agent_id`: its own first (newest first), then
    /// global ones (newest first). With `None`: only global rules.
    pub fn rule_list(&self, agent_id: Option<&str>) -> Result<Vec<Rule>> {
        let conn = self.conn();
        let mut out = Vec::new();
        if let Some(agent) = agent_id {
            let mut stmt = conn.prepare(&format!(
                "SELECT {COLS} FROM rules WHERE agent_id = ?1 ORDER BY created_at DESC, id DESC"
            ))?;
            let own: Vec<Rule> = stmt.query_map([agent], from_row)?.collect::<rusqlite::Result<_>>()?;
            out.extend(own);
        }
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM rules WHERE agent_id IS NULL ORDER BY created_at DESC, id DESC"
        ))?;
        let global: Vec<Rule> = stmt.query_map([], from_row)?.collect::<rusqlite::Result<_>>()?;
        out.extend(global);
        Ok(out)
    }

    pub fn rule_delete(&self, id: &str) -> Result<bool> {
        let n = self.conn().execute("DELETE FROM rules WHERE id = ?1", [id])?;
        Ok(n > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set_created_at(s: &Store, id: &str, ts: i64) {
        s.conn()
            .execute("UPDATE rules SET created_at = ?2 WHERE id = ?1", params![id, ts])
            .unwrap();
    }

    #[test]
    fn set_same_agent_and_pattern_updates_in_place() {
        let s = Store::open_in_memory().unwrap();
        let first = s.rule_set(Some("agent-1"), "git push*", RuleAction::Deny).unwrap();
        let second = s.rule_set(Some("agent-1"), "git push*", RuleAction::Allow).unwrap();
        assert_eq!(second.id, first.id);
        assert_eq!(second.created_at, first.created_at);
        assert_eq!(second.action, RuleAction::Allow);

        let list = s.rule_list(Some("agent-1")).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].action, RuleAction::Allow);
    }

    #[test]
    fn set_global_rule_twice_updates_in_place() {
        // NULL agent_id: plain `=` would never match, so this checks `IS`.
        let s = Store::open_in_memory().unwrap();
        let first = s.rule_set(None, "rm -rf*", RuleAction::Ask).unwrap();
        let second = s.rule_set(None, "rm -rf*", RuleAction::Deny).unwrap();
        assert_eq!(second.id, first.id);
        assert_eq!(second.agent_id, None);
        let list = s.rule_list(None).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].action, RuleAction::Deny);
    }

    #[test]
    fn global_and_agent_rule_with_same_pattern_are_distinct() {
        let s = Store::open_in_memory().unwrap();
        let g = s.rule_set(None, "*deploy*", RuleAction::Ask).unwrap();
        let a = s.rule_set(Some("agent-1"), "*deploy*", RuleAction::Allow).unwrap();
        assert_ne!(g.id, a.id);
        assert_eq!(s.rule_list(None).unwrap().len(), 1);
        assert_eq!(s.rule_list(Some("agent-1")).unwrap().len(), 2);
    }

    #[test]
    fn list_agent_rules_first_then_global_each_newest_first() {
        let s = Store::open_in_memory().unwrap();
        let g_old = s.rule_set(None, "g1", RuleAction::Ask).unwrap();
        let g_new = s.rule_set(None, "g2", RuleAction::Deny).unwrap();
        let a_old = s.rule_set(Some("a"), "p1", RuleAction::Allow).unwrap();
        let a_new = s.rule_set(Some("a"), "p2", RuleAction::Deny).unwrap();
        let other = s.rule_set(Some("b"), "p3", RuleAction::Allow).unwrap();
        set_created_at(&s, &g_old.id, 10);
        set_created_at(&s, &g_new.id, 20);
        set_created_at(&s, &a_old.id, 30);
        set_created_at(&s, &a_new.id, 40);
        set_created_at(&s, &other.id, 50);

        let for_a: Vec<String> = s.rule_list(Some("a")).unwrap().into_iter().map(|r| r.id).collect();
        assert_eq!(
            for_a,
            vec![a_new.id.clone(), a_old.id.clone(), g_new.id.clone(), g_old.id.clone()]
        );

        let global: Vec<String> = s.rule_list(None).unwrap().into_iter().map(|r| r.id).collect();
        assert_eq!(global, vec![g_new.id, g_old.id]);
    }

    #[test]
    fn list_ties_on_created_at_break_by_id_desc() {
        let s = Store::open_in_memory().unwrap();
        let r1 = s.rule_set(Some("a"), "p1", RuleAction::Allow).unwrap();
        let r2 = s.rule_set(Some("a"), "p2", RuleAction::Allow).unwrap();
        set_created_at(&s, &r1.id, 7);
        set_created_at(&s, &r2.id, 7);

        let mut want = vec![r1.id.clone(), r2.id.clone()];
        want.sort();
        want.reverse();
        let got: Vec<String> = s.rule_list(Some("a")).unwrap().into_iter().map(|r| r.id).collect();
        assert_eq!(got, want);
    }

    #[test]
    fn unknown_db_action_maps_to_ask() {
        let s = Store::open_in_memory().unwrap();
        let r = s.rule_set(None, "x*", RuleAction::Deny).unwrap();
        s.conn()
            .execute("UPDATE rules SET action = 'weird' WHERE id = ?1", params![r.id])
            .unwrap();
        assert_eq!(s.rule_list(None).unwrap()[0].action, RuleAction::Ask);
    }

    #[test]
    fn delete_true_then_false() {
        let s = Store::open_in_memory().unwrap();
        let r = s.rule_set(Some("agent-1"), "git push*", RuleAction::Deny).unwrap();
        assert!(s.rule_delete(&r.id).unwrap());
        assert!(!s.rule_delete(&r.id).unwrap());
        assert!(s.rule_list(Some("agent-1")).unwrap().is_empty());
    }
}
