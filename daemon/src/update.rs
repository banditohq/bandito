//! Self-update: the daemon looks up the newest GitHub release and installs it, but only a release whose
//! `SHA256SUMS` carries a valid signature from the release key. Nothing installs by itself: the owner
//! asks (`bandito update`, or the app's `daemon.update_apply`). See docs/ARCHITECTURE.md#self-update.

use crate::service::{self, Mode, Paths, Status};
use anyhow::{Context, Result, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// Public key of the release signing key: Ed25519, raw 32 bytes, base64. The same key as
/// `RELEASE_PUBKEY` in `scripts/install.sh` (as SPKI); a test keeps the two equal.
pub const RELEASE_PUBKEY_B64: &str = "0H7rMV2eLDmjqQ403ipWCERN6K+aZNuWTW5IKuLSpWY=";
/// Releases of the public repository. `.../releases/latest` redirects to `.../releases/tag/<tag>`.
pub const RELEASES_URL: &str = "https://github.com/banditohq/bandito/releases";
pub const SUMS_FILE: &str = "SHA256SUMS";
pub const SUMS_SIG_FILE: &str = "SHA256SUMS.sig";
/// File in the data directory where the daemon records its listen address (the same one `main` writes).
const LISTEN_FILE: &str = "listen";
/// The first background check runs this long after the daemon starts, then one per day.
pub const FIRST_CHECK_AFTER: Duration = Duration::from_secs(10 * 60);
pub const CHECK_EVERY: Duration = Duration::from_secs(24 * 60 * 60);
/// A restart requested over RPC waits this long, so the reply reaches the app first.
const RESTART_AFTER_REPLY: Duration = Duration::from_secs(1);

/// Params of `daemon.update_apply`.
#[derive(Debug, Deserialize)]
pub struct ApplyParams {
    /// `X.Y.Z` or `vX.Y.Z`.
    pub version: String,
}

/// What `daemon.update_check` and `bandito update --check` report. Versions are `X.Y.Z`, without `v`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct UpdateInfo {
    pub current: String,
    pub latest: String,
    pub available: bool,
}

/// `MAJOR.MINOR.PATCH`, compared field by field (so 1.10.0 is newer than 1.9.9).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(pub u64, pub u64, pub u64);

impl Version {
    /// Digits and dots only, exactly three fields. No `v` prefix, no pre-release part.
    pub fn parse(s: &str) -> Result<Version> {
        let parts: Vec<&str> = s.split('.').collect();
        let [major, minor, patch] = parts.as_slice() else {
            bail!("not a version: {s} (expected X.Y.Z)");
        };
        let field = |p: &str| -> Result<u64> {
            if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
                bail!("not a version: {s} (expected X.Y.Z)");
            }
            p.parse::<u64>()
                .map_err(|_| anyhow!("not a version: {s} (expected X.Y.Z)"))
        };
        Ok(Version(field(major)?, field(minor)?, field(patch)?))
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

/// The version of a release tag: `vX.Y.Z`.
pub fn parse_tag(tag: &str) -> Result<Version> {
    let body = tag
        .strip_prefix('v')
        .with_context(|| format!("not a release tag: {tag} (expected vX.Y.Z)"))?;
    Version::parse(body).with_context(|| format!("not a release tag: {tag} (expected vX.Y.Z)"))
}

/// The tag from the URL that `.../releases/latest` finally resolved to.
pub fn tag_from_url(url: &str) -> Result<String> {
    let (_, tag) = url
        .rsplit_once("/releases/tag/")
        .with_context(|| format!("no release found: {url} is not a release tag page"))?;
    if tag.is_empty() || tag.contains(['/', '?', '#']) {
        bail!("unexpected release URL: {url}");
    }
    Ok(tag.to_string())
}

/// How the update reaches the network. The daemon uses [`Curl`]; tests inject a fake.
pub trait Fetcher {
    /// The URL that `url` ends at after redirects. The body is not downloaded.
    fn effective_url(&self, url: &str) -> Result<String>;
    /// Save the body of `url` as `dest`.
    fn download(&self, url: &str, dest: &Path) -> Result<()>;
}

/// The real fetcher: `curl`, https only, TLS 1.2 or newer, as in `scripts/install.sh`.
pub struct Curl;

impl Fetcher for Curl {
    fn effective_url(&self, url: &str) -> Result<String> {
        let out = Command::new("curl")
            .args([
                "-fsSL",
                "--proto",
                "=https",
                "--tlsv1.2",
                "--max-time",
                "60",
                "-o",
                "/dev/null",
                "-w",
                "%{url_effective}",
                url,
            ])
            .stdin(Stdio::null())
            .output()
            .context("cannot run curl")?;
        if !out.status.success() {
            return Err(latest_lookup_error(&String::from_utf8_lossy(&out.stderr)));
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    fn download(&self, url: &str, dest: &Path) -> Result<()> {
        let out = Command::new("curl")
            .args([
                "-fsSL",
                "--proto",
                "=https",
                "--tlsv1.2",
                "--retry",
                "3",
                "--max-time",
                "600",
                "-o",
            ])
            .arg(dest)
            .arg(url)
            .stdin(Stdio::null())
            .output()
            .context("cannot run curl")?;
        if !out.status.success() {
            bail!(
                "download failed: {url}: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(())
    }
}

/// The error for a failed `releases/latest` lookup, from curl's stderr. `-f` makes a missing page exit 22
/// with `returned error: 404`: GitHub answers that while the repository has no published release.
pub fn latest_lookup_error(stderr: &str) -> anyhow::Error {
    if stderr.contains("returned error: 404") {
        anyhow!("no releases published yet")
    } else {
        anyhow!("cannot reach GitHub: {}", stderr.trim())
    }
}

/// The release key the daemon carries.
pub fn release_key() -> Result<VerifyingKey> {
    verifying_key_from_b64(RELEASE_PUBKEY_B64)
}

fn verifying_key_from_b64(s: &str) -> Result<VerifyingKey> {
    let bytes = STANDARD.decode(s).context("release key is not base64")?;
    let raw: [u8; 32] = bytes.try_into().map_err(|_| anyhow!("release key is not 32 bytes"))?;
    VerifyingKey::from_bytes(&raw).context("release key is not a valid Ed25519 key")
}

/// Checks the base64 signature of `sums` (the exact bytes of `SHA256SUMS`).
pub fn verify_signature(key: &VerifyingKey, sums: &[u8], sig_b64: &str) -> Result<()> {
    let sig_bytes = STANDARD
        .decode(sig_b64.trim())
        .map_err(|_| anyhow!("signature check failed: the signature file is not base64"))?;
    let raw: [u8; 64] = sig_bytes
        .try_into()
        .map_err(|_| anyhow!("signature check failed: the signature is not 64 bytes"))?;
    key.verify_strict(sums, &Signature::from_bytes(&raw))
        .map_err(|_| anyhow!("signature check failed: SHA256SUMS is not signed by the Bandito release key"))
}

fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The SHA-256 of `asset` in a `SHA256SUMS` file. Lines are `<hash>  <name>` or `<hash> *<name>`.
pub fn sums_lookup(sums: &str, asset: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let (hash, rest) = line.trim_end().split_once(' ')?;
        let name = rest.trim_start_matches(' ');
        let name = name.strip_prefix('*').unwrap_or(name);
        (name == asset && is_sha256_hex(hash)).then(|| hash.to_ascii_lowercase())
    })
}

/// The release asset for this machine, as in `scripts/install.sh` (`x86_64|aarch64` × `unknown-linux-gnu|apple-darwin`).
pub fn asset_name() -> Result<String> {
    let os = match std::env::consts::OS {
        "linux" => "unknown-linux-gnu",
        "macos" => "apple-darwin",
        other => bail!("self-update works on Linux and macOS only, not {other}"),
    };
    let arch = match std::env::consts::ARCH {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        other => bail!("self-update works on x86_64 and aarch64 only, not {other}"),
    };
    Ok(format!("bandito-{arch}-{os}.tar.gz"))
}

/// The newest release, from the redirect of `releases/latest`, compared with `current`.
pub fn check(fetcher: &dyn Fetcher, current: &str) -> Result<UpdateInfo> {
    let current_v = Version::parse(current)?;
    let url = format!("{RELEASES_URL}/latest");
    let tag = tag_from_url(&fetcher.effective_url(&url)?)?;
    let latest = parse_tag(&tag)?;
    Ok(UpdateInfo {
        current: current_v.to_string(),
        latest: latest.to_string(),
        available: latest > current_v,
    })
}

/// Installs release `version` (`X.Y.Z`) over `exe`. The checks run in this order, and nothing is replaced
/// before all of them pass: not a downgrade (unless `allow_downgrade`), the signature of `SHA256SUMS`,
/// the archive is listed there and its SHA-256 matches, and the archive's `bandito --version` says
/// `bandito <version>`. Returns the installed version. Temporary files live in `<home>/run/update-*`.
pub fn apply(
    fetcher: &dyn Fetcher,
    key: &VerifyingKey,
    home: &Path,
    exe: &Path,
    current: &str,
    version: &str,
    allow_downgrade: bool,
) -> Result<String> {
    let current_v = Version::parse(current)?;
    let target = Version::parse(version.strip_prefix('v').unwrap_or(version))?;
    if target == current_v {
        bail!("already running {target}");
    }
    if target < current_v && !allow_downgrade {
        bail!("downgrade refused: {target} is older than {current_v} (use --allow-downgrade)");
    }
    let asset = asset_name()?;
    let base = format!("{RELEASES_URL}/download/v{target}");
    let work = WorkDir::create(home)?;

    let sums_path = work.path().join(SUMS_FILE);
    fetcher.download(&format!("{base}/{SUMS_FILE}"), &sums_path)?;
    let sig_path = work.path().join(SUMS_SIG_FILE);
    fetcher.download(&format!("{base}/{SUMS_SIG_FILE}"), &sig_path)?;
    let sums = std::fs::read(&sums_path).with_context(|| format!("read {}", sums_path.display()))?;
    let sig = std::fs::read_to_string(&sig_path).unwrap_or_default();
    verify_signature(key, &sums, &sig)?;
    let sums_text = String::from_utf8_lossy(&sums);
    let expected = sums_lookup(&sums_text, &asset)
        .ok_or_else(|| anyhow!("asset not listed: {asset} is not in the signed SHA256SUMS of v{target}"))?;

    let archive = work.path().join(&asset);
    fetcher.download(&format!("{base}/{asset}"), &archive)?;
    if sha256_file(&archive)? != expected {
        bail!("checksum mismatch for {asset}: the download is corrupt or was tampered with");
    }

    let unpack = work.path().join("unpack");
    std::fs::create_dir(&unpack).with_context(|| format!("create {}", unpack.display()))?;
    let tar = Command::new("tar")
        .arg("-xzf")
        .arg(&archive)
        .arg("-C")
        .arg(&unpack)
        .stdin(Stdio::null())
        .output()
        .context("cannot run tar")?;
    if !tar.status.success() {
        bail!("cannot unpack {asset}: {}", String::from_utf8_lossy(&tar.stderr).trim());
    }
    let new_bin = unpack.join("bandito");
    if !new_bin.is_file() {
        bail!("archive has no bandito binary");
    }
    std::fs::set_permissions(&new_bin, std::fs::Permissions::from_mode(0o755))
        .with_context(|| format!("chmod {}", new_bin.display()))?;
    let said = Command::new(&new_bin)
        .arg("--version")
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run the new {}", new_bin.display()))?;
    let answer = String::from_utf8_lossy(&said.stdout).trim().to_string();
    let want = format!("bandito {target}");
    if answer != want {
        bail!("version mismatch: the archive holds \"{answer}\", expected \"{want}\"");
    }

    replace_exe(&new_bin, exe)?;
    Ok(target.to_string())
}

/// Temporary directory `<home>/run/update-<id>` (0700), removed when dropped.
struct WorkDir(PathBuf);

impl WorkDir {
    fn create(home: &Path) -> Result<Self> {
        let parent = home.join("run");
        std::fs::create_dir_all(&parent).with_context(|| format!("create {}", parent.display()))?;
        let dir = parent.join(format!("update-{}", crate::store::new_id()));
        std::fs::create_dir(&dir).with_context(|| format!("create {}", dir.display()))?;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
            .with_context(|| format!("chmod {}", dir.display()))?;
        Ok(WorkDir(dir))
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for WorkDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path).with_context(|| format!("open {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = file
            .read(&mut buf)
            .with_context(|| format!("read {}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Puts `new_bin` in place of `exe`: a copy next to `exe`, then one rename. A running daemon keeps its old
/// inode, and nobody ever sees a half-written binary.
fn replace_exe(new_bin: &Path, exe: &Path) -> Result<()> {
    let dir = exe.parent().context("the bandito binary has no directory")?;
    let staged = dir.join(format!(".bandito.new.{}", std::process::id()));
    let result = (|| -> Result<()> {
        std::fs::copy(new_bin, &staged).with_context(|| format!("copy to {}", staged.display()))?;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))
            .with_context(|| format!("chmod {}", staged.display()))?;
        std::fs::rename(&staged, exe).with_context(|| format!("replace {}", exe.display()))?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&staged);
    }
    result
}

/// How the new binary gets running. Only a daemon that a service manager started is restarted;
/// anything else is `Manual`, and the user restarts it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Restart {
    /// systemd user unit: `systemctl --user restart`.
    Systemd,
    /// launchd agent: `launchctl kickstart -k`.
    Launchd {
        uid: u32,
    },
    /// Background process: a new one starts once `pid` has exited, then `pid` gets SIGTERM.
    Background {
        pid: u32,
        /// The binary and its arguments, as `service install` starts the daemon.
        argv: Vec<String>,
        log: PathBuf,
        pid_file: PathBuf,
    },
    Manual,
}

/// The restart for the running daemon, from its service status. `argv` is the command line of a new daemon.
pub fn restart_plan(status: &Status, uid: u32, paths: &Paths, argv: Vec<String>) -> Restart {
    let (Some(mode), Some(pid), true) = (status.mode, status.pid, status.running) else {
        return Restart::Manual;
    };
    match mode {
        Mode::Systemd => Restart::Systemd,
        Mode::Launchd => Restart::Launchd { uid },
        Mode::Background => Restart::Background {
            pid,
            argv,
            log: paths.log_file.clone(),
            pid_file: paths.pid_file.clone(),
        },
    }
}

/// The command line a daemon is started with: this binary, `--home` when the data directory is not the
/// default one, then `daemon --listen <address>` (the address the daemon wrote to `<home>/listen`).
pub fn daemon_argv(home: &Path, user_home: &Path, exe: &Path) -> Vec<String> {
    let listen = std::fs::read_to_string(home.join(LISTEN_FILE))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| service::DEFAULT_LISTEN.to_string());
    let home_override = (home != user_home.join(".bandito")).then_some(home);
    let mut argv = vec![exe.display().to_string()];
    argv.extend(service::daemon_args(&listen, home_override));
    argv
}

/// Starts the restart. For systemd and launchd the service manager stops the old daemon, so the caller
/// may be that daemon and must answer first. For background it stops the old daemon with SIGTERM.
pub fn run_restart(restart: &Restart) -> Result<()> {
    match restart {
        Restart::Manual => Ok(()),
        Restart::Systemd => run_quiet(&["systemctl", "--user", "--no-block", "restart", service::UNIT_NAME]),
        Restart::Launchd { uid } => {
            run_quiet(&["launchctl", "kickstart", "-k", &format!("gui/{uid}/{}", service::LABEL)])
        }
        Restart::Background {
            pid,
            argv,
            log,
            pid_file,
        } => {
            start_after_exit(*pid, argv, log, pid_file)?;
            terminate(*pid);
            Ok(())
        }
    }
}

fn run_quiet(argv: &[&str]) -> Result<()> {
    let out = Command::new(argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {}", argv[0]))?;
    if !out.status.success() {
        bail!(
            "`{}` failed: {}",
            argv.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// Starts `argv` after process `pid` exits (up to 30 s), in its own process group, with output appended to
/// `log`. The shell execs the daemon, so its pid is the daemon's pid, which goes to `pid_file`.
fn start_after_exit(pid: u32, argv: &[String], log: &Path, pid_file: &Path) -> Result<()> {
    const WAIT_THEN_EXEC: &str =
        r#"i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done; shift; exec "$@""#;
    if let Some(dir) = log.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .with_context(|| format!("open {}", log.display()))?;
    let err = out.try_clone().context("duplicate log handle")?;
    let child = Command::new("sh")
        .arg("-c")
        .arg(WAIT_THEN_EXEC)
        .arg("sh")
        .arg(pid.to_string())
        .args(argv)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        // Own process group: a hangup of the SSH session that ran `bandito update` does not reach it.
        .process_group(0)
        .spawn()
        .context("start the new daemon")?;
    std::fs::write(pid_file, format!("{}\n", child.id())).with_context(|| format!("write {}", pid_file.display()))?;
    Ok(())
}

fn terminate(pid: u32) {
    // SAFETY: plain kill(2) on a pid that is the running bandito daemon (the caller found it on the socket).
    unsafe {
        libc::kill(pid as libc::pid_t, libc::SIGTERM);
    }
}

/// The data directory of this daemon (`--home`). Set once by `main`; before that, the default one.
static DATA_HOME: OnceLock<PathBuf> = OnceLock::new();

pub fn set_data_home(home: &Path) {
    let _ = DATA_HOME.set(home.to_path_buf());
}

fn data_home() -> PathBuf {
    DATA_HOME.get().cloned().unwrap_or_else(crate::setup::default_home)
}

/// The last successful check: the result and when it ran (Unix milliseconds). `daemon.info` shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CheckedUpdate {
    #[serde(flatten)]
    pub info: UpdateInfo,
    pub checked_at: i64,
}

static LAST_CHECK: Mutex<Option<CheckedUpdate>> = Mutex::new(None);

/// The last successful check, or `None` when none has succeeded since start.
pub fn last_check() -> Option<CheckedUpdate> {
    LAST_CHECK.lock().ok().and_then(|g| g.clone())
}

fn remember(info: &UpdateInfo, checked_at: i64) {
    if let Ok(mut slot) = LAST_CHECK.lock() {
        *slot = Some(CheckedUpdate {
            info: info.clone(),
            checked_at,
        });
    }
}

/// The newest release, looked up with curl on a blocking thread. A successful check is remembered
/// for `daemon.info` (the background check goes through here too).
pub async fn check_async(current: &str) -> Result<UpdateInfo> {
    let current = current.to_string();
    let info = tokio::task::spawn_blocking(move || check(&Curl, &current))
        .await
        .context("update check stopped")??;
    remember(&info, crate::store::now_ms());
    Ok(info)
}

/// Installs `version` over `exe`, from a blocking thread. Returns the installed version.
pub async fn apply_async(
    home: PathBuf,
    exe: PathBuf,
    current: String,
    version: String,
    allow_downgrade: bool,
) -> Result<String> {
    tokio::task::spawn_blocking(move || -> Result<String> {
        let key = release_key()?;
        apply(&Curl, &key, &home, &exe, &current, &version, allow_downgrade)
    })
    .await
    .context("update stopped")?
}

/// The restart that fits the daemon running in `home`, from its service status.
pub async fn restart_for(home: &Path, exe: &Path) -> Result<Restart> {
    let user_home = dirs::home_dir().context("no home directory")?;
    let paths = Paths::new(home, &user_home);
    let status = service::status(&paths).await;
    let (_, uid) = service::current_user()?;
    Ok(restart_plan(&status, uid, &paths, daemon_argv(home, &user_home, exe)))
}

static APPLYING: AtomicBool = AtomicBool::new(false);

/// Clears the busy flag of `APPLYING` when an update ends, however it ends.
struct BusyGuard;

impl Drop for BusyGuard {
    fn drop(&mut self) {
        APPLYING.store(false, Ordering::SeqCst);
    }
}

/// `daemon.update_apply`: installs `version` over this daemon's binary. When a service manager runs the
/// daemon, it is restarted a moment later, after the reply is sent. Returns whether a restart was scheduled.
pub async fn rpc_apply(version: &str) -> Result<bool> {
    if APPLYING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        bail!("busy: an update is already running");
    }
    let _busy = BusyGuard;
    let home = data_home();
    let exe = std::env::current_exe()?
        .canonicalize()
        .context("resolve the path of the bandito binary")?;
    apply_async(
        home.clone(),
        exe.clone(),
        crate::rpc::VERSION.to_string(),
        version.to_string(),
        false,
    )
    .await?;
    let restart = restart_for(&home, &exe).await?;
    if restart == Restart::Manual {
        return Ok(false);
    }
    tokio::spawn(async move {
        tokio::time::sleep(RESTART_AFTER_REPLY).await;
        match tokio::task::spawn_blocking(move || run_restart(&restart)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => tracing::error!("restart after update failed: {e:#}"),
            Err(e) => tracing::error!("restart after update stopped: {e}"),
        }
    });
    Ok(true)
}

/// Calls `on_available` when a newer release exists: once, 10 minutes after start, then every 24 hours.
/// Nothing is installed here.
pub fn spawn_background_check(current: &'static str, on_available: impl Fn(UpdateInfo) + Send + 'static) {
    tokio::spawn(async move {
        tokio::time::sleep(FIRST_CHECK_AFTER).await;
        loop {
            match check_async(current).await {
                Ok(info) if info.available => on_available(info),
                Ok(_) => {}
                Err(e) => tracing::debug!("update check: {e:#}"),
            }
            tokio::time::sleep(CHECK_EVERY).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use std::cell::RefCell;
    use std::collections::HashMap;

    const SPKI_PREFIX: [u8; 12] = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];

    /// Serves files from memory and remembers what was asked for.
    struct FakeFetcher {
        files: HashMap<String, Vec<u8>>,
        final_url: String,
        requested: RefCell<Vec<String>>,
    }

    impl FakeFetcher {
        fn new(files: HashMap<String, Vec<u8>>) -> Self {
            FakeFetcher {
                files,
                final_url: format!("{RELEASES_URL}/tag/v0.2.0"),
                requested: RefCell::new(Vec::new()),
            }
        }
    }

    impl Fetcher for FakeFetcher {
        fn effective_url(&self, _url: &str) -> Result<String> {
            Ok(self.final_url.clone())
        }

        fn download(&self, url: &str, dest: &Path) -> Result<()> {
            self.requested.borrow_mut().push(url.to_string());
            let body = self.files.get(url).with_context(|| format!("no such asset {url}"))?;
            std::fs::write(dest, body)?;
            Ok(())
        }
    }

    fn test_key() -> SigningKey {
        SigningKey::from_bytes(&[7u8; 32])
    }

    /// Files of a signed fake release `version`. The archive holds a shell script that answers
    /// `--version` with `answer`. `asset_override` names the archive in `SHA256SUMS` instead of the real name.
    fn fake_release(
        scratch: &Path,
        version: &str,
        answer: &str,
        signer: &SigningKey,
        asset_override: Option<&str>,
    ) -> HashMap<String, Vec<u8>> {
        let src = scratch.join("src");
        std::fs::create_dir_all(&src).unwrap();
        let script = format!("#!/bin/sh\necho \"{answer}\"\n");
        std::fs::write(src.join("bandito"), script).unwrap();
        std::fs::set_permissions(src.join("bandito"), std::fs::Permissions::from_mode(0o755)).unwrap();
        let archive = scratch.join("archive.tar.gz");
        let status = Command::new("tar")
            .arg("-czf")
            .arg(&archive)
            .arg("-C")
            .arg(&src)
            .arg("bandito")
            .status()
            .unwrap();
        assert!(status.success());
        let bytes = std::fs::read(&archive).unwrap();
        let asset = asset_override
            .map(str::to_string)
            .unwrap_or_else(|| asset_name().unwrap());
        let hash = hex::encode(Sha256::digest(&bytes));
        let sums = format!("{hash}  {asset}\n").into_bytes();
        let sig = STANDARD.encode(signer.sign(&sums).to_bytes());
        let base = format!("{RELEASES_URL}/download/v{version}");
        HashMap::from([
            (format!("{base}/{SUMS_FILE}"), sums),
            (format!("{base}/{SUMS_SIG_FILE}"), sig.into_bytes()),
            (format!("{base}/{asset}"), bytes),
        ])
    }

    fn base_of(version: &str) -> String {
        format!("{RELEASES_URL}/download/v{version}")
    }

    /// A temp home and a fake running binary inside it.
    fn setup() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let exe = dir.path().join("bin").join("bandito");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, "old binary").unwrap();
        (dir, home, exe)
    }

    fn run_dir_is_empty(home: &Path) -> bool {
        std::fs::read_dir(home.join("run"))
            .map(|mut d| d.next().is_none())
            .unwrap_or(true)
    }

    #[test]
    fn versions_compare_numerically() {
        assert!(Version::parse("1.10.0").unwrap() > Version::parse("1.9.9").unwrap());
        assert_eq!(Version::parse("0.1.0").unwrap(), Version::parse("0.1.0").unwrap());
        assert!(Version::parse("0.2.0").unwrap() < Version::parse("0.10.0").unwrap());
        assert_eq!(Version::parse("1.2.3").unwrap().to_string(), "1.2.3");
    }

    #[test]
    fn malformed_versions_are_errors() {
        for bad in [
            "",
            "garbage",
            "1.2",
            "1.2.3.4",
            "1.2.3-rc1",
            "v1.2.3",
            "a.b.c",
            "1..3",
            "1.2.-3",
        ] {
            assert!(Version::parse(bad).is_err(), "{bad} must not parse");
        }
        assert_eq!(parse_tag("v1.2.3").unwrap(), Version(1, 2, 3));
        assert!(parse_tag("1.2.3").is_err(), "a tag needs the v");
    }

    #[test]
    fn tag_comes_from_the_redirect_url() {
        let url = format!("{RELEASES_URL}/tag/v0.3.1");
        assert_eq!(tag_from_url(&url).unwrap(), "v0.3.1");
        assert!(tag_from_url(RELEASES_URL).is_err(), "no tag page, no release");
        assert!(tag_from_url(&format!("{RELEASES_URL}/tag/v0.3.1/extra")).is_err());
        assert!(tag_from_url(&format!("{RELEASES_URL}/tag/")).is_err());
    }

    #[test]
    fn check_reports_newer_and_older_releases() {
        let fake = FakeFetcher::new(HashMap::new());
        let newer = check(&fake, "0.1.0").unwrap();
        assert_eq!(
            newer,
            UpdateInfo {
                current: "0.1.0".into(),
                latest: "0.2.0".into(),
                available: true
            }
        );
        let same = check(&fake, "0.2.0").unwrap();
        assert!(!same.available);
        let ahead = check(&fake, "0.3.0").unwrap();
        assert!(!ahead.available, "a build ahead of the release is not an update");
    }

    #[test]
    fn a_missing_release_page_says_there_are_no_releases() {
        let no_release = "curl: (22) The requested URL returned error: 404\n";
        assert_eq!(latest_lookup_error(no_release).to_string(), "no releases published yet");
        let offline = "curl: (6) Could not resolve host: github.com\n";
        assert_eq!(
            latest_lookup_error(offline).to_string(),
            "cannot reach GitHub: curl: (6) Could not resolve host: github.com"
        );
    }

    #[test]
    fn last_check_is_remembered_with_its_time() {
        let info = UpdateInfo {
            current: "0.1.0".into(),
            latest: "0.2.0".into(),
            available: true,
        };
        remember(&info, 1_700_000_000_000);
        let last = last_check().unwrap();
        assert_eq!(last.info, info);
        let v = serde_json::to_value(&last).unwrap();
        assert_eq!(v["current"], "0.1.0");
        assert_eq!(v["latest"], "0.2.0");
        assert_eq!(v["available"], true);
        assert_eq!(v["checked_at"], 1_700_000_000_000i64);
    }

    #[test]
    fn release_key_matches_install_script() {
        let script = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../scripts/install.sh")).unwrap();
        let spki_b64 = script
            .lines()
            .find_map(|l| l.strip_prefix("RELEASE_PUBKEY=\"")?.strip_suffix('"'))
            .expect("RELEASE_PUBKEY in install.sh");
        let spki = STANDARD.decode(spki_b64).unwrap();
        assert_eq!(spki.len(), 44, "Ed25519 SPKI is 44 bytes");
        assert_eq!(spki[..12], SPKI_PREFIX);
        assert_eq!(STANDARD.encode(&spki[12..]), RELEASE_PUBKEY_B64);
        release_key().unwrap();
    }

    #[test]
    fn sums_lines_with_and_without_star() {
        let hash = "a".repeat(64);
        let text =
            format!("{hash}  bandito-x86_64-unknown-linux-gnu.tar.gz\n{hash} *bandito-aarch64-apple-darwin.tar.gz\n");
        assert_eq!(
            sums_lookup(&text, "bandito-x86_64-unknown-linux-gnu.tar.gz"),
            Some(hash.clone())
        );
        assert_eq!(
            sums_lookup(&text, "bandito-aarch64-apple-darwin.tar.gz"),
            Some(hash.clone())
        );
        assert_eq!(sums_lookup(&text, "bandito-other.tar.gz"), None);
        assert_eq!(
            sums_lookup("zz  bandito-x.tar.gz\n", "bandito-x.tar.gz"),
            None,
            "not a sha-256"
        );
    }

    #[test]
    fn signature_must_match_the_key_and_the_bytes() {
        let key = test_key();
        let sums = b"hash  bandito-x.tar.gz\n";
        let sig = STANDARD.encode(key.sign(sums).to_bytes());
        let vk = key.verifying_key();
        verify_signature(&vk, sums, &sig).unwrap();

        let tampered = b"hash  bandito-evil.tar.gz\n";
        let err = verify_signature(&vk, tampered, &sig).unwrap_err();
        assert!(format!("{err:#}").starts_with("signature check failed"), "{err:#}");

        let other = SigningKey::from_bytes(&[9u8; 32]).verifying_key();
        let err = verify_signature(&other, sums, &sig).unwrap_err();
        assert!(format!("{err:#}").contains("signature check failed"));

        let err = verify_signature(&vk, sums, "bm90IGEgc2ln").unwrap_err();
        assert!(format!("{err:#}").contains("signature check failed"));
    }

    #[test]
    fn apply_installs_a_signed_release() {
        let (dir, home, exe) = setup();
        let key = test_key();
        let files = fake_release(dir.path(), "0.2.0", "bandito 0.2.0", &key, None);
        let fake = FakeFetcher::new(files);
        let installed = apply(&fake, &key.verifying_key(), &home, &exe, "0.1.0", "0.2.0", false).unwrap();
        assert_eq!(installed, "0.2.0");
        let body = std::fs::read_to_string(&exe).unwrap();
        assert!(body.contains("bandito 0.2.0"), "new binary in place: {body}");
        let mode = std::fs::metadata(&exe).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o755);
        assert!(run_dir_is_empty(&home), "the temporary directory is removed");
        assert!(
            !exe.parent()
                .unwrap()
                .join(format!(".bandito.new.{}", std::process::id()))
                .exists()
        );
    }

    #[test]
    fn a_bad_signature_replaces_nothing_and_fetches_no_archive() {
        let (dir, home, exe) = setup();
        let key = test_key();
        let mut files = fake_release(dir.path(), "0.2.0", "bandito 0.2.0", &key, None);
        let sums_url = format!("{}/{SUMS_FILE}", base_of("0.2.0"));
        files.insert(
            sums_url,
            format!("{}  {}\n", "b".repeat(64), asset_name().unwrap()).into_bytes(),
        );
        let fake = FakeFetcher::new(files);
        let err = apply(&fake, &key.verifying_key(), &home, &exe, "0.1.0", "0.2.0", false).unwrap_err();
        assert!(format!("{err:#}").contains("signature check failed"), "{err:#}");
        assert_eq!(std::fs::read_to_string(&exe).unwrap(), "old binary");
        assert!(run_dir_is_empty(&home));
        let archive_url = format!("{}/{}", base_of("0.2.0"), asset_name().unwrap());
        assert!(
            !fake.requested.borrow().contains(&archive_url),
            "archive is not fetched before the signature passes"
        );
    }

    #[test]
    fn a_wrong_hash_is_a_checksum_mismatch() {
        let (dir, home, exe) = setup();
        let key = test_key();
        let asset = asset_name().unwrap();
        let mut files = fake_release(dir.path(), "0.2.0", "bandito 0.2.0", &key, None);
        // Signed, but the hash of another archive.
        let sums = format!("{}  {asset}\n", "c".repeat(64)).into_bytes();
        let sig = STANDARD.encode(key.sign(&sums).to_bytes());
        files.insert(format!("{}/{SUMS_FILE}", base_of("0.2.0")), sums);
        files.insert(format!("{}/{SUMS_SIG_FILE}", base_of("0.2.0")), sig.into_bytes());
        let fake = FakeFetcher::new(files);
        let err = apply(&fake, &key.verifying_key(), &home, &exe, "0.1.0", "0.2.0", false).unwrap_err();
        assert!(format!("{err:#}").contains("checksum mismatch"), "{err:#}");
        assert_eq!(std::fs::read_to_string(&exe).unwrap(), "old binary");
        assert!(run_dir_is_empty(&home));
    }

    #[test]
    fn an_archive_missing_from_the_sums_is_refused() {
        let (dir, home, exe) = setup();
        let key = test_key();
        let files = fake_release(
            dir.path(),
            "0.2.0",
            "bandito 0.2.0",
            &key,
            Some("bandito-other-target.tar.gz"),
        );
        let fake = FakeFetcher::new(files);
        let err = apply(&fake, &key.verifying_key(), &home, &exe, "0.1.0", "0.2.0", false).unwrap_err();
        assert!(format!("{err:#}").contains("asset not listed"), "{err:#}");
        assert_eq!(std::fs::read_to_string(&exe).unwrap(), "old binary");
    }

    #[test]
    fn a_binary_with_another_version_is_refused() {
        let (dir, home, exe) = setup();
        let key = test_key();
        let files = fake_release(dir.path(), "0.2.0", "bandito 0.2.1", &key, None);
        let fake = FakeFetcher::new(files);
        let err = apply(&fake, &key.verifying_key(), &home, &exe, "0.1.0", "0.2.0", false).unwrap_err();
        assert!(format!("{err:#}").contains("version mismatch"), "{err:#}");
        assert_eq!(std::fs::read_to_string(&exe).unwrap(), "old binary");
        assert!(run_dir_is_empty(&home));
    }

    #[test]
    fn downgrade_is_refused_unless_allowed() {
        let (dir, home, exe) = setup();
        let key = test_key();
        let fake = FakeFetcher::new(HashMap::new());
        let err = apply(&fake, &key.verifying_key(), &home, &exe, "0.3.0", "0.2.0", false).unwrap_err();
        assert!(format!("{err:#}").contains("downgrade refused"), "{err:#}");
        assert!(fake.requested.borrow().is_empty(), "refused before any download");

        let files = fake_release(dir.path(), "0.2.0", "bandito 0.2.0", &key, None);
        let fake = FakeFetcher::new(files);
        let installed = apply(&fake, &key.verifying_key(), &home, &exe, "0.3.0", "0.2.0", true).unwrap();
        assert_eq!(installed, "0.2.0");
        assert!(std::fs::read_to_string(&exe).unwrap().contains("bandito 0.2.0"));
    }

    #[test]
    fn the_same_version_is_not_installed_again() {
        let (_dir, home, exe) = setup();
        let key = test_key();
        let fake = FakeFetcher::new(HashMap::new());
        let err = apply(&fake, &key.verifying_key(), &home, &exe, "0.2.0", "v0.2.0", false).unwrap_err();
        assert!(format!("{err:#}").contains("already running"));
        assert!(fake.requested.borrow().is_empty());
    }

    #[test]
    fn restart_follows_the_service_that_runs_this_daemon() {
        let paths = Paths::new(Path::new("/h/.bandito"), Path::new("/h"));
        let argv = vec!["/bin/bandito".to_string(), "daemon".to_string()];
        let running = |mode, pid| Status {
            installed: true,
            mode,
            running: true,
            pid,
        };
        assert_eq!(
            restart_plan(&running(Some(Mode::Systemd), Some(42)), 501, &paths, argv.clone()),
            Restart::Systemd
        );
        assert_eq!(
            restart_plan(&running(Some(Mode::Launchd), Some(42)), 501, &paths, argv.clone()),
            Restart::Launchd { uid: 501 }
        );
        match restart_plan(&running(Some(Mode::Background), Some(42)), 501, &paths, argv.clone()) {
            Restart::Background {
                pid, argv: a, pid_file, ..
            } => {
                assert_eq!(pid, 42);
                assert_eq!(a, argv);
                assert_eq!(pid_file, paths.pid_file);
            }
            other => panic!("expected background, got {other:?}"),
        }
        // Not started by a service: the user restarts it.
        assert_eq!(
            restart_plan(&running(None, Some(42)), 501, &paths, argv.clone()),
            Restart::Manual
        );
        // Service installed but the daemon does not answer.
        let down = Status {
            installed: true,
            mode: Some(Mode::Systemd),
            running: false,
            pid: None,
        };
        assert_eq!(restart_plan(&down, 501, &paths, argv), Restart::Manual);
    }

    #[test]
    fn daemon_argv_passes_home_only_when_it_is_not_the_default() {
        let dir = tempfile::tempdir().unwrap();
        let user_home = dir.path().join("user");
        let default_home = user_home.join(".bandito");
        std::fs::create_dir_all(&default_home).unwrap();
        std::fs::write(default_home.join(LISTEN_FILE), "127.0.0.1:9999\n").unwrap();
        let exe = Path::new("/bin/bandito");
        assert_eq!(
            daemon_argv(&default_home, &user_home, exe),
            vec!["/bin/bandito", "daemon", "--listen", "127.0.0.1:9999"]
        );
        let other = dir.path().join("elsewhere");
        assert_eq!(
            daemon_argv(&other, &user_home, exe),
            vec![
                "/bin/bandito",
                "--home",
                other.to_str().unwrap(),
                "daemon",
                "--listen",
                service::DEFAULT_LISTEN
            ]
        );
    }
}
