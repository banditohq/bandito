//! The integrations table: MCP servers for the agents (see docs/ARCHITECTURE.md#integrations). The rules for
//! what a row may hold are in [`crate::integrations`]; this file stores and reads rows.

use super::{Store, new_id, now_ms};
use anyhow::{Result, bail};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IntegrationKind {
    /// A program the daemon starts, which speaks MCP over its stdin and stdout.
    Stdio,
    /// A server reached over HTTP (streamable HTTP, MCP 2025-03-26 and later).
    Http,
}

impl IntegrationKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stdio => "stdio",
            Self::Http => "http",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "stdio" => Some(Self::Stdio),
            "http" => Some(Self::Http),
            _ => None,
        }
    }
}

/// How an http integration signs in. `Oauth` rows carry no token in their headers: the daemon holds the tokens
/// (see `mcp_oauth.rs`) and puts the `Authorization` header in when a session starts.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IntegrationAuth {
    /// Whatever its headers and environment hold.
    #[default]
    None,
    /// Signed in through the service's own page in the browser.
    Oauth,
}

impl IntegrationAuth {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Oauth => "oauth",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "none" => Some(Self::None),
            "oauth" => Some(Self::Oauth),
            _ => None,
        }
    }
}

/// What the agents may do with an integration's tools (docs/ARCHITECTURE.md#tool-permissions).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolMode {
    /// Every tool runs as the agent's approval mode says.
    #[default]
    All,
    /// A tool that reads runs; a tool that changes something (or that is not known to read) is refused.
    ReadOnly,
    /// A tool that reads runs; a tool that changes something waits for the owner's yes.
    ConfirmWrites,
}

impl ToolMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::ReadOnly => "read_only",
            Self::ConfirmWrites => "confirm_writes",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "all" => Some(Self::All),
            "read_only" => Some(Self::ReadOnly),
            "confirm_writes" => Some(Self::ConfirmWrites),
            _ => None,
        }
    }
}

/// The owner's word on one tool, over the mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolOverride {
    Allow,
    Ask,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Integration {
    pub id: String,
    pub name: String,
    pub kind: IntegrationKind,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub url: Option<String>,
    /// Environment of a stdio server. A value is a literal or `secret:<name>`.
    pub env: BTreeMap<String, String>,
    /// Headers of an http server. A value is a literal or `secret:<name>`.
    pub headers: BTreeMap<String, String>,
    pub enabled: bool,
    pub created_at: i64,
    /// `oauth` for a service the owner signed in to in the browser; `none` for the rest.
    #[serde(default)]
    pub auth: IntegrationAuth,
    /// What the agents may do with its tools.
    #[serde(default)]
    pub tool_mode: ToolMode,
    /// The owner's word per tool name; it wins over `tool_mode`.
    #[serde(default)]
    pub tool_overrides: BTreeMap<String, ToolOverride>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewIntegration {
    pub name: String,
    pub kind: IntegrationKind,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default = "yes")]
    pub enabled: bool,
    #[serde(default)]
    pub auth: IntegrationAuth,
}

fn yes() -> bool {
    true
}

/// Fields to change; `None` leaves a field as is. Nullable fields take `Some(None)` to clear.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct IntegrationPatch {
    pub name: Option<String>,
    pub kind: Option<IntegrationKind>,
    /// `null` clears it; a missing field leaves it.
    #[serde(default, deserialize_with = "present_or_null")]
    pub command: Option<Option<String>>,
    pub args: Option<Vec<String>>,
    #[serde(default, deserialize_with = "present_or_null")]
    pub url: Option<Option<String>>,
    pub env: Option<BTreeMap<String, String>>,
    pub headers: Option<BTreeMap<String, String>>,
    pub enabled: Option<bool>,
    pub tool_mode: Option<ToolMode>,
    /// Replaces the whole map.
    pub tool_overrides: Option<BTreeMap<String, ToolOverride>>,
}

/// A field that is present (even as `null`) reads as `Some`, so `null` can clear it.
fn present_or_null<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(d).map(Some)
}

const COLS: &str =
    "id, name, kind, command, args, url, env, headers, enabled, created_at, auth, tool_mode, tool_overrides";

fn json_column<T: serde::de::DeserializeOwned + Default>(r: &Row, i: usize) -> rusqlite::Result<T> {
    let text: String = r.get(i)?;
    Ok(serde_json::from_str(&text).unwrap_or_default())
}

fn from_row(r: &Row) -> rusqlite::Result<Integration> {
    let kind: String = r.get(2)?;
    Ok(Integration {
        id: r.get(0)?,
        name: r.get(1)?,
        kind: IntegrationKind::parse(&kind).unwrap_or(IntegrationKind::Stdio),
        command: r.get(3)?,
        args: json_column(r, 4)?,
        url: r.get(5)?,
        env: json_column(r, 6)?,
        headers: json_column(r, 7)?,
        enabled: r.get::<_, i64>(8)? != 0,
        created_at: r.get(9)?,
        auth: IntegrationAuth::parse(&r.get::<_, String>(10)?).unwrap_or_default(),
        tool_mode: ToolMode::parse(&r.get::<_, String>(11)?).unwrap_or_default(),
        tool_overrides: json_column(r, 12)?,
    })
}

impl Store {
    pub fn integration_list(&self) -> Result<Vec<Integration>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!("SELECT {COLS} FROM integrations ORDER BY created_at, id"))?;
        let rows = stmt.query_map([], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn integration_get(&self, id: &str) -> Result<Option<Integration>> {
        Ok(self
            .conn()
            .query_row(
                &format!("SELECT {COLS} FROM integrations WHERE id = ?1"),
                [id],
                from_row,
            )
            .optional()?)
    }

    /// Insert. A name already taken is an error (the name is unique).
    pub fn integration_create(&self, n: NewIntegration) -> Result<Integration> {
        let row = Integration {
            id: new_id(),
            name: n.name,
            kind: n.kind,
            command: n.command,
            args: n.args,
            url: n.url,
            env: n.env,
            headers: n.headers,
            enabled: n.enabled,
            created_at: now_ms(),
            auth: n.auth,
            tool_mode: ToolMode::All,
            tool_overrides: BTreeMap::new(),
        };
        // A service of the catalog starts with its changing tools behind a question; an own one is left as it is.
        let row = Integration {
            tool_mode: crate::integrations::default_tool_mode(&row),
            ..row
        };
        let res = self.conn().execute(
            "INSERT INTO integrations (id, name, kind, command, args, url, env, headers, enabled, created_at, auth,
             tool_mode, tool_overrides)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                row.id,
                row.name,
                row.kind.as_str(),
                row.command,
                serde_json::to_string(&row.args)?,
                row.url,
                serde_json::to_string(&row.env)?,
                serde_json::to_string(&row.headers)?,
                i64::from(row.enabled),
                row.created_at,
                row.auth.as_str(),
                row.tool_mode.as_str(),
                serde_json::to_string(&row.tool_overrides)?,
            ],
        );
        match res {
            Ok(_) => Ok(row),
            Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
                bail!("an integration named '{}' already exists", row.name)
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Apply the patch. Error if missing or if the new name is taken.
    pub fn integration_update(&self, id: &str, p: IntegrationPatch) -> Result<Integration> {
        let Some(mut row) = self.integration_get(id)? else {
            bail!("no integration {id}");
        };
        if let Some(v) = p.name {
            row.name = v;
        }
        if let Some(v) = p.kind {
            row.kind = v;
        }
        if let Some(v) = p.command {
            row.command = v;
        }
        if let Some(v) = p.args {
            row.args = v;
        }
        if let Some(v) = p.url {
            row.url = v;
        }
        if let Some(v) = p.env {
            row.env = v;
        }
        if let Some(v) = p.headers {
            row.headers = v;
        }
        if let Some(v) = p.enabled {
            row.enabled = v;
        }
        if let Some(v) = p.tool_mode {
            row.tool_mode = v;
        }
        if let Some(v) = p.tool_overrides {
            row.tool_overrides = v;
        }
        let res = self.conn().execute(
            "UPDATE integrations SET name = ?2, kind = ?3, command = ?4, args = ?5, url = ?6, env = ?7,
             headers = ?8, enabled = ?9, tool_mode = ?10, tool_overrides = ?11 WHERE id = ?1",
            params![
                row.id,
                row.name,
                row.kind.as_str(),
                row.command,
                serde_json::to_string(&row.args)?,
                row.url,
                serde_json::to_string(&row.env)?,
                serde_json::to_string(&row.headers)?,
                i64::from(row.enabled),
                row.tool_mode.as_str(),
                serde_json::to_string(&row.tool_overrides)?,
            ],
        );
        match res {
            Ok(_) => Ok(row),
            Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
                bail!("an integration named '{}' already exists", row.name)
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Set how the row signs in. `false` if there is no such row.
    pub fn integration_set_auth(&self, id: &str, auth: IntegrationAuth) -> Result<bool> {
        let n = self.conn().execute(
            "UPDATE integrations SET auth = ?2 WHERE id = ?1",
            params![id, auth.as_str()],
        )?;
        Ok(n > 0)
    }

    /// Delete the row and drop its id from every agent's list. `false` if there was no such row.
    pub fn integration_delete(&self, id: &str) -> Result<bool> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let n = tx.execute("DELETE FROM integrations WHERE id = ?1", [id])?;
        let lists: Vec<(String, String)> = {
            let mut stmt = tx.prepare("SELECT id, integrations FROM agents WHERE integrations IS NOT NULL")?;
            let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        for (agent, json) in lists {
            let mut ids: Vec<String> = serde_json::from_str(&json).unwrap_or_default();
            let before = ids.len();
            ids.retain(|i| i != id);
            if ids.len() != before {
                tx.execute(
                    "UPDATE agents SET integrations = ?2 WHERE id = ?1",
                    params![agent, serde_json::to_string(&ids)?],
                )?;
            }
        }
        tx.commit()?;
        Ok(n > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new(name: &str) -> NewIntegration {
        NewIntegration {
            name: name.into(),
            kind: IntegrationKind::Stdio,
            command: Some("npx".into()),
            args: vec!["-y".into(), "pkg".into()],
            url: None,
            env: BTreeMap::from([("TOKEN".to_string(), "secret:github".to_string())]),
            headers: BTreeMap::new(),
            enabled: true,
            auth: Default::default(),
        }
    }

    fn test_agent(name: &str) -> crate::store::NewAgent {
        crate::store::NewAgent {
            name: name.into(),
            role: "builder".into(),
            runtime: crate::runtime::RuntimeKind::Claude,
            model: None,
            cwd: "/tmp".into(),
            approval_mode: crate::store::ApprovalMode::Risky,
            system_prompt: None,
            effort: None,
            memory_mode: crate::store::MemoryMode::Smart,
            context_budget: None,
            fallback_runtime: None,
            fallback_model: None,
            use_personal_settings: false,
            avatar: None,
            capabilities: None,
            integrations: None,
        }
    }

    #[test]
    fn a_catalog_service_starts_asking_and_an_own_one_starts_open() {
        let s = Store::open_in_memory().unwrap();
        // Named like a template of the catalog.
        let catalog = s.integration_create(new("fetch")).unwrap();
        assert_eq!(catalog.tool_mode, ToolMode::ConfirmWrites);
        assert!(catalog.tool_overrides.is_empty());
        let own = s.integration_create(new("my-own-tool")).unwrap();
        assert_eq!(own.tool_mode, ToolMode::All);
        // What was stored is what is read back.
        assert_eq!(
            s.integration_get(&catalog.id).unwrap().unwrap().tool_mode,
            ToolMode::ConfirmWrites
        );
    }

    #[test]
    fn the_mode_and_the_words_for_tools_are_patched_and_kept() {
        let s = Store::open_in_memory().unwrap();
        let a = s.integration_create(new("my-own-tool")).unwrap();
        let patched = s
            .integration_update(
                &a.id,
                IntegrationPatch {
                    tool_mode: Some(ToolMode::ReadOnly),
                    tool_overrides: Some(BTreeMap::from([("delete".to_string(), ToolOverride::Deny)])),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(patched.tool_mode, ToolMode::ReadOnly);
        assert_eq!(s.integration_get(&a.id).unwrap().unwrap(), patched);
        // A patch that names neither leaves them.
        let renamed = s
            .integration_update(
                &a.id,
                IntegrationPatch {
                    enabled: Some(false),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(renamed.tool_mode, ToolMode::ReadOnly);
        assert_eq!(renamed.tool_overrides.get("delete"), Some(&ToolOverride::Deny));
        // The words are replaced as a whole.
        let cleared = s
            .integration_update(
                &a.id,
                IntegrationPatch {
                    tool_overrides: Some(BTreeMap::new()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(cleared.tool_overrides.is_empty());
    }

    #[test]
    fn create_list_get_round_trips_json_columns() {
        let s = Store::open_in_memory().unwrap();
        let a = s.integration_create(new("fetch")).unwrap();
        assert_eq!(s.integration_get(&a.id).unwrap(), Some(a.clone()));
        assert_eq!(s.integration_list().unwrap(), vec![a.clone()]);
        assert_eq!(a.env.get("TOKEN").map(String::as_str), Some("secret:github"));
    }

    #[test]
    fn names_are_unique() {
        let s = Store::open_in_memory().unwrap();
        s.integration_create(new("fetch")).unwrap();
        assert!(s.integration_create(new("fetch")).is_err());
    }

    #[test]
    fn update_patches_and_clears_nullable_fields() {
        let s = Store::open_in_memory().unwrap();
        let a = s.integration_create(new("fetch")).unwrap();
        let b = s
            .integration_update(
                &a.id,
                IntegrationPatch {
                    command: Some(None),
                    enabled: Some(false),
                    args: Some(vec![]),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!((b.command, b.enabled, b.args.len()), (None, false, 0));
        assert_eq!(b.name, "fetch", "untouched fields stay");
        assert!(s.integration_update("missing", IntegrationPatch::default()).is_err());
    }

    #[test]
    fn delete_removes_the_id_from_agent_lists() {
        let s = Store::open_in_memory().unwrap();
        let a = s.integration_create(new("fetch")).unwrap();
        let b = s.integration_create(new("other")).unwrap();
        let agent = s.agent_create(test_agent("Forge")).unwrap();
        s.agent_update(
            &agent.id,
            crate::store::AgentPatch {
                integrations: Some(Some(vec![a.id.clone(), b.id.clone()])),
                ..Default::default()
            },
        )
        .unwrap();
        assert!(s.integration_delete(&a.id).unwrap());
        assert!(!s.integration_delete(&a.id).unwrap());
        let left = s.agent_get(&agent.id).unwrap().unwrap();
        assert_eq!(left.integrations, Some(vec![b.id]));
    }
}
