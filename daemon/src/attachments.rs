//! Files the human attaches to a message. They are saved in a folder of the agent, where the agent can read
//! them: `<cwd>/.bandito/attachments/<YYYY-MM-DD>/`, or `<home>/files/attachments/<YYYY-MM-DD>/` when the agent
//! has no folder or the folder is Bandito's own data folder. See docs/ARCHITECTURE.md#replies-and-attachments.

use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

/// Largest file, after decoding, in bytes.
pub const MAX_BYTES: usize = 20 * 1024 * 1024;
/// Longest file name, in bytes.
const MAX_NAME_BYTES: usize = 200;
/// Tries for a free name (`name (2).ext` ... ) before giving up.
const MAX_SUFFIX: u32 = 10_000;

/// A file attached to a message: its path (what the agent reads), its name, size and mime type.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Attachment {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub mime: String,
}

/// Checks a file name from the client: no folders, no `..`, no control characters, not empty, not too long.
pub fn check_name(name: &str) -> Result<(), String> {
    let t = name.trim();
    if t.is_empty() {
        return Err("file name is empty".into());
    }
    if name.len() > MAX_NAME_BYTES {
        return Err(format!("file name is longer than {MAX_NAME_BYTES} bytes"));
    }
    if name.contains('/') || name.contains('\\') {
        return Err("file name must not contain / or \\".into());
    }
    if name.contains("..") {
        return Err("file name must not contain ..".into());
    }
    if name.starts_with('.') {
        return Err("file name must not start with a dot".into());
    }
    if name.chars().any(char::is_control) {
        return Err("file name must not contain control characters".into());
    }
    Ok(())
}

/// The mime type of a file, by its extension. Unknown extensions are `application/octet-stream`.
pub fn mime_of(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "txt" | "log" => "text/plain",
        "md" => "text/markdown",
        "csv" => "text/csv",
        "json" => "application/json",
        "zip" => "application/zip",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        _ => "application/octet-stream",
    }
}

/// The folders an agent's attachments live in, in order of preference, as `(anchor, root)`: the root is
/// `<cwd>/.bandito/attachments` or `<home>/files/attachments`, and the anchor is the folder it is in (the cwd or the
/// home). A folder that is Bandito's own data folder is never a root.
fn roots(cwd: &str, home: Option<&str>, data_home: &Path) -> Vec<(PathBuf, PathBuf)> {
    let mut out = Vec::new();
    if cwd.starts_with('/') {
        let root = Path::new(cwd).join(".bandito").join("attachments");
        if !root.starts_with(data_home) {
            out.push((PathBuf::from(cwd), root));
        }
    }
    if let Some(home) = home.filter(|h| h.starts_with('/')) {
        let root = Path::new(home).join("files").join("attachments");
        if !root.starts_with(data_home) {
            out.push((PathBuf::from(home), root));
        }
    }
    out
}

/// Whether `dir` and every folder between `anchor` and it is a real folder, not a link. The anchor itself is not
/// checked: it is the agent's own cwd or home, which may be reached through a link.
fn plain_below(anchor: &Path, dir: &Path) -> bool {
    let Ok(rel) = dir.strip_prefix(anchor) else {
        return false;
    };
    let mut cur = anchor.to_path_buf();
    for part in rel.components() {
        cur.push(part);
        if let Ok(meta) = std::fs::symlink_metadata(&cur)
            && meta.file_type().is_symlink()
        {
            return false;
        }
    }
    true
}

/// The folder the day's attachments are written into, created as needed. Only the first root is used. A folder on
/// the way that is a link is refused: nothing is written through a link.
pub fn folder_for_today(cwd: &str, home: Option<&str>, data_home: &Path, day: &str) -> Result<PathBuf, String> {
    let (anchor, root) = roots(cwd, home, data_home)
        .into_iter()
        .next()
        .ok_or_else(|| "this agent has no folder for attachments".to_string())?;
    let dir = root.join(day);
    if !plain_below(&anchor, &dir) {
        return Err("the attachment folder is a symbolic link; attachments are not saved through links".into());
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    if let Some(dot) = root.parent().filter(|d| d.file_name().is_some_and(|n| n == ".bandito")) {
        keep_out_of_git(dot);
    }
    Ok(dir)
}

/// Puts a `.gitignore` of `*` into the project's `.bandito` folder, so attachments (screenshots, documents) never end
/// up in the project's commits. Only a new file is written: one already there, or a link in its place, is left alone.
fn keep_out_of_git(dot: &Path) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dot.join(".gitignore"))
    {
        let _ = f.write_all(b"# Files sent to Bandito agents: not part of the project.\n*\n");
    }
}

/// Whether `path` is a file inside one of the agent's attachment folders (any day). Its folders must be real
/// folders, not links; and the file, with links followed, must be inside the real folder.
pub fn is_agent_attachment(path: &str, cwd: &str, home: Option<&str>, data_home: &Path) -> bool {
    let p = Path::new(path);
    if !p.is_absolute() || p.components().any(|c| matches!(c, Component::ParentDir)) {
        return false;
    }
    roots(cwd, home, data_home).iter().any(|(anchor, root)| {
        if !p.starts_with(root) || p == root.as_path() {
            return false;
        }
        let Some(parent) = p.parent() else {
            return false;
        };
        if !plain_below(anchor, parent) {
            return false;
        }
        match (root.canonicalize(), p.canonicalize()) {
            (Ok(real_root), Ok(real_file)) => real_file.starts_with(&real_root) && real_file.is_file(),
            _ => false,
        }
    })
}

/// Saves a file into `dir` under `name`, or `name (2).ext`, `name (3).ext`... when that name is taken.
/// Returns the path it was saved at and the name it got.
pub fn save(dir: &Path, name: &str, bytes: &[u8]) -> Result<(PathBuf, String), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => (stem.to_string(), format!(".{ext}")),
        _ => (name.to_string(), String::new()),
    };
    for n in 1..=MAX_SUFFIX {
        let candidate = if n == 1 {
            name.to_string()
        } else {
            format!("{stem} ({n}){ext}")
        };
        let path = dir.join(&candidate);
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut file) => {
                file.write_all(bytes)
                    .map_err(|e| format!("write {}: {e}", path.display()))?;
                return Ok((path, candidate));
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("write {}: {e}", path.display())),
        }
    }
    Err("no free file name in the folder".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DATA: &str = "/Users/u/.bandito";

    #[test]
    fn names_are_plain_file_names() {
        assert!(check_name("photo.png").is_ok());
        assert!(check_name("Отчёт 2026.pdf").is_ok());
        assert!(check_name("").is_err());
        assert!(check_name("   ").is_err());
        assert!(check_name("a/b.png").is_err());
        assert!(check_name("a\\b.png").is_err());
        assert!(check_name("..").is_err());
        assert!(check_name("../etc").is_err());
        assert!(check_name("x..y").is_err());
        assert!(check_name("a\nb").is_err());
        assert!(check_name(".").is_err());
        assert!(check_name(".hidden").is_err());
        assert!(check_name("notes.txt").is_ok());
        assert!(check_name(&"a".repeat(201)).is_err());
    }

    #[test]
    fn mime_comes_from_the_extension() {
        assert_eq!(mime_of("a.PNG"), "image/png");
        assert_eq!(mime_of("a.pdf"), "application/pdf");
        assert_eq!(mime_of("noext"), "application/octet-stream");
        assert_eq!(mime_of("a.unknownext"), "application/octet-stream");
    }

    #[test]
    fn the_root_is_the_project_folder_then_the_home() {
        let r = roots("/work/proj", Some("/work/home"), Path::new(DATA));
        assert_eq!(r[0].1, PathBuf::from("/work/proj/.bandito/attachments"));
        assert_eq!(r[1].1, PathBuf::from("/work/home/files/attachments"));
        let only_home = roots("", Some("/work/home"), Path::new(DATA));
        assert_eq!(only_home.len(), 1);
        assert_eq!(only_home[0].1, PathBuf::from("/work/home/files/attachments"));
        assert!(roots("", None, Path::new(DATA)).is_empty());
    }

    #[test]
    fn the_data_folder_is_never_an_attachment_folder() {
        // An agent whose folder is the user's home: `~/.bandito` is the data folder.
        let f = roots("/Users/u", Some("/Users/u/bandito/agents/x"), Path::new(DATA));
        assert_eq!(f.len(), 1, "the cwd's folder is the data folder: only the home is left");
        assert_eq!(f[0].1, PathBuf::from("/Users/u/bandito/agents/x/files/attachments"));
        let none = roots("/Users/u/.bandito", None, Path::new(DATA));
        assert!(none.is_empty());
        assert!(folder_for_today("/Users/u/.bandito", None, Path::new(DATA), "d").is_err());
    }

    #[test]
    fn the_project_folder_gets_a_gitignore_once() {
        let tmp = tempfile::tempdir().unwrap();
        let cwd = tmp.path().join("proj");
        std::fs::create_dir_all(&cwd).unwrap();
        let cwd_s = cwd.display().to_string();
        folder_for_today(&cwd_s, None, Path::new(DATA), "2026-10-10").unwrap();
        let ignore = cwd.join(".bandito/.gitignore");
        assert!(std::fs::read_to_string(&ignore).unwrap().lines().any(|l| l == "*"));
        // The person's own version stays.
        std::fs::write(&ignore, "mine\n").unwrap();
        folder_for_today(&cwd_s, None, Path::new(DATA), "2026-10-11").unwrap();
        assert_eq!(std::fs::read_to_string(&ignore).unwrap(), "mine\n");
    }

    #[test]
    fn saved_names_do_not_overwrite() {
        let dir = std::env::temp_dir().join(format!("bandito-att-{}", crate::store::new_id()));
        let (p1, n1) = save(&dir, "a.txt", b"one").unwrap();
        let (p2, n2) = save(&dir, "a.txt", b"two").unwrap();
        let (p3, n3) = save(&dir, "a.txt", b"three").unwrap();
        assert_eq!(
            (n1.as_str(), n2.as_str(), n3.as_str()),
            ("a.txt", "a (2).txt", "a (3).txt")
        );
        assert_eq!(std::fs::read(&p1).unwrap(), b"one");
        assert_eq!(std::fs::read(&p2).unwrap(), b"two");
        assert_eq!(std::fs::read(&p3).unwrap(), b"three");
        let (_, bare) = save(&dir, "README", b"x").unwrap();
        assert_eq!(bare, "README");
        let (_, again) = save(&dir, "README", b"y").unwrap();
        assert_eq!(again, "README (2)");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn only_files_inside_the_agents_folders_pass() {
        let dir = std::env::temp_dir().join(format!("bandito-att-{}", crate::store::new_id()));
        let day = dir.join(".bandito").join("attachments").join("2026-10-10");
        std::fs::create_dir_all(&day).unwrap();
        let file = day.join("a.png");
        std::fs::write(&file, b"png").unwrap();
        let cwd = dir.display().to_string();
        let good = file.display().to_string();
        assert!(is_agent_attachment(&good, &cwd, None, Path::new(DATA)));
        // Outside the folder, a missing file, and a path with `..` are all refused.
        let outside = dir.join("secret.txt");
        std::fs::write(&outside, b"s").unwrap();
        assert!(!is_agent_attachment(
            &outside.display().to_string(),
            &cwd,
            None,
            Path::new(DATA)
        ));
        let missing = day.join("nope.png").display().to_string();
        assert!(!is_agent_attachment(&missing, &cwd, None, Path::new(DATA)));
        let sneaky = format!("{}/../../secret.txt", day.display());
        assert!(!is_agent_attachment(&sneaky, &cwd, None, Path::new(DATA)));
        assert!(!is_agent_attachment("relative/a.png", &cwd, None, Path::new(DATA)));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_link_on_the_way_is_refused_for_writing_and_reading() {
        use std::os::unix::fs::symlink;
        let base = std::env::temp_dir().join(format!("bandito-att-links-{}", crate::store::new_id()));
        let cwd = base.join("project");
        let outside = base.join("outside");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::create_dir_all(outside.join("attachments").join("d")).unwrap();
        std::fs::write(outside.join("attachments").join("d").join("x.txt"), b"x").unwrap();
        std::fs::write(outside.join("secret.txt"), b"s").unwrap();
        let cwd_text = cwd.display().to_string();
        let data = Path::new(DATA);

        // `.bandito` is a link: nothing is written through it, and nothing in it is an attachment.
        symlink(&outside, cwd.join(".bandito")).unwrap();
        let err = folder_for_today(&cwd_text, None, data, "d").unwrap_err();
        assert!(err.contains("symbolic link"), "{err}");
        let through = cwd.join(".bandito/attachments/d/x.txt").display().to_string();
        assert!(!is_agent_attachment(&through, &cwd_text, None, data));
        std::fs::remove_file(cwd.join(".bandito")).unwrap();

        // `.bandito` is a real folder, `attachments` is a link.
        std::fs::create_dir_all(cwd.join(".bandito")).unwrap();
        symlink(outside.join("attachments"), cwd.join(".bandito/attachments")).unwrap();
        assert!(folder_for_today(&cwd_text, None, data, "d").is_err());
        assert!(!is_agent_attachment(&through, &cwd_text, None, data));
        std::fs::remove_file(cwd.join(".bandito/attachments")).unwrap();

        // `attachments` is real, the day folder is a link.
        std::fs::create_dir_all(cwd.join(".bandito/attachments")).unwrap();
        symlink(outside.join("attachments/d"), cwd.join(".bandito/attachments/d")).unwrap();
        assert!(folder_for_today(&cwd_text, None, data, "d").is_err());
        assert!(!is_agent_attachment(&through, &cwd_text, None, data));
        std::fs::remove_file(cwd.join(".bandito/attachments/d")).unwrap();

        // The folders are real, but the file is a link to a file outside them.
        std::fs::create_dir_all(cwd.join(".bandito/attachments/d")).unwrap();
        let file_link = cwd.join(".bandito/attachments/d/leak.txt");
        symlink(outside.join("secret.txt"), &file_link).unwrap();
        assert!(!is_agent_attachment(
            &file_link.display().to_string(),
            &cwd_text,
            None,
            data
        ));
        // And a real file there is accepted, through the real folders.
        std::fs::write(cwd.join(".bandito/attachments/d/ok.txt"), b"ok").unwrap();
        assert!(is_agent_attachment(
            &cwd.join(".bandito/attachments/d/ok.txt").display().to_string(),
            &cwd_text,
            None,
            data
        ));

        std::fs::remove_dir_all(&base).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_project_folder_reached_through_a_link_still_works() {
        use std::os::unix::fs::symlink;
        // On macOS /tmp is a link; an agent whose folder is named through one must keep working.
        let base = std::env::temp_dir().join(format!("bandito-att-alias-{}", crate::store::new_id()));
        let real = base.join("real-project");
        let alias = base.join("alias");
        std::fs::create_dir_all(&real).unwrap();
        symlink(&real, &alias).unwrap();
        let cwd_text = alias.display().to_string();
        let dir = folder_for_today(&cwd_text, None, Path::new(DATA), "2026-10-10").unwrap();
        let (saved, _) = save(&dir, "a.txt", b"hi").unwrap();
        assert!(is_agent_attachment(
            &saved.display().to_string(),
            &cwd_text,
            None,
            Path::new(DATA)
        ));
        std::fs::remove_dir_all(&base).unwrap();
    }
}
