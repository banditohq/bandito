//! Each agent's own folder on the server: a memory index, notes, a journal and
//! files the agent makes for itself. See docs/ARCHITECTURE.md#memory-and-context.

use crate::store::Store;
use anyhow::{Context, Result, bail};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// Marks a folder as belonging to one agent: its file holds the agent id.
const MARKER: &str = ".bandito-agent";
/// Folder names tried before giving up when a slug is taken: `slug`, `slug-2`, …
const MAX_NAME_TRIES: u32 = 100;
const SUBDIRS: [&str; 3] = ["notes", "journal", "files"];

/// First read by the agent in every chapter. `{name}` is replaced with the agent's name.
const MEMORY_TEMPLATE: &str = "\
<!-- Read this first in every new session. Keep it under 200 lines; put details in notes/. -->
# Memory — {name}

## About the user
<!-- Who the user is, how they like to work, what to call them. -->

## Current work
<!-- What is in progress right now, and where it stands. -->

## Open tasks
<!-- Things promised or pending, with dates if known. -->

## Decisions
<!-- Choices made and why. Details go to notes/. -->

## Notes index
<!-- One line per file in notes/: - notes/<topic>.md — what it holds. -->
";

/// Root for all agent folders: `$BANDITO_AGENTS_DIR`, else `~/bandito/agents`.
/// `fallback` (the daemon's data dir) is used when there is no home directory.
/// A relative `BANDITO_AGENTS_DIR` is ignored: the folders must not depend on the
/// daemon's working directory.
pub fn default_agents_root(fallback: &Path) -> PathBuf {
    agents_root_from(std::env::var_os("BANDITO_AGENTS_DIR"), dirs::home_dir(), fallback)
}

fn agents_root_from(env: Option<OsString>, home: Option<PathBuf>, fallback: &Path) -> PathBuf {
    let custom = env.map(PathBuf::from).filter(|dir| {
        let absolute = dir.is_absolute();
        if !absolute {
            tracing::warn!(dir = %dir.display(), "BANDITO_AGENTS_DIR is not absolute; using the default agents folder");
        }
        absolute
    });
    match (custom, home) {
        (Some(dir), _) => dir,
        (None, Some(home)) => home.join("bandito").join("agents"),
        (None, None) => fallback.join("agents"),
    }
}

/// Give every agent without a folder one (agents made before folders existed).
/// Returns how many were created; a failure is logged and the agent is skipped.
pub fn backfill(store: &Store, root: &Path) -> usize {
    let agents = match store.agent_list() {
        Ok(agents) => agents,
        Err(e) => {
            tracing::warn!("agent folders: list agents: {e:#}");
            return 0;
        }
    };
    let mut created = 0;
    for agent in agents.iter().filter(|a| a.home_dir.is_none()) {
        let folder = ensure_agent_home(root, &agent.id, &agent.name).and_then(|dir| {
            store
                .agent_set_home(&agent.id, &dir.display().to_string())
                .map(|()| dir)
        });
        match folder {
            Ok(_) => created += 1,
            Err(e) => tracing::warn!(agent = %agent.id, "agent folder: {e:#}"),
        }
    }
    created
}

/// A folder name for an agent: lowercase ASCII letters and digits, other
/// characters become single `-`, no leading or trailing `-`. Empty → `agent`.
pub fn slug(name: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            dash = false;
        } else if !dash {
            out.push('-');
            dash = true;
        }
    }
    let s = out.trim_matches('-');
    if s.is_empty() {
        "agent".to_string()
    } else {
        s.to_string()
    }
}

/// Create (or reuse) the agent's folder under `root` and return its absolute path.
///
/// The folder is `root/<slug(name)>`, or `-2`, `-3`… when that folder belongs to
/// another agent. Calling it again for the same agent returns the same folder and
/// never overwrites `MEMORY.md`.
pub fn ensure_agent_home(root: &Path, agent_id: &str, name: &str) -> Result<PathBuf> {
    std::fs::create_dir_all(root).with_context(|| format!("create {}", root.display()))?;
    let dir = claim_dir(root, &slug(name), agent_id)?;
    for sub in SUBDIRS {
        let p = dir.join(sub);
        std::fs::create_dir_all(&p).with_context(|| format!("create {}", p.display()))?;
    }
    std::fs::write(dir.join(MARKER), agent_id).with_context(|| format!("write {MARKER}"))?;
    let memory = dir.join("MEMORY.md");
    if !memory.exists() {
        std::fs::write(&memory, MEMORY_TEMPLATE.replace("{name}", name.trim()))
            .with_context(|| format!("write {}", memory.display()))?;
    }
    restrict_to_owner(&dir)?;
    Ok(dir)
}

/// Create the agent's folder for the first free name, so that two agents never
/// share one. `create_dir` is atomic: when it reports the name taken, the folder
/// is reused only if its marker names this agent; otherwise the next name is tried.
fn claim_dir(root: &Path, base: &str, agent_id: &str) -> Result<PathBuf> {
    for n in 1..=MAX_NAME_TRIES {
        let name = if n == 1 {
            base.to_string()
        } else {
            format!("{base}-{n}")
        };
        let dir = root.join(name);
        match std::fs::create_dir(&dir) {
            Ok(()) => return Ok(dir),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                if owned_by(&dir, agent_id)? {
                    return Ok(dir);
                }
            }
            Err(e) => return Err(e).with_context(|| format!("create {}", dir.display())),
        }
    }
    bail!("no free folder for {base} under {}", root.display())
}

/// True when `dir` is a folder whose marker names `agent_id`.
fn owned_by(dir: &Path, agent_id: &str) -> Result<bool> {
    if !dir.is_dir() {
        return Ok(false);
    }
    match std::fs::read_to_string(dir.join(MARKER)) {
        Ok(owner) => Ok(owner.trim() == agent_id),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e).with_context(|| format!("read {}", dir.display())),
    }
}

#[cfg(unix)]
fn restrict_to_owner(dir: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .with_context(|| format!("chmod 700 {}", dir.display()))
}

#[cfg(not(unix))]
fn restrict_to_owner(_dir: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, MemoryMode, NewAgent};

    #[test]
    fn slug_cases() {
        assert_eq!(slug("Night Owl"), "night-owl");
        assert_eq!(slug("Ёж 2"), "2");
        assert_eq!(slug("!!!"), "agent");
        assert_eq!(slug("  Forge__Builder  "), "forge-builder");
        assert_eq!(slug("A--B"), "a-b");
        assert_eq!(slug("Scout-3"), "scout-3");
        assert_eq!(slug(""), "agent");
    }

    #[test]
    fn root_comes_from_env_or_home() {
        assert_eq!(
            agents_root_from(Some("/srv/agents".into()), Some("/home/u".into()), Path::new("/var/b")),
            PathBuf::from("/srv/agents")
        );
        assert_eq!(
            agents_root_from(None, Some("/home/u".into()), Path::new("/var/b")),
            PathBuf::from("/home/u/bandito/agents")
        );
        assert_eq!(
            agents_root_from(None, None, Path::new("/var/b")),
            PathBuf::from("/var/b/agents")
        );
    }

    #[test]
    fn relative_env_root_is_ignored() {
        assert_eq!(
            agents_root_from(
                Some("relative/agents".into()),
                Some("/home/u".into()),
                Path::new("/var/b")
            ),
            PathBuf::from("/home/u/bandito/agents")
        );
    }

    #[test]
    fn unmarked_empty_folder_is_not_taken_over() {
        let root = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("forge")).unwrap();
        let dir = ensure_agent_home(root.path(), "id-1", "Forge").unwrap();
        assert_eq!(dir, root.path().join("forge-2"));
    }

    fn add_agent(store: &Store, name: &str) -> crate::store::Agent {
        store
            .agent_create(NewAgent {
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
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
    }

    #[test]
    fn backfill_gives_folders_only_to_agents_without_one() {
        let root = tempfile::tempdir().unwrap();
        let store = Store::open_in_memory().unwrap();
        let old = add_agent(&store, "Night Owl");
        let done = add_agent(&store, "Forge");
        store.agent_set_home(&done.id, "/elsewhere/forge").unwrap();

        assert_eq!(backfill(&store, root.path()), 1);
        let dir = root.path().join("night-owl");
        assert_eq!(
            store.agent_get(&old.id).unwrap().unwrap().home_dir,
            Some(dir.display().to_string())
        );
        assert!(dir.join("MEMORY.md").is_file());
        assert_eq!(
            store.agent_get(&done.id).unwrap().unwrap().home_dir.as_deref(),
            Some("/elsewhere/forge"),
            "an existing folder is left alone"
        );
        assert_eq!(backfill(&store, root.path()), 0, "nothing left to do");
    }

    #[test]
    fn backfill_skips_agents_it_cannot_give_a_folder() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("not-a-dir");
        std::fs::write(&file, "x").unwrap();
        let store = Store::open_in_memory().unwrap();
        let agent = add_agent(&store, "Forge");

        assert_eq!(backfill(&store, &file), 0);
        assert_eq!(store.agent_get(&agent.id).unwrap().unwrap().home_dir, None);
    }

    #[test]
    fn creates_structure_and_template() {
        let root = tempfile::tempdir().unwrap();
        let dir = ensure_agent_home(root.path(), "id-1", "Night Owl").unwrap();

        assert!(dir.is_absolute());
        assert_eq!(dir, root.path().join("night-owl"));
        for sub in SUBDIRS {
            assert!(dir.join(sub).is_dir(), "{sub} missing");
        }
        assert_eq!(std::fs::read_to_string(dir.join(MARKER)).unwrap(), "id-1");
        let memory = std::fs::read_to_string(dir.join("MEMORY.md")).unwrap();
        assert!(memory.starts_with("<!-- Read this first in every new session."));
        assert!(memory.contains("# Memory — Night Owl\n"));
        for section in [
            "## About the user",
            "## Current work",
            "## Open tasks",
            "## Decisions",
            "## Notes index",
        ] {
            assert!(memory.contains(section), "{section} missing");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700);
        }
    }

    #[test]
    fn same_agent_gets_same_folder_and_keeps_memory() {
        let root = tempfile::tempdir().unwrap();
        let first = ensure_agent_home(root.path(), "id-1", "Night Owl").unwrap();
        std::fs::write(first.join("MEMORY.md"), "my own notes").unwrap();

        let again = ensure_agent_home(root.path(), "id-1", "Night Owl").unwrap();
        assert_eq!(again, first);
        assert_eq!(
            std::fs::read_to_string(again.join("MEMORY.md")).unwrap(),
            "my own notes"
        );
    }

    #[test]
    fn other_agents_folder_gets_a_suffix() {
        let root = tempfile::tempdir().unwrap();
        let first = ensure_agent_home(root.path(), "id-1", "Night Owl").unwrap();
        let second = ensure_agent_home(root.path(), "id-2", "night owl").unwrap();
        assert_eq!(first, root.path().join("night-owl"));
        assert_eq!(second, root.path().join("night-owl-2"));
        assert_eq!(std::fs::read_to_string(first.join(MARKER)).unwrap(), "id-1");
    }

    #[test]
    fn unmarked_non_empty_folder_is_not_taken_over() {
        let root = tempfile::tempdir().unwrap();
        let taken = root.path().join("forge");
        std::fs::create_dir_all(&taken).unwrap();
        std::fs::write(taken.join("someone-elses.txt"), "keep me").unwrap();

        let dir = ensure_agent_home(root.path(), "id-1", "Forge").unwrap();
        assert_eq!(dir, root.path().join("forge-2"));
        assert_eq!(
            std::fs::read_to_string(taken.join("someone-elses.txt")).unwrap(),
            "keep me"
        );
    }

    #[test]
    fn fails_when_root_is_a_file() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("not-a-dir");
        std::fs::write(&file, "x").unwrap();
        assert!(ensure_agent_home(&file, "id-1", "Forge").is_err());
    }
}
