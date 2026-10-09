//! Each agent's own folder on the server: a memory index, notes, a journal and
//! files the agent makes for itself. See docs/ARCHITECTURE.md#memory-and-context.

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
/// `fallback` (the daemon's data dir) is used when there is no home directory,
/// so the root is never a relative path.
pub fn default_agents_root(fallback: &Path) -> PathBuf {
    agents_root_from(std::env::var_os("BANDITO_AGENTS_DIR"), dirs::home_dir(), fallback)
}

fn agents_root_from(env: Option<OsString>, home: Option<PathBuf>, fallback: &Path) -> PathBuf {
    match (env, home) {
        (Some(dir), _) => PathBuf::from(dir),
        (None, Some(home)) => home.join("bandito").join("agents"),
        (None, None) => fallback.join("agents"),
    }
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
    let base = slug(name);
    let dir = pick_dir(root, &base, agent_id)?;
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
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

fn pick_dir(root: &Path, base: &str, agent_id: &str) -> Result<PathBuf> {
    for n in 1..=MAX_NAME_TRIES {
        let name = if n == 1 {
            base.to_string()
        } else {
            format!("{base}-{n}")
        };
        let dir = root.join(name);
        if is_free_for(&dir, agent_id)? {
            return Ok(dir);
        }
    }
    bail!("no free folder for {base} under {}", root.display())
}

/// A folder is usable when it does not exist, when it already belongs to this
/// agent, or when it is an empty folder nobody has marked.
fn is_free_for(dir: &Path, agent_id: &str) -> Result<bool> {
    if !dir.exists() {
        return Ok(true);
    }
    if !dir.is_dir() {
        return Ok(false);
    }
    match std::fs::read_to_string(dir.join(MARKER)) {
        Ok(owner) => Ok(owner.trim() == agent_id),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(std::fs::read_dir(dir)?.next().is_none()),
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
