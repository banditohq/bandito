//! Workspace rows: where an agent's CLI runs (see docs/ARCHITECTURE.md#workspaces).
//! Docker itself lives in `crate::workspace`.

use super::{Store, new_id, now_ms};
use crate::workspace::{WorkspaceError, check_mount};
use anyhow::Result;
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

/// The built-in workspace: the server's own user environment. Always present.
pub const SHARED_WORKSPACE: &str = "shared";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceKind {
    Shared,
    Container,
}

impl WorkspaceKind {
    pub fn as_str(self) -> &'static str {
        match self {
            WorkspaceKind::Shared => "shared",
            WorkspaceKind::Container => "container",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "shared" => WorkspaceKind::Shared,
            "container" => WorkspaceKind::Container,
            _ => return None,
        })
    }
}

/// Network of a container workspace. `none` has no network at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Network {
    #[default]
    Internet,
    #[serde(rename = "none")]
    Offline,
}

impl Network {
    pub fn as_str(self) -> &'static str {
        match self {
            Network::Internet => "internet",
            Network::Offline => "none",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "internet" => Network::Internet,
            "none" => Network::Offline,
            _ => return None,
        })
    }
}

/// A host folder shown inside a container. The target is where it appears there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mount {
    pub host: String,
    pub target: String,
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub kind: WorkspaceKind,
    /// Container image; `None` = the image Bandito builds (see `workspace::default_image_tag`).
    pub image: Option<String>,
    pub cpus: Option<f64>,
    pub memory_mb: Option<u32>,
    pub network: Network,
    /// Folders the user added. The agents' own folders are added at start (see `workspace::mounts_for`).
    pub mounts: Vec<Mount>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewWorkspace {
    pub name: String,
    pub kind: WorkspaceKind,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub cpus: Option<f64>,
    #[serde(default)]
    pub memory_mb: Option<u32>,
    #[serde(default)]
    pub network: Network,
    #[serde(default)]
    pub mounts: Vec<Mount>,
}

/// Fields to change; `None` leaves a field as is. For nullable fields, `Some(None)` clears them.
#[derive(Debug, Clone, Default)]
pub struct WorkspacePatch {
    pub name: Option<String>,
    pub image: Option<Option<String>>,
    pub cpus: Option<Option<f64>>,
    pub memory_mb: Option<Option<u32>>,
    pub network: Option<Network>,
    pub mounts: Option<Vec<Mount>>,
}

/// Checks the name and the container settings of a workspace as it would be stored.
/// The shared workspace has no container settings at all.
fn check(w: &Workspace) -> Result<(), WorkspaceError> {
    let name = w.name.trim();
    if name.is_empty() || name.chars().count() > 64 {
        return Err(WorkspaceError::Invalid("workspace name must be 1–64 characters".into()));
    }
    match w.kind {
        WorkspaceKind::Shared => {
            if w.image.is_some() || w.cpus.is_some() || w.memory_mb.is_some() || !w.mounts.is_empty() {
                return Err(WorkspaceError::Invalid(
                    "the shared workspace has no container settings".into(),
                ));
            }
            if w.network != Network::Internet {
                return Err(WorkspaceError::Invalid(
                    "the shared workspace always has its network".into(),
                ));
            }
        }
        WorkspaceKind::Container => {
            if let Some(cpus) = w.cpus
                && !(0.1..=64.0).contains(&cpus)
            {
                return Err(WorkspaceError::Invalid("cpus must be between 0.1 and 64".into()));
            }
            if let Some(mb) = w.memory_mb
                && !(64..=262_144).contains(&mb)
            {
                return Err(WorkspaceError::Invalid(
                    "memory must be between 64 and 262144 MB".into(),
                ));
            }
            if let Some(image) = &w.image
                && (image.trim().is_empty() || image.contains(char::is_whitespace))
            {
                return Err(WorkspaceError::Invalid("image must be a name without spaces".into()));
            }
            for m in &w.mounts {
                check_mount(m)?;
            }
        }
    }
    Ok(())
}

const COLS: &str = "id, name, kind, image, cpus, memory_mb, network, mounts, created_at";

fn from_row(r: &Row) -> rusqlite::Result<Workspace> {
    let kind: String = r.get(2)?;
    let network: String = r.get(6)?;
    let mounts: String = r.get(7)?;
    Ok(Workspace {
        id: r.get(0)?,
        name: r.get(1)?,
        // The CHECK constraint keeps other values out; a container is the safer reading of an unknown one.
        kind: WorkspaceKind::parse(&kind).unwrap_or(WorkspaceKind::Container),
        image: r.get(3)?,
        cpus: r.get(4)?,
        memory_mb: r.get::<_, Option<i64>>(5)?.map(|v| v.clamp(0, u32::MAX as i64) as u32),
        network: Network::parse(&network).unwrap_or_default(),
        mounts: serde_json::from_str(&mounts)
            .map_err(|e| rusqlite::Error::FromSqlConversionFailure(7, rusqlite::types::Type::Text, Box::new(e)))?,
        created_at: r.get(8)?,
    })
}

impl Store {
    pub fn workspace_create(&self, w: NewWorkspace) -> Result<Workspace> {
        let ws = Workspace {
            id: new_id(),
            name: w.name.trim().to_string(),
            kind: w.kind,
            image: w.image.map(|i| i.trim().to_string()),
            cpus: w.cpus,
            memory_mb: w.memory_mb,
            network: w.network,
            mounts: w.mounts,
            created_at: now_ms(),
        };
        check(&ws)?;
        self.conn().execute(
            "INSERT INTO workspaces (id, name, kind, image, cpus, memory_mb, network, mounts, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                ws.id,
                ws.name,
                ws.kind.as_str(),
                ws.image,
                ws.cpus,
                ws.memory_mb.map(i64::from),
                ws.network.as_str(),
                serde_json::to_string(&ws.mounts)?,
                ws.created_at
            ],
        )?;
        Ok(ws)
    }

    pub fn workspace_get(&self, id: &str) -> Result<Option<Workspace>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM workspaces WHERE id = ?1"), [id], from_row)
            .optional()?)
    }

    /// Oldest first, so the shared workspace comes first.
    pub fn workspace_list(&self) -> Result<Vec<Workspace>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!("SELECT {COLS} FROM workspaces ORDER BY created_at, id"))?;
        let rows = stmt.query_map([], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn workspace_update(&self, id: &str, p: WorkspacePatch) -> Result<Workspace> {
        let mut w = self
            .workspace_get(id)?
            .ok_or_else(|| WorkspaceError::NotFound(id.to_string()))?;
        if let Some(v) = p.name {
            w.name = v.trim().to_string();
        }
        if let Some(v) = p.image {
            w.image = v.map(|i| i.trim().to_string());
        }
        if let Some(v) = p.cpus {
            w.cpus = v;
        }
        if let Some(v) = p.memory_mb {
            w.memory_mb = v;
        }
        if let Some(v) = p.network {
            w.network = v;
        }
        if let Some(v) = p.mounts {
            w.mounts = v;
        }
        check(&w)?;
        self.conn().execute(
            "UPDATE workspaces SET name=?2, image=?3, cpus=?4, memory_mb=?5, network=?6, mounts=?7 WHERE id=?1",
            params![
                w.id,
                w.name,
                w.image,
                w.cpus,
                w.memory_mb.map(i64::from),
                w.network.as_str(),
                serde_json::to_string(&w.mounts)?
            ],
        )?;
        Ok(w)
    }

    /// Deletes an empty container workspace. The shared one and any with agents are refused.
    pub fn workspace_delete(&self, id: &str) -> Result<()> {
        if id == SHARED_WORKSPACE {
            return Err(WorkspaceError::Builtin.into());
        }
        if self.workspace_get(id)?.is_none() {
            return Err(WorkspaceError::NotFound(id.to_string()).into());
        }
        let agents = self.workspace_agent_ids(id)?;
        if !agents.is_empty() {
            return Err(WorkspaceError::NotEmpty(agents.len()).into());
        }
        self.conn().execute("DELETE FROM workspaces WHERE id=?1", [id])?;
        Ok(())
    }

    /// Ids of the agents that run in a workspace, oldest first.
    pub fn workspace_agent_ids(&self, id: &str) -> Result<Vec<String>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT id FROM agents WHERE workspace_id = ?1 ORDER BY created_at")?;
        let rows = stmt.query_map([id], |r| r.get(0))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::RuntimeKind;
    use crate::store::{AgentPatch, ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::workspace::WorkspaceError;

    fn new_ws(name: &str) -> NewWorkspace {
        NewWorkspace {
            name: name.into(),
            kind: WorkspaceKind::Container,
            image: None,
            cpus: Some(1.5),
            memory_mb: Some(1024),
            network: Network::Offline,
            mounts: vec![Mount {
                host: "/srv/data".into(),
                target: "/srv/data".into(),
                read_only: true,
            }],
        }
    }

    fn new_agent(name: &str) -> NewAgent {
        NewAgent {
            name: name.into(),
            role: String::new(),
            runtime: RuntimeKind::Claude,
            model: None,
            cwd: "/tmp".into(),
            approval_mode: ApprovalMode::Risky,
            system_prompt: None,
            effort: None,
            memory_mode: MemoryMode::Smart,
            context_budget: None,
        }
    }

    fn reason(err: &anyhow::Error) -> &'static str {
        err.downcast_ref::<WorkspaceError>().expect("a WorkspaceError").reason()
    }

    #[test]
    fn crud_round_trip() {
        let s = Store::open_in_memory().unwrap();
        let w = s.workspace_create(new_ws("Scout box")).unwrap();
        assert_eq!(w.kind, WorkspaceKind::Container);
        assert_eq!(w.network, Network::Offline);
        assert_eq!(w.mounts.len(), 1);
        assert_eq!(s.workspace_get(&w.id).unwrap().unwrap(), w);

        let names: Vec<String> = s.workspace_list().unwrap().into_iter().map(|w| w.name).collect();
        assert_eq!(names, vec!["Shared".to_string(), "Scout box".to_string()]);

        let patched = s
            .workspace_update(
                &w.id,
                WorkspacePatch {
                    name: Some("Watch".into()),
                    cpus: Some(Some(2.0)),
                    memory_mb: Some(None),
                    network: Some(Network::Internet),
                    mounts: Some(Vec::new()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(patched.name, "Watch");
        assert_eq!(patched.cpus, Some(2.0));
        assert_eq!(patched.memory_mb, None);
        assert_eq!(patched.network, Network::Internet);
        assert!(patched.mounts.is_empty());
        assert_eq!(patched.created_at, w.created_at);
    }

    #[test]
    fn shared_is_built_in_and_cannot_be_changed_or_deleted() {
        let s = Store::open_in_memory().unwrap();
        let shared = s.workspace_get(SHARED_WORKSPACE).unwrap().unwrap();
        assert_eq!(shared.kind, WorkspaceKind::Shared);
        assert!(shared.mounts.is_empty());

        let err = s
            .workspace_update(
                SHARED_WORKSPACE,
                WorkspacePatch {
                    cpus: Some(Some(1.0)),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert_eq!(reason(&err), "invalid");

        let err = s.workspace_delete(SHARED_WORKSPACE).unwrap_err();
        assert_eq!(reason(&err), "builtin");
    }

    #[test]
    fn delete_needs_an_empty_container_workspace() {
        let s = Store::open_in_memory().unwrap();
        let w = s.workspace_create(new_ws("Scout box")).unwrap();
        let a = s.agent_create_in(new_agent("Scout"), &w.id).unwrap();
        assert_eq!(a.workspace_id, w.id);
        assert_eq!(s.workspace_agent_ids(&w.id).unwrap(), vec![a.id.clone()]);

        let err = s.workspace_delete(&w.id).unwrap_err();
        assert_eq!(reason(&err), "not_empty");
        assert!(s.workspace_get(&w.id).unwrap().is_some());

        s.agent_delete(&a.id).unwrap();
        s.workspace_delete(&w.id).unwrap();
        assert!(s.workspace_get(&w.id).unwrap().is_none());
    }

    #[test]
    fn container_limits_and_mounts_are_checked_on_create() {
        let s = Store::open_in_memory().unwrap();
        let mut bad_cpus = new_ws("Box");
        bad_cpus.cpus = Some(0.0);
        assert_eq!(reason(&s.workspace_create(bad_cpus).unwrap_err()), "invalid");
        let mut bad_memory = new_ws("Box");
        bad_memory.memory_mb = Some(8);
        assert_eq!(reason(&s.workspace_create(bad_memory).unwrap_err()), "invalid");
        let mut shared_with_limits = new_ws("Box");
        shared_with_limits.kind = WorkspaceKind::Shared;
        assert_eq!(reason(&s.workspace_create(shared_with_limits).unwrap_err()), "invalid");
        assert_eq!(s.workspace_list().unwrap().len(), 1, "nothing was stored");
    }

    #[test]
    fn unknown_workspace_is_not_found() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(reason(&s.workspace_delete("nope").unwrap_err()), "not_found");
        let err = s.workspace_update("nope", WorkspacePatch::default()).unwrap_err();
        assert_eq!(reason(&err), "not_found");
    }

    #[test]
    fn agents_start_in_shared_and_can_move() {
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new_agent("Forge")).unwrap();
        assert_eq!(a.workspace_id, SHARED_WORKSPACE);
        assert_eq!(s.agent_get(&a.id).unwrap().unwrap().workspace_id, SHARED_WORKSPACE);

        let w = s.workspace_create(new_ws("Box")).unwrap();
        let moved = s
            .agent_update(
                &a.id,
                AgentPatch {
                    workspace_id: Some(w.id.clone()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(moved.workspace_id, w.id);
        assert_eq!(s.workspace_agent_ids(SHARED_WORKSPACE).unwrap(), Vec::<String>::new());
    }
}
