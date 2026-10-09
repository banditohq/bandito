//! `fs.clone`: copies a git repository onto the server (see docs/ARCHITECTURE.md#files).
//! Only `https://` and scp-style `user@host:path` (ssh) URLs. Private repositories
//! work through the server's own ssh keys; nothing can prompt for a password.

use crate::files::FsError;
use serde::Serialize;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

/// History depth of the clone: enough to show recent work, not the whole repository.
pub const CLONE_DEPTH: u32 = 50;
/// A clone that takes longer is killed.
pub const CLONE_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// The end of git's stderr that goes back to the app.
pub const STDERR_TAIL_BYTES: usize = 2048;
/// `file://` URLs are only for the tests of this module and the RPC layer.
#[cfg(test)]
const LOCAL_URLS_ALLOWED: bool = true;
#[cfg(not(test))]
const LOCAL_URLS_ALLOWED: bool = false;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Cloned {
    /// The folder the repository was cloned into (absolute).
    pub path: String,
    /// The branch HEAD points to, or `None` when HEAD is detached.
    pub default_branch: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum CloneError {
    #[error("{0}")]
    InvalidUrl(String),
    #[error(transparent)]
    Fs(#[from] FsError),
    /// `stderr` is already cut to `STDERR_TAIL_BYTES` and has no URL credentials.
    #[error("git clone failed")]
    Failed { stderr: String },
}

/// Checks a clone URL: `https://…` or `user@host:path`. The error is a short English message.
pub fn check_url(url: &str) -> Result<(), String> {
    check_url_with(url, LOCAL_URLS_ALLOWED)
}

fn check_url_with(url: &str, allow_local: bool) -> Result<(), String> {
    const REFUSED: &str = "only https:// and user@host:path (ssh) URLs are allowed";
    if url.is_empty() || url.len() > 2048 {
        return Err("URL is empty or too long".into());
    }
    if url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("URL must not contain spaces or control characters".into());
    }
    if let Some(rest) = url.strip_prefix("https://") {
        // Credentials may sit in the authority (`user:token@host`); the host must follow them.
        let authority = rest.split('/').next().unwrap_or_default();
        let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
        if host.is_empty() || host.starts_with('-') {
            return Err("https URL has no host".into());
        }
        return Ok(());
    }
    if let Some(path) = url.strip_prefix("file://") {
        return match (allow_local, path.starts_with('/')) {
            (true, true) => Ok(()),
            _ => Err(REFUSED.into()),
        };
    }
    // scp-style ssh address: user@host:path
    let Some((user_host, path)) = url.split_once(':') else {
        return Err(REFUSED.into());
    };
    let Some((user, host)) = user_host.split_once('@') else {
        return Err(REFUSED.into());
    };
    let name_ok = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c));
    let host_ok = host.starts_with(|c: char| c.is_ascii_alphanumeric()) && name_ok(host);
    if !name_ok(user) || !host_ok || path.is_empty() || path.starts_with('-') {
        return Err(REFUSED.into());
    }
    Ok(())
}

/// Removes `user:password@` (or `user@`) from every `scheme://` URL in `text`.
pub fn strip_credentials(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("://") {
        let (head, tail) = rest.split_at(at + 3);
        out.push_str(head);
        let end = tail
            .find(|c: char| c == '/' || c == '\'' || c == '"' || c.is_whitespace())
            .unwrap_or(tail.len());
        rest = match tail[..end].rfind('@') {
            Some(i) => &tail[i + 1..],
            None => tail,
        };
    }
    out.push_str(rest);
    out
}

/// The last `STDERR_TAIL_BYTES` of git's stderr, without credentials, cut on a character boundary.
pub fn stderr_tail(stderr: &[u8]) -> String {
    let text = strip_credentials(&String::from_utf8_lossy(stderr));
    if text.len() <= STDERR_TAIL_BYTES {
        return text;
    }
    let mut start = text.len() - STDERR_TAIL_BYTES;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text[start..].to_string()
}

/// Clones `url` into `dest`, which must be an absolute path that does not exist yet
/// (its parent must). On failure nothing is left at `dest`.
pub async fn clone_repo(url: &str, dest: &Path) -> Result<Cloned, CloneError> {
    clone_with_timeout(url, dest, CLONE_TIMEOUT).await
}

async fn clone_with_timeout(url: &str, dest: &Path, timeout: Duration) -> Result<Cloned, CloneError> {
    check_url(url).map_err(CloneError::InvalidUrl)?;
    let shown = dest.display().to_string();
    if !dest.is_absolute() {
        return Err(FsError::InvalidPath(shown).into());
    }
    if dest.symlink_metadata().is_ok() {
        return Err(FsError::AlreadyExists(shown).into());
    }
    let Some(parent) = dest.parent() else {
        return Err(FsError::InvalidPath(shown).into());
    };
    match parent.metadata() {
        Err(_) => return Err(FsError::NotFound(parent.display().to_string()).into()),
        Ok(m) if !m.is_dir() => return Err(FsError::NotADirectory(parent.display().to_string()).into()),
        Ok(_) => {}
    }

    let child = Command::new("git")
        .arg("clone")
        .arg("--depth")
        .arg(CLONE_DEPTH.to_string())
        .arg("--")
        .arg(url)
        .arg(dest)
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| CloneError::Failed {
            stderr: format!("could not run git: {e}"),
        })?;
    // Dropping the child on timeout kills git (`kill_on_drop`).
    let output = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(e)) => {
            return Err(CloneError::Failed {
                stderr: format!("git failed: {e}"),
            });
        }
        Err(_) => {
            remove_partial(dest);
            return Err(CloneError::Failed {
                stderr: format!("git clone did not finish within {} seconds", timeout.as_secs()),
            });
        }
    };
    if !output.status.success() {
        remove_partial(dest);
        return Err(CloneError::Failed {
            stderr: stderr_tail(&output.stderr),
        });
    }

    let default_branch = Command::new("git")
        .args(["symbolic-ref", "--short", "-q", "HEAD"])
        .current_dir(dest)
        .output()
        .await
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|b| !b.is_empty());
    Ok(Cloned {
        path: shown,
        default_branch,
    })
}

/// Removes what a failed clone left at `dest`. Only called for a path that did not exist before.
fn remove_partial(dest: &Path) {
    if let Err(e) = std::fs::remove_dir_all(dest)
        && e.kind() != std::io::ErrorKind::NotFound
    {
        tracing::warn!("could not remove the partial clone {}: {e}", dest.display());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        let out = Command::new("git")
            .args(["-c", "user.name=test", "-c", "user.email=test@example.com"])
            .args(args)
            .current_dir(dir)
            .output()
            .expect("git runs");
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// A bare repository with one commit on `main`, to clone from.
    fn origin(root: &Path) -> std::path::PathBuf {
        let bare = root.join("origin.git");
        let work = root.join("work");
        std::fs::create_dir_all(&work).unwrap();
        git(root, &["init", "--bare", "-b", "main", bare.to_str().unwrap()]);
        git(&work, &["init", "-b", "main"]);
        std::fs::write(work.join("README.md"), "hello\n").unwrap();
        git(&work, &["add", "README.md"]);
        git(&work, &["commit", "-m", "init"]);
        git(&work, &["push", bare.to_str().unwrap(), "main"]);
        bare
    }

    #[test]
    fn https_and_ssh_urls_are_accepted() {
        assert!(check_url_with("https://github.com/acme/app.git", false).is_ok());
        assert!(check_url_with("https://user:token@git.example.com/acme/app", false).is_ok());
        assert!(check_url_with("git@github.com:acme/app.git", false).is_ok());
        assert!(check_url_with("deploy@git.example.com:team/app.git", false).is_ok());
    }

    #[test]
    fn other_schemes_and_option_like_urls_are_refused() {
        for url in [
            "http://github.com/acme/app.git",
            "file:///etc/passwd",
            "ssh://git@github.com/acme/app.git",
            "ext::sh -c touch% /tmp/pwned",
            "--upload-pack=touch /tmp/pwned",
            "-uploadpack=x",
            "https://",
            "git@host:-oProxyCommand=x",
            "git@:repo",
            "git@host:",
            "",
            "https://github.com/acme/app.git --upload-pack=x",
            "https://github.com/acme/\napp.git",
        ] {
            assert!(check_url_with(url, false).is_err(), "accepted {url:?}");
        }
    }

    #[test]
    fn local_urls_are_only_allowed_where_asked() {
        assert!(check_url_with("file:///srv/repo.git", true).is_ok());
        assert!(check_url_with("file:///srv/repo.git", false).is_err());
        assert!(check_url("file:///srv/repo.git").is_ok(), "allowed under cfg(test)");
    }

    #[test]
    fn credentials_are_cut_from_urls_in_stderr() {
        assert_eq!(
            strip_credentials("fatal: unable to access 'https://user:tok3n@git.example.com/acme/app.git/': 403"),
            "fatal: unable to access 'https://git.example.com/acme/app.git/': 403"
        );
        assert_eq!(
            strip_credentials("https://only-user@host/x and https://a:b@host/y"),
            "https://host/x and https://host/y"
        );
        // No secret in an scp-style address: nothing to cut. Text without URLs is kept.
        assert_eq!(
            strip_credentials("git@host:acme/app.git: Permission denied"),
            "git@host:acme/app.git: Permission denied"
        );
        assert_eq!(strip_credentials("plain error"), "plain error");
    }

    #[test]
    fn stderr_keeps_only_its_last_two_kilobytes_on_a_character_boundary() {
        let mut long = "a".repeat(5000);
        long.push_str("ЫЫЫ END");
        let tail = stderr_tail(long.as_bytes());
        assert!(tail.len() <= STDERR_TAIL_BYTES, "{}", tail.len());
        assert!(tail.ends_with("END"));
        assert_eq!(stderr_tail(b"short"), "short");
    }

    #[tokio::test]
    async fn an_existing_destination_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let bare = origin(dir.path());
        let dest = dir.path().join("taken");
        std::fs::create_dir(&dest).unwrap();
        let err = clone_repo(&format!("file://{}", bare.display()), &dest)
            .await
            .unwrap_err();
        assert!(matches!(err, CloneError::Fs(FsError::AlreadyExists(_))), "{err:?}");
    }

    #[tokio::test]
    async fn a_missing_parent_or_a_relative_destination_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let bare = format!("file://{}", origin(dir.path()).display());
        let err = clone_repo(&bare, &dir.path().join("no/such/parent/app"))
            .await
            .unwrap_err();
        assert!(matches!(err, CloneError::Fs(FsError::NotFound(_))), "{err:?}");
        let err = clone_repo(&bare, Path::new("relative/app")).await.unwrap_err();
        assert!(matches!(err, CloneError::Fs(FsError::InvalidPath(_))), "{err:?}");
    }

    #[tokio::test]
    async fn a_local_bare_repository_clones_with_its_default_branch() {
        let dir = tempfile::tempdir().unwrap();
        let bare = origin(dir.path());
        let dest = dir.path().join("app");
        let cloned = clone_repo(&format!("file://{}", bare.display()), &dest).await.unwrap();
        assert_eq!(cloned.path, dest.display().to_string());
        assert_eq!(cloned.default_branch.as_deref(), Some("main"));
        assert_eq!(std::fs::read_to_string(dest.join("README.md")).unwrap(), "hello\n");
    }

    #[tokio::test]
    async fn a_failed_clone_reports_stderr_and_leaves_no_folder() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("app");
        let err = clone_repo(&format!("file://{}/missing.git", dir.path().display()), &dest)
            .await
            .unwrap_err();
        match err {
            CloneError::Failed { stderr } => assert!(!stderr.is_empty()),
            other => panic!("expected Failed, got {other:?}"),
        }
        assert!(!dest.exists());
    }

    #[tokio::test]
    async fn a_clone_past_its_timeout_is_killed_and_reported() {
        let dir = tempfile::tempdir().unwrap();
        let bare = origin(dir.path());
        let dest = dir.path().join("app");
        let err = clone_with_timeout(&format!("file://{}", bare.display()), &dest, Duration::ZERO)
            .await
            .unwrap_err();
        assert!(matches!(err, CloneError::Failed { .. }), "{err:?}");
        assert!(!dest.exists());
    }

    #[tokio::test]
    async fn credentials_do_not_come_back_in_the_error() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("app");
        // Port 9 on localhost refuses at once; git may echo the URL in its message.
        let err = clone_repo("https://user:s3cr3t-pass@127.0.0.1:9/acme/app.git", &dest)
            .await
            .unwrap_err();
        match err {
            CloneError::Failed { stderr } => assert!(!stderr.contains("s3cr3t-pass"), "{stderr}"),
            other => panic!("expected Failed, got {other:?}"),
        }
    }
}
