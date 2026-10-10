//! Each agent's own folder on the server: a memory index, notes, a journal and
//! files the agent makes for itself. See docs/ARCHITECTURE.md#memory-and-context.

use crate::store::Store;
use anyhow::{Context, Result, bail};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

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

/// The daemon's data folder as `main` resolved it (`--home`, else `BANDITO_HOME`, else `~/.bandito`).
static DATA_HOME: OnceLock<PathBuf> = OnceLock::new();

/// Records the data folder for the whole process. Called once by `main`, before anything reads it.
pub fn set_data_home(home: &Path) {
    let _ = DATA_HOME.set(home.to_path_buf());
}

/// Bandito's data folder: the one `main` set, else `$BANDITO_HOME`, else `~/.bandito`.
pub fn data_home() -> PathBuf {
    data_home_from(
        DATA_HOME.get().map(PathBuf::as_path),
        std::env::var_os("BANDITO_HOME"),
        dirs::home_dir(),
    )
}

/// The rule behind [`data_home`]: `configured` first, then `BANDITO_HOME`, then `<user home>/.bandito`.
pub fn data_home_from(configured: Option<&Path>, env_home: Option<OsString>, user_home: Option<PathBuf>) -> PathBuf {
    if let Some(dir) = configured {
        return dir.to_path_buf();
    }
    if let Some(dir) = env_home {
        return PathBuf::from(dir);
    }
    match user_home {
        Some(user_home) => user_home.join(".bandito"),
        None => PathBuf::from(".bandito"),
    }
}

/// Root for all agent folders: `$BANDITO_AGENTS_DIR`, else `<home>/agents` when the daemon was given its own
/// `--home` (so a second daemon does not write into the first one's folders), else `~/bandito/agents`.
/// `home` is the daemon's data folder; `home_given` says whether `--home` was passed.
pub fn default_agents_root(home: &Path, home_given: bool) -> PathBuf {
    agents_root_from(
        std::env::var_os("BANDITO_AGENTS_DIR"),
        dirs::home_dir(),
        home,
        home_given,
    )
}

/// The rule behind [`default_agents_root`]. A relative `BANDITO_AGENTS_DIR` is ignored: the folders must not
/// depend on the daemon's working directory.
fn agents_root_from(env: Option<OsString>, user_home: Option<PathBuf>, home: &Path, home_given: bool) -> PathBuf {
    let custom = env.map(PathBuf::from).filter(|dir| {
        let absolute = dir.is_absolute();
        if !absolute {
            tracing::warn!(dir = %dir.display(), "BANDITO_AGENTS_DIR is not absolute; using the default agents folder");
        }
        absolute
    });
    let default_home = user_home.as_ref().map(|user_home| user_home.join(".bandito"));
    match (custom, user_home) {
        (Some(dir), _) => dir,
        // Next to the data folder, never inside it: agents may not touch Bandito's own files, so a folder under the
        // data folder would be one they cannot write (`/srv/second` → `/srv/second-agents`).
        (None, Some(_)) if home_given && Some(home) != default_home.as_deref() => {
            let home = std::path::absolute(home).unwrap_or_else(|_| home.to_path_buf());
            let name = home
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "bandito".into());
            home.with_file_name(format!("{name}-agents"))
        }
        (None, Some(user_home)) => user_home.join("bandito").join("agents"),
        (None, None) => home.join("agents"),
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

/// The Latin spelling of a lowercase Cyrillic letter (a simple GOST-like table, Ukrainian letters included).
/// `""` drops the letter (ъ, ь). `None` for anything else.
fn cyrillic_latin(c: char) -> Option<&'static str> {
    Some(match c {
        'а' => "a",
        'б' => "b",
        'в' => "v",
        'г' => "g",
        'д' => "d",
        'е' => "e",
        'ё' => "yo",
        'ж' => "zh",
        'з' => "z",
        'и' => "i",
        'й' => "y",
        'к' => "k",
        'л' => "l",
        'м' => "m",
        'н' => "n",
        'о' => "o",
        'п' => "p",
        'р' => "r",
        'с' => "s",
        'т' => "t",
        'у' => "u",
        'ф' => "f",
        'х' => "kh",
        'ц' => "ts",
        'ч' => "ch",
        'ш' => "sh",
        'щ' => "shch",
        'ъ' | 'ь' => "",
        'ы' => "y",
        'э' => "e",
        'ю' => "yu",
        'я' => "ya",
        'і' => "i",
        'ї' => "yi",
        'є' => "ye",
        'ґ' => "g",
        _ => return None,
    })
}

/// A folder name for an agent: lowercase ASCII letters and digits. Cyrillic is transliterated, other letters
/// are dropped, any other character becomes a single `-`, no leading or trailing `-`. Empty → `agent`.
pub fn slug(name: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for upper in name.chars() {
        for c in upper.to_lowercase() {
            if c.is_ascii_alphanumeric() {
                out.push(c);
                dash = false;
            } else if let Some(latin) = cyrillic_latin(c) {
                if !latin.is_empty() {
                    out.push_str(latin);
                    dash = false;
                }
            } else if c.is_alphabetic() {
                // A letter with no Latin form is dropped.
            } else if !dash {
                out.push('-');
                dash = true;
            }
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
        assert_eq!(slug("Ёж 2"), "yozh-2");
        assert_eq!(slug("Тестер"), "tester");
        assert_eq!(slug("!!!"), "agent");
        assert_eq!(slug("  Forge__Builder  "), "forge-builder");
        assert_eq!(slug("A--B"), "a-b");
        assert_eq!(slug("Scout-3"), "scout-3");
        assert_eq!(slug(""), "agent");
    }

    #[test]
    fn slug_transliterates_cyrillic() {
        assert_eq!(slug("Щи"), "shchi");
        assert_eq!(slug("Объём"), "obyom", "ъ and ь are dropped");
        assert_eq!(slug("Юля Яна"), "yulya-yana");
        assert_eq!(slug("Їжак Єнот Ґудзик"), "yizhak-yenot-gudzik");
        assert_eq!(slug("Хлеб ЦЕХ Чай"), "khleb-tsekh-chay");
    }

    #[test]
    fn slug_drops_other_letters_and_keeps_symbols_as_separators() {
        assert_eq!(slug("aéb"), "ab", "a letter without a table entry is dropped");
        assert_eq!(slug("Café 2"), "caf-2");
        assert_eq!(slug("🦝🦝🦝"), "agent", "emoji only falls back to agent");
        assert_eq!(slug("Night🦝Owl"), "night-owl");
    }

    #[test]
    fn root_comes_from_env_or_home() {
        assert_eq!(
            agents_root_from(
                Some("/srv/agents".into()),
                Some("/home/u".into()),
                Path::new("/var/b"),
                false
            ),
            PathBuf::from("/srv/agents")
        );
        assert_eq!(
            agents_root_from(None, Some("/home/u".into()), Path::new("/var/b"), false),
            PathBuf::from("/home/u/bandito/agents")
        );
        assert_eq!(
            agents_root_from(None, None, Path::new("/var/b"), false),
            PathBuf::from("/var/b/agents")
        );
    }

    #[test]
    fn relative_env_root_is_ignored() {
        assert_eq!(
            agents_root_from(
                Some("relative/agents".into()),
                Some("/home/u".into()),
                Path::new("/var/b"),
                false
            ),
            PathBuf::from("/home/u/bandito/agents")
        );
    }

    #[test]
    fn a_given_home_moves_the_agents_root_with_it() {
        // A second daemon with its own --home must not write into the first one's folder.
        assert_eq!(
            agents_root_from(None, Some("/home/u".into()), Path::new("/srv/second"), true),
            PathBuf::from("/srv/second-agents")
        );
        // BANDITO_AGENTS_DIR still wins over the home.
        assert_eq!(
            agents_root_from(
                Some("/srv/agents".into()),
                Some("/home/u".into()),
                Path::new("/srv/second"),
                true
            ),
            PathBuf::from("/srv/agents")
        );
        // --home pointing at the default ~/.bandito keeps the default folder.
        assert_eq!(
            agents_root_from(None, Some("/home/u".into()), Path::new("/home/u/.bandito"), true),
            PathBuf::from("/home/u/bandito/agents")
        );
        // Without --home (BANDITO_HOME or default) nothing changes.
        assert_eq!(
            agents_root_from(None, Some("/home/u".into()), Path::new("/srv/second"), false),
            PathBuf::from("/home/u/bandito/agents")
        );
    }

    #[test]
    fn data_home_comes_from_the_flag_first() {
        assert_eq!(
            data_home_from(Some(Path::new("/flag")), Some("/env".into()), Some("/home/u".into())),
            PathBuf::from("/flag")
        );
        assert_eq!(
            data_home_from(None, Some("/env".into()), Some("/home/u".into())),
            PathBuf::from("/env")
        );
        assert_eq!(
            data_home_from(None, None, Some("/home/u".into())),
            PathBuf::from("/home/u/.bandito")
        );
        assert_eq!(data_home_from(None, None, None), PathBuf::from(".bandito"));
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
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
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
