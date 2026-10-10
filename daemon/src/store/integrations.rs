//! The integrations table: MCP servers for the agents (see docs/ARCHITECTURE.md#integrations). The rules for
//! what a row may hold are in [`crate::integrations`]; this file stores and reads rows.

use super::{Store, new_id, now_ms};
use anyhow::{Result, bail};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// A tool an integration's server listed at its last successful probe (see docs/ARCHITECTURE.md#integrations).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct IntegrationTool {
    pub name: String,
    pub title: Option<String>,
    pub description: Option<String>,
    /// The server's `readOnlyHint` annotation.
    pub read_only: bool,
    /// The server's `destructiveHint` annotation.
    pub destructive: bool,
    /// The tool's `inputSchema`; `None` when the server gave none or it was too large to keep.
    pub input_schema: Option<Value>,
    pub seen_at: i64,
}

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
}

/// A field that is present (even as `null`) reads as `Some`, so `null` can clear it.
fn present_or_null<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(d).map(Some)
}

const COLS: &str = "id, name, kind, command, args, url, env, headers, enabled, created_at, auth";

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
        };
        let res = self.conn().execute(
            "INSERT INTO integrations (id, name, kind, command, args, url, env, headers, enabled, created_at, auth)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
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
        let res = self.conn().execute(
            "UPDATE integrations SET name = ?2, kind = ?3, command = ?4, args = ?5, url = ?6, env = ?7,
             headers = ?8, enabled = ?9 WHERE id = ?1",
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
        tx.execute("DELETE FROM integration_tools WHERE integration_id = ?1", [id])?;
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

    /// Replaces the tools of an integration with the list of its latest successful probe: a tool it no longer
    /// lists is dropped. `false` (nothing written) when the integration does not exist, e.g. it was removed while
    /// the probe ran.
    pub fn integration_tools_replace(&self, integration_id: &str, tools: &[IntegrationTool]) -> Result<bool> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM integrations WHERE id = ?1)",
            [integration_id],
            |r| r.get(0),
        )?;
        if !exists {
            return Ok(false);
        }
        tx.execute(
            "DELETE FROM integration_tools WHERE integration_id = ?1",
            [integration_id],
        )?;
        for t in tools {
            tx.execute(
                "INSERT OR REPLACE INTO integration_tools
                    (integration_id, name, title, description, read_only, destructive, input_schema, seen_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    integration_id,
                    t.name,
                    t.title,
                    t.description,
                    t.read_only,
                    t.destructive,
                    t.input_schema.as_ref().map(Value::to_string),
                    t.seen_at,
                ],
            )?;
        }
        tx.commit()?;
        Ok(true)
    }

    /// The tools of an integration, by name. Empty when none was ever listed.
    pub fn integration_tools(&self, integration_id: &str) -> Result<Vec<IntegrationTool>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT name, title, description, read_only, destructive, input_schema, seen_at
             FROM integration_tools WHERE integration_id = ?1 ORDER BY name",
        )?;
        let rows = stmt.query_map([integration_id], |r| {
            let schema: Option<String> = r.get(5)?;
            Ok(IntegrationTool {
                name: r.get(0)?,
                title: r.get(1)?,
                description: r.get(2)?,
                read_only: r.get(3)?,
                destructive: r.get(4)?,
                input_schema: schema.and_then(|s| serde_json::from_str(&s).ok()),
                seen_at: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tool(name: &str, read_only: bool) -> IntegrationTool {
        IntegrationTool {
            name: name.into(),
            title: Some(format!("{name} title")),
            description: None,
            read_only,
            destructive: !read_only,
            input_schema: Some(serde_json::json!({ "type": "object" })),
            seen_at: 1,
        }
    }

    #[test]
    fn tools_are_replaced_per_integration_and_leave_with_it() {
        let store = Store::open_in_memory().unwrap();
        let a = store.integration_create(new("a")).unwrap();
        let b = store.integration_create(new("b")).unwrap();
        assert!(
            store
                .integration_tools_replace(&a.id, &[tool("search", true), tool("delete", false)])
                .unwrap()
        );
        assert!(store.integration_tools_replace(&b.id, &[tool("other", true)]).unwrap());
        // A later probe that no longer lists `delete` drops it; `b` keeps its own.
        assert!(store.integration_tools_replace(&a.id, &[tool("search", true)]).unwrap());
        let names: Vec<String> = store
            .integration_tools(&a.id)
            .unwrap()
            .into_iter()
            .map(|t| t.name)
            .collect();
        assert_eq!(names, ["search"]);
        assert_eq!(store.integration_tools(&b.id).unwrap().len(), 1);
        // Removing `a` removes its tools and nothing of `b`.
        assert!(store.integration_delete(&a.id).unwrap());
        assert!(store.integration_tools(&a.id).unwrap().is_empty());
        assert_eq!(store.integration_tools(&b.id).unwrap().len(), 1);
    }

    #[test]
    fn annotations_and_schema_come_back_as_written() {
        let store = Store::open_in_memory().unwrap();
        let a = store.integration_create(new("a")).unwrap();
        let mut bare = tool("bare", false);
        bare.title = None;
        bare.input_schema = None;
        store
            .integration_tools_replace(&a.id, &[tool("read", true), bare.clone()])
            .unwrap();
        let got = store.integration_tools(&a.id).unwrap();
        let read = got.iter().find(|t| t.name == "read").unwrap();
        assert!(read.read_only && !read.destructive);
        assert_eq!(read.input_schema, Some(serde_json::json!({ "type": "object" })));
        assert_eq!(got.iter().find(|t| t.name == "bare"), Some(&bare));
    }

    #[test]
    fn tools_of_a_missing_integration_are_not_saved() {
        let store = Store::open_in_memory().unwrap();
        assert!(!store.integration_tools_replace("gone", &[tool("x", true)]).unwrap());
        assert!(store.integration_tools("gone").unwrap().is_empty());
    }

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
