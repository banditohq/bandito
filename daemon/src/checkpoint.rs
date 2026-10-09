//! Checkpoints: a shadow git repository in each agent's home folder that records
//! what the agent's working folder looked like before and after its turns. The app
//! uses it to show what an agent changed and to undo it. The working folder may or
//! may not be a git repository; a project's own `.git` is never touched, because the
//! shadow repository is driven with `GIT_DIR` and `GIT_WORK_TREE` only.
//! See docs/ARCHITECTURE.md#changes.

use crate::store::now_ms;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};
use std::process::{Output, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::Mutex as AsyncMutex;

/// Directory of the shadow repository, inside the agent's home folder.
pub const GIT_DIR_NAME: &str = ".checkpoints";

/// Largest diff `file_diff` returns; longer ones are cut and marked.
pub const MAX_DIFF_BYTES: usize = 512 * 1024;

/// Each git command gets this long. The supervisor limits a whole snapshot separately.
const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
/// Files over this size are never checkpointed.
const MAX_FILE_BYTES: u64 = 5 * 1024 * 1024;
/// A working folder with more files than this is not checkpointed.
const MAX_FILES: usize = 20_000;
/// Never checkpointed; written to `info/exclude` of the shadow repository.
/// Credentials stay out too, even when the project does not ignore them.
const EXCLUDES: &[&str] = &[
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "id_rsa*",
    "id_ed25519*",
    ".npmrc",
    ".netrc",
    ".git/",
    "node_modules/",
    "target/",
    ".venv/",
    "venv/",
    "__pycache__/",
    "dist/",
    "build/",
    ".next/",
    ".cache/",
    "*.log",
];
/// Author of the checkpoint commits.
const AUTHOR: &str = "Bandito";
const AUTHOR_EMAIL: &str = "bandito@localhost";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub sha: String,
    pub label: String,
    /// Unix milliseconds.
    pub created_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FileChange {
    /// Relative to the working folder, `/` separated.
    pub path: String,
    pub status: ChangeKind,
    /// The old path of a renamed file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    /// `None` for binary files.
    pub additions: Option<u32>,
    /// `None` for binary files.
    pub deletions: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDiff {
    pub diff: String,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Restored {
    /// Paths that were brought back or removed.
    pub paths: Vec<String>,
    /// The state from before the restore; restoring it undoes the restore.
    pub undo: Snapshot,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("path must be relative to the agent's folder and stay inside it: {0}")]
    InvalidPath(String),
    #[error("not a checkpoint: {0}")]
    InvalidRevision(String),
    #[error("the agent's folder does not exist: {0}")]
    MissingFolder(String),
    #[error("too many files to checkpoint")]
    TooManyFiles,
    #[error("could not take a checkpoint before restoring")]
    UndoUnavailable,
    #[error("git {command} failed: {detail}")]
    Git { command: String, detail: String },
    #[error("{0}")]
    Io(String),
}

impl Error {
    /// Stable code for clients (`error.data.reason`).
    pub fn reason(&self) -> &'static str {
        match self {
            Error::InvalidPath(_) => "invalid_path",
            Error::InvalidRevision(_) => "invalid_revision",
            Error::MissingFolder(_) => "missing_folder",
            Error::TooManyFiles => "too_many_files",
            Error::UndoUnavailable => "undo_unavailable",
            Error::Git { .. } => "git",
            Error::Io(_) => "io",
        }
    }
}

/// Record the working folder now. Returns `None` (with a warning) when the folder is
/// missing, when git fails, or when there are too many files; the caller goes on without it.
pub async fn snapshot(home: &Path, cwd: &Path, label: &str) -> Result<Option<Snapshot>, Error> {
    let lock = repo_lock(home);
    let _guard = lock.lock().await;
    let repo = match Repo::open(home, cwd).await {
        Ok(repo) => repo,
        Err(Error::MissingFolder(dir)) => {
            tracing::warn!(folder = %dir, "checkpoint skipped: the agent's folder does not exist");
            return Ok(None);
        }
        Err(e) => return Err(e),
    };
    snapshot_locked(&repo, label).await
}

async fn snapshot_locked(repo: &Repo, label: &str) -> Result<Option<Snapshot>, Error> {
    match repo.stage().await {
        Ok(true) => {}
        Ok(false) => {
            tracing::warn!(folder = %repo.work_tree.display(), "checkpoint skipped: more than {MAX_FILES} files");
            return Ok(None);
        }
        Err(e) => {
            tracing::warn!(folder = %repo.work_tree.display(), "checkpoint skipped: {e}");
            return Ok(None);
        }
    }
    let changed = match repo.run(&["diff", "--cached", "--quiet"]).await?.status.code() {
        Some(0) => false,
        Some(1) => true,
        _ => return Err(git_err("diff", "could not compare the index with HEAD")),
    };
    if !changed && let Some(head) = repo.head().await? {
        return Ok(Some(Snapshot {
            sha: head,
            label: label.to_string(),
            created_at: now_ms(),
        }));
    }
    repo.git(&[
        "commit",
        "--quiet",
        "--allow-empty",
        "--allow-empty-message",
        "-m",
        label,
    ])
    .await?;
    let sha = text(&repo.git(&["rev-parse", "HEAD"]).await?);
    Ok(Some(Snapshot {
        sha,
        label: label.to_string(),
        created_at: now_ms(),
    }))
}

/// Files that differ between `from` and `to` (`None` = the working folder now).
pub async fn changes(home: &Path, cwd: &Path, from: &str, to: Option<&str>) -> Result<Vec<FileChange>, Error> {
    check_revision(from)?;
    if let Some(to) = to {
        check_revision(to)?;
    }
    let lock = repo_lock(home);
    let _guard = lock.lock().await;
    let repo = Repo::open(home, cwd).await?;
    let base = diff_base(&repo, from, to).await?;
    let mut numstat_args = base.clone();
    numstat_args.extend(["--numstat", "-z"]);
    let mut status_args = base;
    status_args.extend(["--name-status", "-z"]);
    let numstat = repo.git(&numstat_args).await?;
    let status = repo.git(&status_args).await?;
    parse_changes(&numstat, &status)
}

/// Unified diff of one file between `from` and `to` (`None` = the working folder now).
pub async fn file_diff(home: &Path, cwd: &Path, from: &str, to: Option<&str>, path: &str) -> Result<FileDiff, Error> {
    check_revision(from)?;
    if let Some(to) = to {
        check_revision(to)?;
    }
    check_relative(path)?;
    let lock = repo_lock(home);
    let _guard = lock.lock().await;
    let repo = Repo::open(home, cwd).await?;
    let mut args = diff_base(&repo, from, to).await?;
    args.extend(["--no-color", "-U3", "--", path]);
    let out = repo.git(&args).await?;
    let truncated = out.len() > MAX_DIFF_BYTES;
    let mut diff = String::from_utf8_lossy(&out[..out.len().min(MAX_DIFF_BYTES)]).into_owned();
    if truncated {
        diff.push_str("\n… diff cut at 512 KiB\n");
    }
    Ok(FileDiff { diff, truncated })
}

/// Put files back as they were at `sha`: all changed files, or only `paths`.
/// Takes an undo checkpoint first.
pub async fn restore(home: &Path, cwd: &Path, sha: &str, paths: Option<&[String]>) -> Result<Restored, Error> {
    check_revision(sha)?;
    if let Some(paths) = paths {
        for path in paths {
            check_relative(path)?;
        }
    }
    let lock = repo_lock(home);
    let _guard = lock.lock().await;
    let repo = Repo::open(home, cwd).await?;
    // The undo point also stages the working folder, so the index below is the current state.
    let undo = snapshot_locked(&repo, "before restore")
        .await?
        .ok_or(Error::UndoUnavailable)?;
    let targets = match paths {
        Some(paths) => paths.to_vec(),
        None => {
            let names = repo
                .git(&["diff", "--cached", "--name-only", "-z", "--no-renames", sha])
                .await?;
            fields(&names)
        }
    };
    let mut restored = Vec::new();
    for path in targets {
        let in_sha = repo
            .run(&["cat-file", "-e", &format!("{sha}:{path}")])
            .await?
            .status
            .success();
        if in_sha {
            repo.git(&["checkout", sha, "--", &path]).await?;
            restored.push(path);
        } else if remove_working_file(cwd, &path)? {
            restored.push(path);
        }
    }
    Ok(Restored { paths: restored, undo })
}

/// Ok when `path` is a plain relative path inside the working folder.
pub fn check_relative(path: &str) -> Result<(), Error> {
    let bad = || Error::InvalidPath(path.to_string());
    if path.is_empty() || path.contains('\0') {
        return Err(bad());
    }
    for component in Path::new(path).components() {
        match component {
            Component::Normal(name) if !matches!(name.to_str(), Some(".git") | Some(GIT_DIR_NAME)) => {}
            _ => return Err(bad()),
        }
    }
    Ok(())
}

/// A commit id as git prints it: 40 hex digits. Anything else (even `--option`) is refused.
fn check_revision(rev: &str) -> Result<(), Error> {
    if rev.len() == 40 && rev.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(Error::InvalidRevision(rev.to_string()))
    }
}

/// Arguments of a `git diff` from `from` to `to`, or from `from` to the staged
/// working folder when `to` is `None` (which stages it first).
async fn diff_base<'a>(repo: &Repo, from: &'a str, to: Option<&'a str>) -> Result<Vec<&'a str>, Error> {
    let mut args = vec!["diff", "-M", "--no-ext-diff"];
    if to.is_none() {
        if !repo.stage().await? {
            return Err(Error::TooManyFiles);
        }
        args.push("--cached");
    }
    args.push(from);
    if let Some(to) = to {
        args.push(to);
    }
    Ok(args)
}

/// Pairs the `--numstat -z` and `--name-status -z` outputs of one diff, which list the same files in the same order.
fn parse_changes(numstat: &[u8], status: &[u8]) -> Result<Vec<FileChange>, Error> {
    let numstat = fields(numstat);
    let status = fields(status);
    let mut counts = Vec::new();
    let mut i = 0;
    while i < numstat.len() {
        let mut parts = numstat[i].splitn(3, '\t');
        let additions = parts.next().unwrap_or_default();
        let deletions = parts.next().unwrap_or_default();
        let path = parts.next().unwrap_or_default();
        // A rename has an empty path here; the two paths follow as their own fields.
        i += if path.is_empty() { 3 } else { 1 };
        counts.push((count(additions), count(deletions)));
    }
    let mut out = Vec::new();
    let mut j = 0;
    let mut counts = counts.into_iter();
    while j < status.len() {
        let code = status[j].as_str();
        let (kind, path, from, step) = match code.chars().next() {
            Some('R') | Some('C') => (
                ChangeKind::Renamed,
                field(&status, j + 2)?,
                Some(field(&status, j + 1)?),
                3,
            ),
            Some('A') => (ChangeKind::Added, field(&status, j + 1)?, None, 2),
            Some('D') => (ChangeKind::Deleted, field(&status, j + 1)?, None, 2),
            _ => (ChangeKind::Modified, field(&status, j + 1)?, None, 2),
        };
        let (additions, deletions) = counts
            .next()
            .ok_or_else(|| git_err("diff", "numstat and name-status disagree"))?;
        out.push(FileChange {
            path,
            status: kind,
            from,
            additions,
            deletions,
        });
        j += step;
    }
    if counts.next().is_some() {
        return Err(git_err("diff", "numstat and name-status disagree"));
    }
    Ok(out)
}

/// One `git diff` count; `-` (binary) is `None`.
fn count(s: &str) -> Option<u32> {
    s.parse().ok()
}

fn field(list: &[String], at: usize) -> Result<String, Error> {
    list.get(at)
        .cloned()
        .ok_or_else(|| git_err("diff", "unexpected output"))
}

/// Deletes a file of the working folder. False when there is nothing to delete.
/// Refuses to delete through a symlink that leads out of the folder.
fn remove_working_file(cwd: &Path, path: &str) -> Result<bool, Error> {
    let full = cwd.join(path);
    let meta = match std::fs::symlink_metadata(&full) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(io_err(e)),
    };
    if meta.is_dir() {
        return Ok(false);
    }
    if let Some(parent) = full.parent() {
        let root = cwd.canonicalize().map_err(io_err)?;
        let parent = parent.canonicalize().map_err(io_err)?;
        if !parent.starts_with(&root) {
            return Err(Error::InvalidPath(path.to_string()));
        }
    }
    std::fs::remove_file(&full).map_err(io_err)?;
    Ok(true)
}

/// NUL-separated output of a `-z` command. Empty fields at the end are dropped.
fn fields(bytes: &[u8]) -> Vec<String> {
    let mut out: Vec<String> = bytes
        .split(|b| *b == 0)
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect();
    while out.last().is_some_and(|s| s.is_empty()) {
        out.pop();
    }
    out
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).trim().to_string()
}

fn io_err(e: std::io::Error) -> Error {
    Error::Io(e.to_string())
}

fn git_err(command: &str, detail: impl Into<String>) -> Error {
    Error::Git {
        command: command.to_string(),
        detail: detail.into(),
    }
}

/// Locks used for every shadow repository, keyed by its home folder. Git's index
/// does not survive two commands at once, and the calls are short.
fn repo_lock(home: &Path) -> Arc<AsyncMutex<()>> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<AsyncMutex<()>>>>> = OnceLock::new();
    let locks = LOCKS.get_or_init(Default::default);
    let mut locks = locks.lock().unwrap_or_else(|e| e.into_inner());
    locks.entry(home.to_path_buf()).or_default().clone()
}

/// A shadow repository bound to one working folder. Only used under `repo_lock`.
struct Repo {
    git_dir: PathBuf,
    work_tree: PathBuf,
}

impl Repo {
    /// Creates the repository on first use, and clears a lock file that a git killed by a timeout left behind.
    async fn open(home: &Path, cwd: &Path) -> Result<Self, Error> {
        if !cwd.is_dir() {
            return Err(Error::MissingFolder(cwd.display().to_string()));
        }
        let repo = Repo {
            git_dir: home.join(GIT_DIR_NAME),
            work_tree: cwd.to_path_buf(),
        };
        if !repo.git_dir.join("HEAD").is_file() {
            repo.init().await?;
        }
        let _ = std::fs::remove_file(repo.git_dir.join("index.lock"));
        Ok(repo)
    }

    async fn init(&self) -> Result<(), Error> {
        std::fs::create_dir_all(&self.git_dir).map_err(io_err)?;
        self.git(&["init", "--quiet"]).await?;
        let info = self.git_dir.join("info");
        std::fs::create_dir_all(&info).map_err(io_err)?;
        let mut lines: Vec<String> = EXCLUDES.iter().map(|s| s.to_string()).collect();
        // When the home folder is inside the working folder, keep the repository out of its own snapshots.
        if let Ok(rel) = self.git_dir.strip_prefix(&self.work_tree) {
            lines.push(format!("{}/", anchored(&rel.to_string_lossy())));
        }
        let body = format!(
            "# Written by Bandito: files that are never checkpointed.\n{}\n",
            lines.join("\n")
        );
        std::fs::write(info.join("exclude"), body).map_err(io_err)?;
        restrict_to_owner(&self.git_dir)
    }

    /// Stages the whole working folder, then takes files over the size limit out of the index,
    /// and out of future snapshots. `Ok(false)` when there are too many files.
    async fn stage(&self) -> Result<bool, Error> {
        self.git(&["add", "-A"]).await?;
        let listed = self.git(&["ls-files", "-z"]).await?;
        if fields(&listed).len() > MAX_FILES {
            return Ok(false);
        }
        let added = self
            .git(&[
                "diff",
                "--cached",
                "--name-only",
                "-z",
                "--no-renames",
                "--diff-filter=AM",
            ])
            .await?;
        for path in fields(&added) {
            let too_big =
                std::fs::symlink_metadata(self.work_tree.join(&path)).is_ok_and(|meta| meta.len() > MAX_FILE_BYTES);
            if !too_big {
                continue;
            }
            if let Err(e) = self.git(&["rm", "--cached", "--quiet", "--", &path]).await {
                tracing::warn!(path = %path, "checkpoint: could not drop a large file from the index: {e}");
            }
            self.exclude(&path)?;
        }
        Ok(true)
    }

    /// Adds `path` to `info/exclude` unless it is there already.
    fn exclude(&self, path: &str) -> Result<(), Error> {
        let file = self.git_dir.join("info").join("exclude");
        let line = anchored(path);
        let current = std::fs::read_to_string(&file).unwrap_or_default();
        if current.lines().any(|l| l == line) {
            return Ok(());
        }
        let mut text = current;
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(&line);
        text.push('\n');
        std::fs::write(&file, text).map_err(io_err)
    }

    async fn head(&self) -> Result<Option<String>, Error> {
        let out = self.run(&["rev-parse", "--verify", "-q", "HEAD"]).await?;
        Ok(out.status.success().then(|| text(&out.stdout)))
    }

    /// Runs git on the shadow repository. The exit status is the caller's to check.
    async fn run(&self, args: &[&str]) -> Result<Output, Error> {
        let mut cmd = Command::new("git");
        cmd.env_clear();
        for key in ["PATH", "HOME"] {
            if let Some(value) = std::env::var_os(key) {
                cmd.env(key, value);
            }
        }
        cmd.env("GIT_DIR", &self.git_dir)
            .env("GIT_WORK_TREE", &self.work_tree)
            .env("GIT_AUTHOR_NAME", AUTHOR)
            .env("GIT_AUTHOR_EMAIL", AUTHOR_EMAIL)
            .env("GIT_COMMITTER_NAME", AUTHOR)
            .env("GIT_COMMITTER_EMAIL", AUTHOR_EMAIL)
            // File names are names, not patterns.
            .env("GIT_LITERAL_PATHSPECS", "1")
            .args([
                "-c",
                "core.autocrlf=false",
                "-c",
                "core.quotepath=off",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .stdin(Stdio::null())
            .kill_on_drop(true);
        let name = args.first().copied().unwrap_or_default();
        match tokio::time::timeout(COMMAND_TIMEOUT, cmd.output()).await {
            Ok(Ok(out)) => Ok(out),
            Ok(Err(e)) => Err(git_err(name, e.to_string())),
            Err(_) => Err(git_err(name, "timed out")),
        }
    }

    /// Like `run`, but a failing exit status is an error. Returns stdout.
    async fn git(&self, args: &[&str]) -> Result<Vec<u8>, Error> {
        let out = self.run(args).await?;
        if out.status.success() {
            Ok(out.stdout)
        } else {
            Err(git_err(args.first().copied().unwrap_or_default(), text(&out.stderr)))
        }
    }
}

/// `info/exclude` pattern for one path: anchored at the working folder, glob characters escaped.
fn anchored(path: &str) -> String {
    let mut out = String::from("/");
    for c in path.chars() {
        if matches!(c, '*' | '?' | '[' | ']' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    if path.ends_with(' ') {
        out.insert(out.len() - 1, '\\');
    }
    out
}

#[cfg(unix)]
fn restrict_to_owner(dir: &Path) -> Result<(), Error> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700)).map_err(io_err)
}

#[cfg(not(unix))]
fn restrict_to_owner(_dir: &Path) -> Result<(), Error> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// A home folder (for the shadow repository) and a working folder, both in a temp dir.
    struct Fixture {
        _dir: tempfile::TempDir,
        home: PathBuf,
        proj: PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let proj = dir.path().join("proj");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&proj).unwrap();
        Fixture { _dir: dir, home, proj }
    }

    fn write(path: &Path, bytes: impl AsRef<[u8]>) {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(path, bytes).unwrap();
    }

    /// Runs git in `dir` for the test's own repository (not the shadow one).
    fn git(dir: &Path, args: &[&str]) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "test")
            .env("GIT_AUTHOR_EMAIL", "test@test")
            .env("GIT_COMMITTER_NAME", "test")
            .env("GIT_COMMITTER_EMAIL", "test@test")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap()
    }

    fn is_sha(s: &str) -> bool {
        s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
    }

    async fn snap(f: &Fixture, label: &str) -> String {
        let s = snapshot(&f.home, &f.proj, label).await.unwrap().expect("snapshot");
        assert!(is_sha(&s.sha), "{}", s.sha);
        s.sha
    }

    fn by_path(list: &[FileChange], path: &str) -> FileChange {
        list.iter()
            .find(|c| c.path == path)
            .unwrap_or_else(|| panic!("{path} not in {list:?}"))
            .clone()
    }

    #[tokio::test]
    async fn snapshot_of_an_empty_folder_is_a_commit() {
        let f = fixture();
        let sha = snap(&f, "before: first").await;
        assert!(f.home.join(GIT_DIR_NAME).join("HEAD").is_file());
        assert!(changes(&f.home, &f.proj, &sha, None).await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn unchanged_folder_gives_the_same_sha() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "hello\n");
        let first = snap(&f, "before: one").await;
        let second = snap(&f, "after").await;
        assert_eq!(first, second);
    }

    #[tokio::test]
    async fn modified_added_and_deleted_files_are_listed_with_counts() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "one\ntwo\nthree\n");
        write(&f.proj.join("gone.txt"), "bye\n");
        let base = snap(&f, "before: base").await;

        write(&f.proj.join("a.txt"), "one\nTWO\nthree\nfour\n");
        std::fs::remove_file(f.proj.join("gone.txt")).unwrap();
        write(&f.proj.join("new.txt"), "x\ny\n");

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        let a = by_path(&list, "a.txt");
        assert_eq!(a.status, ChangeKind::Modified);
        assert_eq!((a.additions, a.deletions), (Some(2), Some(1)));
        let new = by_path(&list, "new.txt");
        assert_eq!(new.status, ChangeKind::Added);
        assert_eq!((new.additions, new.deletions), (Some(2), Some(0)));
        let gone = by_path(&list, "gone.txt");
        assert_eq!(gone.status, ChangeKind::Deleted);
        assert_eq!(list.len(), 3, "{list:?}");
    }

    #[tokio::test]
    async fn renamed_file_is_reported_with_its_old_path() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "same content\nline two\nline three\n");
        let base = snap(&f, "before: base").await;
        std::fs::rename(f.proj.join("a.txt"), f.proj.join("b.txt")).unwrap();

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        assert_eq!(list.len(), 1, "{list:?}");
        assert_eq!(list[0].status, ChangeKind::Renamed);
        assert_eq!(list[0].path, "b.txt");
        assert_eq!(list[0].from.as_deref(), Some("a.txt"));
    }

    #[tokio::test]
    async fn names_with_spaces_and_cyrillic_are_kept_as_they_are() {
        let f = fixture();
        let base = snap(&f, "before: base").await;
        write(&f.proj.join("Отчёт 1 final.txt"), "данные\n");

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        assert_eq!(by_path(&list, "Отчёт 1 final.txt").status, ChangeKind::Added);
        let diff = file_diff(&f.home, &f.proj, &base, None, "Отчёт 1 final.txt")
            .await
            .unwrap();
        assert!(diff.diff.contains("+данные"), "{}", diff.diff);
    }

    #[tokio::test]
    async fn binary_file_has_no_line_counts() {
        let f = fixture();
        let base = snap(&f, "before: base").await;
        write(&f.proj.join("img.bin"), [0u8, 159, 146, 150, 0, 1, 2]);

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        let bin = by_path(&list, "img.bin");
        assert_eq!(bin.status, ChangeKind::Added);
        assert_eq!((bin.additions, bin.deletions), (None, None));
    }

    #[tokio::test]
    async fn files_over_5_mib_are_not_tracked_and_stay_untracked() {
        let f = fixture();
        write(&f.proj.join("small.txt"), "small\n");
        let first = snap(&f, "before: base").await;
        write(&f.proj.join("big.bin"), vec![b'x'; 5 * 1024 * 1024 + 1]);

        let second = snap(&f, "after").await;
        assert_eq!(first, second, "an untracked file does not make a new checkpoint");
        let list = changes(&f.home, &f.proj, &first, None).await.unwrap();
        assert!(list.iter().all(|c| c.path != "big.bin"), "{list:?}");
        assert!(f.proj.join("big.bin").is_file(), "the file itself is left alone");

        // Changing it again does not bring it back.
        write(&f.proj.join("big.bin"), vec![b'y'; 5 * 1024 * 1024 + 7]);
        let list = changes(&f.home, &f.proj, &second, None).await.unwrap();
        assert!(list.is_empty(), "{list:?}");
    }

    #[tokio::test]
    async fn build_and_dependency_folders_are_not_tracked() {
        let f = fixture();
        let base = snap(&f, "before: base").await;
        write(&f.proj.join("node_modules/pkg/index.js"), "x\n");
        write(&f.proj.join("target/debug/out"), "x\n");
        write(&f.proj.join("app.log"), "x\n");
        write(&f.proj.join("src/main.rs"), "fn main() {}\n");

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        let paths: Vec<&str> = list.iter().map(|c| c.path.as_str()).collect();
        assert_eq!(paths, ["src/main.rs"], "{list:?}");
    }

    #[tokio::test]
    async fn credentials_are_not_tracked() {
        let f = fixture();
        let base = snap(&f, "before: base").await;
        write(&f.proj.join(".env"), "TOKEN=x\n");
        write(&f.proj.join(".env.local"), "TOKEN=x\n");
        write(&f.proj.join("certs/server.key"), "x\n");
        write(&f.proj.join("README.md"), "hi\n");

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        let paths: Vec<&str> = list.iter().map(|c| c.path.as_str()).collect();
        assert_eq!(paths, ["README.md"], "{list:?}");
    }

    #[tokio::test]
    async fn file_diff_has_plus_and_minus_lines() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "one\ntwo\nthree\n");
        let base = snap(&f, "before: base").await;
        write(&f.proj.join("a.txt"), "one\nTWO\nthree\nfour\n");

        let d = file_diff(&f.home, &f.proj, &base, None, "a.txt").await.unwrap();
        assert!(!d.truncated);
        assert!(d.diff.contains("-two\n"), "{}", d.diff);
        assert!(d.diff.contains("+TWO\n"), "{}", d.diff);
        assert!(d.diff.contains("+four\n"), "{}", d.diff);
    }

    #[tokio::test]
    async fn restore_one_file_brings_back_old_content_and_makes_an_undo() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "v1\n");
        let base = snap(&f, "before: base").await;
        write(&f.proj.join("a.txt"), "v2\n");

        let restored = restore(&f.home, &f.proj, &base, Some(&["a.txt".to_string()]))
            .await
            .unwrap();
        assert_eq!(restored.paths, ["a.txt"]);
        assert_eq!(std::fs::read_to_string(f.proj.join("a.txt")).unwrap(), "v1\n");
        assert_ne!(restored.undo.sha, base);
        assert!(restored.undo.label.contains("restore"), "{}", restored.undo.label);
    }

    #[tokio::test]
    async fn restore_all_removes_new_files_and_brings_back_deleted_ones() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "a\n");
        write(&f.proj.join("b.txt"), "b\n");
        let base = snap(&f, "before: base").await;

        std::fs::remove_file(f.proj.join("b.txt")).unwrap();
        write(&f.proj.join("c.txt"), "c\n");

        let restored = restore(&f.home, &f.proj, &base, None).await.unwrap();
        assert!(!f.proj.join("c.txt").exists(), "new file removed");
        assert_eq!(std::fs::read_to_string(f.proj.join("b.txt")).unwrap(), "b\n");
        assert_eq!(std::fs::read_to_string(f.proj.join("a.txt")).unwrap(), "a\n");
        let mut paths = restored.paths.clone();
        paths.sort();
        assert_eq!(paths, ["b.txt", "c.txt"]);
    }

    #[tokio::test]
    async fn the_undo_checkpoint_can_be_applied_back() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "a\n");
        let base = snap(&f, "before: base").await;
        std::fs::remove_file(f.proj.join("a.txt")).unwrap();
        write(&f.proj.join("c.txt"), "c\n");

        let first = restore(&f.home, &f.proj, &base, None).await.unwrap();
        assert!(f.proj.join("a.txt").exists());
        assert!(!f.proj.join("c.txt").exists());

        restore(&f.home, &f.proj, &first.undo.sha, None).await.unwrap();
        assert!(!f.proj.join("a.txt").exists(), "back to the state before the restore");
        assert_eq!(std::fs::read_to_string(f.proj.join("c.txt")).unwrap(), "c\n");
    }

    #[tokio::test]
    async fn paths_outside_the_folder_are_refused() {
        let f = fixture();
        write(&f.proj.join("a.txt"), "a\n");
        let base = snap(&f, "before: base").await;

        for bad in [
            "../x",
            "/etc/passwd",
            "a/../../x",
            "",
            ".git/config",
            ".checkpoints/HEAD",
        ] {
            let err = restore(&f.home, &f.proj, &base, Some(&[bad.to_string()]))
                .await
                .unwrap_err();
            assert_eq!(err.reason(), "invalid_path", "{bad:?}: {err}");
            let err = file_diff(&f.home, &f.proj, &base, None, bad).await.unwrap_err();
            assert_eq!(err.reason(), "invalid_path", "{bad:?}: {err}");
        }
        assert!(matches!(check_relative("sub/x.txt"), Ok(())));
    }

    #[tokio::test]
    async fn bad_revisions_are_refused() {
        let f = fixture();
        let err = changes(&f.home, &f.proj, "--output=/tmp/x", None).await.unwrap_err();
        assert_eq!(err.reason(), "invalid_revision");
    }

    #[tokio::test]
    async fn missing_folder_gives_no_snapshot_and_an_error_for_changes() {
        let f = fixture();
        let gone = f.proj.join("not-there");
        assert_eq!(snapshot(&f.home, &gone, "before: x").await.unwrap(), None);
        let err = changes(&f.home, &gone, &"a".repeat(40), None).await.unwrap_err();
        assert_eq!(err.reason(), "missing_folder");
    }

    #[tokio::test]
    async fn project_git_repository_is_not_touched() {
        let f = fixture();
        git(&f.proj, &["init", "-q"]);
        write(&f.proj.join("tracked.txt"), "one\n");
        git(&f.proj, &["add", "tracked.txt"]);
        git(&f.proj, &["commit", "-q", "-m", "init"]);
        write(&f.proj.join("tracked.txt"), "two\n");
        write(&f.proj.join("untracked.txt"), "u\n");

        let head_before = git(&f.proj, &["rev-parse", "HEAD"]);
        let status_before = git(&f.proj, &["status", "--porcelain"]);
        let index_before = std::fs::read(f.proj.join(".git").join("index")).unwrap();

        let base = snap(&f, "before: base").await;
        write(&f.proj.join("tracked.txt"), "three\n");
        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        assert_eq!(by_path(&list, "tracked.txt").status, ChangeKind::Modified);
        restore(&f.home, &f.proj, &base, None).await.unwrap();

        // Read the index before any git call in the project: `git status` may refresh it.
        assert_eq!(std::fs::read(f.proj.join(".git").join("index")).unwrap(), index_before);
        assert_eq!(git(&f.proj, &["rev-parse", "HEAD"]), head_before);
        assert_eq!(git(&f.proj, &["status", "--porcelain"]), status_before);
        assert_eq!(std::fs::read_to_string(f.proj.join("tracked.txt")).unwrap(), "two\n");
    }

    #[tokio::test]
    async fn project_gitignore_is_honored() {
        let f = fixture();
        write(&f.proj.join(".gitignore"), "secret.env\n");
        let base = snap(&f, "before: base").await;
        write(&f.proj.join("secret.env"), "TOKEN=1\n");
        write(&f.proj.join("visible.txt"), "v\n");

        let list = changes(&f.home, &f.proj, &base, None).await.unwrap();
        assert!(list.iter().all(|c| c.path != "secret.env"), "{list:?}");
        assert!(list.iter().any(|c| c.path == "visible.txt"), "{list:?}");
    }
}
