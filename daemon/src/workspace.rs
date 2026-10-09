//! Where an agent's CLI runs: the server itself (`shared`) or a Docker container.
//! Store rows live in `store::workspaces`; see docs/ARCHITECTURE.md#workspaces.
//!
//! Every CLI start goes through [`confine`], so the runtimes build their command as before and
//! only the workspace decides whether it runs directly or through `docker exec`.

use crate::store::{Mount, Network, Store, Workspace, WorkspaceKind};
use anyhow::Result;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command as AsyncCommand;

/// Containers are named `bandito-ws-<workspace id>`.
const CONTAINER_PREFIX: &str = "bandito-ws-";
/// The image built when a container workspace names none: Node with both agent CLIs.
const DOCKERFILE: &str = "FROM node:22-bookworm\nRUN npm install -g @anthropic-ai/claude-code @openai/codex\n";
/// How long `docker info` may take before Docker counts as unavailable.
const DOCKER_INFO_TIMEOUT: Duration = Duration::from_secs(20);
/// The container label that holds [`config_hash`].
const CONFIG_LABEL: &str = "bandito.config";

/// Where an agent's CLI runs. `None` in `SpawnConfig` means the same as `Shared`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceSpec {
    Shared,
    /// A running container; `docker` is the client that runs `docker exec` in it.
    Container {
        name: String,
        docker: PathBuf,
    },
}

/// Failures of workspaces. The RPC layer sends `reason()` as `error.data.reason`.
#[derive(Debug, thiserror::Error)]
pub enum WorkspaceError {
    #[error("Docker is not available ({0}). Install it: https://docs.docker.com/engine/install/")]
    DockerUnavailable(String),
    #[error("no workspace {0}")]
    NotFound(String),
    #[error("the shared workspace cannot be deleted")]
    Builtin,
    #[error("the workspace still has {0} agent(s); move them first")]
    NotEmpty(usize),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Docker(String),
}

impl WorkspaceError {
    pub fn reason(&self) -> &'static str {
        match self {
            WorkspaceError::DockerUnavailable(_) => "docker_unavailable",
            WorkspaceError::NotFound(_) => "not_found",
            WorkspaceError::Builtin => "builtin",
            WorkspaceError::NotEmpty(_) => "not_empty",
            WorkspaceError::Invalid(_) => "invalid",
            WorkspaceError::Docker(_) => "docker",
        }
    }
}

/// Live numbers of a container workspace (`workspaces.list`, `workspaces.start`).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WorkspaceStatus {
    pub running: bool,
    pub container_id: Option<String>,
    pub cpu: Option<String>,
    pub mem: Option<String>,
}

/// The container name of a workspace.
pub fn container_name(id: &str) -> String {
    format!("{CONTAINER_PREFIX}{id}")
}

/// Bandito's data folder: `$BANDITO_HOME`, else `~/.bandito`.
pub fn data_dir() -> PathBuf {
    std::env::var_os("BANDITO_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(|| PathBuf::from("/")).join(".bandito"))
}

/// The tag of the image Bandito builds from [`DOCKERFILE`]. The tag changes with the Dockerfile.
pub fn default_image_tag() -> String {
    let digest = Sha256::digest(DOCKERFILE.as_bytes());
    format!("bandito/workspace:{}", &hex::encode(digest)[..12])
}

/// Checks one mount by its shape. Host paths must be absolute and free of the characters
/// `docker --mount` cannot carry, and the Docker socket and the server root are refused.
pub fn check_mount(m: &Mount) -> Result<(), WorkspaceError> {
    for path in [&m.host, &m.target] {
        if !path.starts_with('/') {
            return Err(WorkspaceError::Invalid(format!("mount path {path} must be absolute")));
        }
        if path.contains([',', '"']) {
            return Err(WorkspaceError::Invalid(format!(
                "mount path {path} cannot contain ',' or '\"'"
            )));
        }
        if Path::new(path)
            .components()
            .any(|c| c == std::path::Component::ParentDir)
        {
            return Err(WorkspaceError::Invalid(format!(
                "mount path {path} cannot contain '..'"
            )));
        }
    }
    if m.host == "/" {
        return Err(WorkspaceError::Invalid("the server root cannot be mounted".into()));
    }
    if m.host.ends_with("docker.sock") {
        return Err(WorkspaceError::Invalid("the Docker socket cannot be mounted".into()));
    }
    Ok(())
}

/// The daemon user's CLI logins, so the agent inside a container is logged in too:
/// `~/.claude` and `~/.codex`, when they exist. The container runs as root, so they land in `/root`.
pub fn login_mounts() -> Vec<Mount> {
    let Some(home) = dirs::home_dir() else {
        return Vec::new();
    };
    [(".claude", "/root/.claude"), (".codex", "/root/.codex")]
        .into_iter()
        .filter_map(|(dir, target)| {
            let host = home.join(dir);
            host.is_dir().then(|| Mount {
                host: host.display().to_string(),
                target: target.to_string(),
                read_only: false,
            })
        })
        .collect()
}

/// Every mount a container of `ws` needs, merged and sorted: the folders the user added, the
/// folder and home of each agent that runs in the workspace (at their own paths, so the CLI
/// sees the same paths as on the server), and the CLI logins. The same agents always give the
/// same list, so the container is not recreated for nothing.
pub fn mounts_for(store: &Store, ws: &Workspace) -> Result<Vec<Mount>> {
    let mut all: Vec<Mount> = ws.mounts.clone();
    for agent in store.agent_list()?.into_iter().filter(|a| a.workspace_id == ws.id) {
        all.push(Mount {
            host: agent.cwd.clone(),
            target: agent.cwd,
            read_only: false,
        });
        if let Some(home) = agent.home_dir {
            all.push(Mount {
                host: home.clone(),
                target: home,
                read_only: false,
            });
        }
    }
    all.extend(login_mounts());
    let mut merged: BTreeMap<(String, String), bool> = BTreeMap::new();
    for m in all {
        merged
            .entry((m.host, m.target))
            .and_modify(|read_only| *read_only = *read_only && m.read_only)
            .or_insert(m.read_only);
    }
    Ok(merged
        .into_iter()
        .map(|((host, target), read_only)| Mount {
            host,
            target,
            read_only,
        })
        .collect())
}

/// Identifies the settings a container is made with. It goes in the container's label; when a
/// start finds a different one, the container is recreated. The name is not part of it.
pub fn config_hash(ws: &Workspace, mounts: &[Mount]) -> String {
    let image = ws.image.clone().unwrap_or_else(default_image_tag);
    let body = serde_json::json!({
        "image": image,
        "cpus": ws.cpus,
        "memory_mb": ws.memory_mb,
        "network": ws.network.as_str(),
        "mounts": mounts,
    });
    hex::encode(Sha256::digest(body.to_string().as_bytes()))[..16].to_string()
}

fn mount_arg(m: &Mount) -> String {
    let mut arg = format!("type=bind,source={},target={}", m.host, m.target);
    if m.read_only {
        arg.push_str(",readonly");
    }
    arg
}

/// Arguments of `docker run` for a workspace's container: detached, `--init` as PID 1, restarted
/// with the Docker daemon, limits, network, mounts. Mounts keep their paths.
pub fn run_args(ws: &Workspace, mounts: &[Mount], config: &str, image: &str) -> Vec<String> {
    let mut args: Vec<String> = ["run", "-d", "--name"].map(String::from).into();
    args.push(container_name(&ws.id));
    args.extend(["--init", "--restart", "unless-stopped", "--label"].map(String::from));
    args.push(format!("{CONFIG_LABEL}={config}"));
    if let Some(cpus) = ws.cpus {
        args.extend(["--cpus".to_string(), cpus.to_string()]);
    }
    if let Some(mb) = ws.memory_mb {
        args.extend(["--memory".to_string(), format!("{mb}m")]);
    }
    let network = match ws.network {
        Network::Internet => "bridge",
        Network::Offline => "none",
    };
    args.extend(["--network".to_string(), network.to_string()]);
    for m in mounts {
        args.extend(["--mount".to_string(), mount_arg(m)]);
    }
    args.push(image.to_string());
    args.extend(["sleep".to_string(), "infinity".to_string()]);
    args
}

/// Arguments of `docker exec` into a container. Environment values are not in here: each name
/// is passed with `-e NAME`, and the value comes from the environment of the docker client.
/// That keeps secrets out of the process list.
pub fn exec_args(
    container: &str,
    cwd: Option<&Path>,
    env_names: &[&str],
    program: &str,
    args: &[String],
) -> Vec<String> {
    let mut out: Vec<String> = vec!["exec".into(), "-i".into()];
    if let Some(cwd) = cwd {
        out.extend(["-w".to_string(), cwd.display().to_string()]);
    }
    for name in env_names {
        out.extend(["-e".to_string(), (*name).to_string()]);
    }
    out.push(container.to_string());
    out.push(program.to_string());
    out.extend(args.iter().cloned());
    out
}

/// The command that runs `program` in a workspace: directly for `Shared` (or no workspace), and
/// through `docker exec` for a container. Stdio is left to the caller.
pub fn exec_command(
    ws: Option<&WorkspaceSpec>,
    program: &str,
    args: &[String],
    env: &[(String, String)],
    cwd: Option<&Path>,
) -> std::process::Command {
    match ws {
        Some(WorkspaceSpec::Container { name, docker }) => {
            let names: Vec<&str> = env.iter().map(|(k, _)| k.as_str()).collect();
            let mut cmd = std::process::Command::new(docker);
            cmd.args(exec_args(name, cwd, &names, program, args));
            cmd.envs(env.iter().map(|(k, v)| (k, v)));
            cmd
        }
        Some(WorkspaceSpec::Shared) | None => {
            let mut cmd = std::process::Command::new(program);
            cmd.args(args);
            cmd.envs(env.iter().map(|(k, v)| (k, v)));
            if let Some(cwd) = cwd {
                cmd.current_dir(cwd);
            }
            cmd
        }
    }
}

/// Moves a CLI command that a runtime has built into its workspace. The runtime's own settings
/// (arguments, environment, folder) carry over. Arguments are UTF-8: they come from JSON and from
/// paths the daemon chose.
pub fn confine(cmd: tokio::process::Command, ws: Option<&WorkspaceSpec>) -> tokio::process::Command {
    let std_cmd = cmd.as_std();
    let program = std_cmd.get_program().to_string_lossy().into_owned();
    let args: Vec<String> = std_cmd.get_args().map(|a| a.to_string_lossy().into_owned()).collect();
    let env: Vec<(String, String)> = std_cmd
        .get_envs()
        .filter_map(|(k, v)| Some((k.to_string_lossy().into_owned(), v?.to_string_lossy().into_owned())))
        .collect();
    let cwd = std_cmd.get_current_dir().map(Path::to_path_buf);
    tokio::process::Command::from(exec_command(ws, &program, &args, &env, cwd.as_deref()))
}

/// Docker's words for a container that does not exist (its case varies by version).
fn is_missing(stderr: &str) -> bool {
    stderr.to_ascii_lowercase().contains("no such")
}

/// Runs the `docker` program for the container workspaces.
pub struct WorkspaceManager {
    docker: PathBuf,
    /// Where the Dockerfile of the default image is written before `docker build`.
    build_dir: PathBuf,
}

/// What `docker inspect` says about a container.
struct Inspected {
    id: String,
    running: bool,
    config: String,
}

impl WorkspaceManager {
    pub fn new(docker: PathBuf, build_dir: PathBuf) -> Arc<Self> {
        Arc::new(Self { docker, build_dir })
    }

    /// The real setup: `docker` from `PATH`, the default image built under the data folder.
    pub fn system() -> Arc<Self> {
        Self::new(PathBuf::from("docker"), data_dir().join("workspaces").join("image"))
    }

    /// How sessions of a container workspace reach it.
    pub fn spec(&self, ws: &Workspace) -> WorkspaceSpec {
        WorkspaceSpec::Container {
            name: container_name(&ws.id),
            docker: self.docker.clone(),
        }
    }

    /// Makes sure the workspace's container runs with `mounts` and the current settings: created
    /// when missing, started when stopped, recreated when its settings differ.
    pub async fn ensure_running(&self, ws: &Workspace, mounts: &[Mount]) -> Result<(), WorkspaceError> {
        if ws.kind != WorkspaceKind::Container {
            return Err(WorkspaceError::Invalid(
                "only a container workspace runs in Docker".into(),
            ));
        }
        for m in mounts {
            check_mount(m)?;
        }
        self.check_docker().await?;
        if ws.image.is_none() {
            self.ensure_default_image().await?;
        }
        let image = ws.image.clone().unwrap_or_else(default_image_tag);
        let config = config_hash(ws, mounts);
        let name = container_name(&ws.id);
        match self.inspect(&name).await? {
            Some(found) if found.config == config => {
                if !found.running {
                    self.run(&["start", &name]).await?;
                }
            }
            Some(_) => {
                self.run(&["rm", "-f", &name]).await?;
                self.run(&run_args(ws, mounts, &config, &image)).await?;
            }
            None => {
                self.run(&run_args(ws, mounts, &config, &image)).await?;
            }
        }
        Ok(())
    }

    /// Live status. A container that does not exist is simply not running.
    pub async fn status(&self, ws: &Workspace) -> Result<WorkspaceStatus, WorkspaceError> {
        self.check_docker().await?;
        let name = container_name(&ws.id);
        let Some(found) = self.inspect(&name).await? else {
            return Ok(WorkspaceStatus {
                running: false,
                container_id: None,
                cpu: None,
                mem: None,
            });
        };
        let (cpu, mem) = if found.running {
            self.stats(&name).await
        } else {
            (None, None)
        };
        Ok(WorkspaceStatus {
            running: found.running,
            container_id: Some(found.id),
            cpu,
            mem,
        })
    }

    /// Stops the container. Its processes, the agents' CLIs included, end with it.
    pub async fn stop(&self, ws: &Workspace) -> Result<(), WorkspaceError> {
        self.check_docker().await?;
        let name = container_name(&ws.id);
        match self.run(&["stop", "-t", "5", &name]).await {
            Err(WorkspaceError::Docker(msg)) if is_missing(&msg) => Ok(()),
            other => other.map(|_| ()),
        }
    }

    /// Removes the container if there is one. Without Docker there cannot be one, so that is fine too.
    pub async fn remove(&self, ws: &Workspace) -> Result<(), WorkspaceError> {
        let name = container_name(&ws.id);
        match self.run(&["rm", "-f", &name]).await {
            Err(WorkspaceError::Docker(msg)) if is_missing(&msg) => Ok(()),
            Err(WorkspaceError::DockerUnavailable(_)) => Ok(()),
            other => other.map(|_| ()),
        }
    }

    async fn check_docker(&self) -> Result<(), WorkspaceError> {
        let out = tokio::time::timeout(DOCKER_INFO_TIMEOUT, self.raw(&["info"]))
            .await
            .map_err(|_| WorkspaceError::DockerUnavailable("docker info timed out".into()))??;
        if out.status.success() {
            return Ok(());
        }
        let detail = String::from_utf8_lossy(&out.stderr)
            .lines()
            .last()
            .unwrap_or("")
            .trim()
            .to_string();
        Err(WorkspaceError::DockerUnavailable(if detail.is_empty() {
            "the Docker daemon does not answer".into()
        } else {
            detail
        }))
    }

    /// Builds the default image once per Dockerfile; later starts find it by its tag.
    async fn ensure_default_image(&self) -> Result<(), WorkspaceError> {
        let tag = default_image_tag();
        if self.raw(&["image", "inspect", &tag]).await?.status.success() {
            return Ok(());
        }
        std::fs::create_dir_all(&self.build_dir)
            .and_then(|_| std::fs::write(self.build_dir.join("Dockerfile"), DOCKERFILE))
            .map_err(|e| WorkspaceError::Docker(format!("write the Dockerfile: {e}")))?;
        let dir = self.build_dir.display().to_string();
        self.run(&["build", "-t", &tag, &dir]).await?;
        Ok(())
    }

    /// `docker inspect` of one container; `None` when it does not exist.
    async fn inspect(&self, name: &str) -> Result<Option<Inspected>, WorkspaceError> {
        let format = format!("{{{{.Id}}}} {{{{.State.Running}}}} {{{{index .Config.Labels \"{CONFIG_LABEL}\"}}}}");
        let out = self.raw(&["inspect", "-f", &format, name]).await?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr).into_owned();
            if is_missing(&err) || err.trim().is_empty() {
                return Ok(None);
            }
            return Err(WorkspaceError::Docker(err.trim().to_string()));
        }
        let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let mut parts = text.splitn(3, ' ');
        let id = parts.next().unwrap_or_default().to_string();
        let running = parts.next() == Some("true");
        let config = parts.next().unwrap_or_default().to_string();
        Ok(Some(Inspected { id, running, config }))
    }

    /// CPU and memory of a running container from `docker stats`, as Docker prints them. Best effort.
    async fn stats(&self, name: &str) -> (Option<String>, Option<String>) {
        let Ok(out) = self
            .raw(&["stats", "--no-stream", "--format", "{{json .}}", name])
            .await
        else {
            return (None, None);
        };
        let Ok(value) = serde_json::from_slice::<serde_json::Value>(&out.stdout) else {
            return (None, None);
        };
        let field = |key: &str| value.get(key).and_then(|v| v.as_str()).map(str::to_string);
        (field("CPUPerc"), field("MemUsage"))
    }

    /// Runs `docker` and returns its stdout, or the error with Docker's stderr.
    async fn run<S: AsRef<str>>(&self, args: &[S]) -> Result<String, WorkspaceError> {
        let out = self.raw(args).await?;
        if out.status.success() {
            return Ok(String::from_utf8_lossy(&out.stdout).trim().to_string());
        }
        let mut msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
        if msg.to_ascii_lowercase().contains("permission denied") {
            msg.push_str(" (add your user to the docker group: sudo usermod -aG docker $USER)");
        }
        Err(WorkspaceError::Docker(if msg.is_empty() {
            format!("docker exited with {}", out.status)
        } else {
            msg
        }))
    }

    /// Runs `docker` and returns its output as it is. A missing `docker` program is DockerUnavailable.
    async fn raw<S: AsRef<str>>(&self, args: &[S]) -> Result<Output, WorkspaceError> {
        AsyncCommand::new(&self.docker)
            .args(args.iter().map(|a| a.as_ref()))
            .stdin(Stdio::null())
            .kill_on_drop(true)
            .output()
            .await
            .map_err(|e| WorkspaceError::DockerUnavailable(format!("{}: {e}", self.docker.display())))
    }
}

#[cfg(all(test, unix))]
pub(crate) mod testing {
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    /// A `docker` stand-in for tests. It logs every call to `calls.log` in `dir`. `inspect` prints
    /// the content of `inspect.out` when that exists, and otherwise says there is no such container.
    /// Every other call succeeds.
    pub struct FakeDocker {
        pub dir: tempfile::TempDir,
        pub docker: PathBuf,
    }

    impl FakeDocker {
        pub fn calls(&self) -> Vec<String> {
            std::fs::read_to_string(self.dir.path().join("calls.log"))
                .unwrap_or_default()
                .lines()
                .map(str::to_string)
                .collect()
        }
    }

    pub fn fake_docker(inspect: Option<&str>) -> FakeDocker {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("calls.log");
        let state = dir.path().join("inspect.out");
        if let Some(text) = inspect {
            std::fs::write(&state, text).unwrap();
        }
        let docker = dir.path().join("docker");
        let script = format!(
            "#!/bin/sh\necho \"$@\" >> {log}\ncase \"$1\" in\n  inspect) if [ -f {state} ]; then cat {state}; exit 0; fi; exit 1 ;;\n  *) exit 0 ;;\nesac\n",
            log = sh_quote(&log),
            state = sh_quote(&state),
        );
        std::fs::write(&docker, script).unwrap();
        std::fs::set_permissions(&docker, std::fs::Permissions::from_mode(0o755)).unwrap();
        FakeDocker { dir, docker }
    }

    fn sh_quote(path: &Path) -> String {
        format!("'{}'", path.display())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{Mount, Network, Workspace, WorkspaceKind};
    use std::ffi::OsStr;

    fn ws(id: &str) -> Workspace {
        Workspace {
            id: id.into(),
            name: "Scout".into(),
            kind: WorkspaceKind::Container,
            image: Some("img:1".into()),
            cpus: Some(1.5),
            memory_mb: Some(1024),
            network: Network::Offline,
            mounts: Vec::new(),
            created_at: 0,
        }
    }

    fn mount(path: &str, read_only: bool) -> Mount {
        Mount {
            host: path.into(),
            target: path.into(),
            read_only,
        }
    }

    #[test]
    fn run_args_describe_the_container() {
        let w = ws("a1");
        let mounts = vec![mount("/srv/my data", false), mount("/srv/ro", true)];
        let args = run_args(&w, &mounts, "hash1", "img:1");
        assert_eq!(
            args,
            vec![
                "run",
                "-d",
                "--name",
                "bandito-ws-a1",
                "--init",
                "--restart",
                "unless-stopped",
                "--label",
                "bandito.config=hash1",
                "--cpus",
                "1.5",
                "--memory",
                "1024m",
                "--network",
                "none",
                "--mount",
                "type=bind,source=/srv/my data,target=/srv/my data",
                "--mount",
                "type=bind,source=/srv/ro,target=/srv/ro,readonly",
                "img:1",
                "sleep",
                "infinity",
            ]
        );
    }

    #[test]
    fn run_args_without_limits_or_with_internet() {
        let mut w = ws("a2");
        w.cpus = None;
        w.memory_mb = None;
        w.network = Network::Internet;
        let args = run_args(&w, &[], "h", "img:1");
        assert!(!args.iter().any(|a| a == "--cpus" || a == "--memory"));
        let net = args.iter().position(|a| a == "--network").unwrap();
        assert_eq!(args[net + 1], "bridge");
    }

    #[test]
    fn exec_args_pass_env_names_and_keep_paths_whole() {
        let args = exec_args(
            "bandito-ws-a1",
            Some(Path::new("/srv/my data")),
            &["BANDITO_AGENT_ID", "ANTHROPIC_API_KEY"],
            "claude",
            &["-p".to_string(), "a b".to_string()],
        );
        assert_eq!(
            args,
            vec![
                "exec",
                "-i",
                "-w",
                "/srv/my data",
                "-e",
                "BANDITO_AGENT_ID",
                "-e",
                "ANTHROPIC_API_KEY",
                "bandito-ws-a1",
                "claude",
                "-p",
                "a b",
            ]
        );
    }

    #[test]
    fn confine_leaves_shared_commands_as_they_are() {
        let mut cmd = tokio::process::Command::new("echo");
        cmd.arg("a b").env("K", "V").current_dir("/tmp");
        let out = confine(cmd, None);
        let std_cmd = out.as_std();
        assert_eq!(std_cmd.get_program(), OsStr::new("echo"));
        assert_eq!(std_cmd.get_args().collect::<Vec<_>>(), vec![OsStr::new("a b")]);
        assert_eq!(std_cmd.get_current_dir(), Some(Path::new("/tmp")));
        let envs: Vec<_> = std_cmd.get_envs().collect();
        assert_eq!(envs, vec![(OsStr::new("K"), Some(OsStr::new("V")))]);

        let mut again = tokio::process::Command::new("echo");
        again.arg("a b");
        let shared = confine(again, Some(&WorkspaceSpec::Shared));
        assert_eq!(shared.as_std().get_program(), OsStr::new("echo"));
    }

    #[test]
    fn confine_wraps_container_commands_in_docker_exec() {
        let spec = WorkspaceSpec::Container {
            name: "bandito-ws-a1".into(),
            docker: PathBuf::from("/usr/bin/docker"),
        };
        let mut cmd = tokio::process::Command::new("claude");
        cmd.arg("-p").env("K", "V").current_dir("/srv/my data");
        let out = confine(cmd, Some(&spec));
        let std_cmd = out.as_std();
        assert_eq!(std_cmd.get_program(), OsStr::new("/usr/bin/docker"));
        let args: Vec<&OsStr> = std_cmd.get_args().collect();
        assert_eq!(
            args,
            vec![
                OsStr::new("exec"),
                OsStr::new("-i"),
                OsStr::new("-w"),
                OsStr::new("/srv/my data"),
                OsStr::new("-e"),
                OsStr::new("K"),
                OsStr::new("bandito-ws-a1"),
                OsStr::new("claude"),
                OsStr::new("-p"),
            ]
        );
        // The value travels in the environment of the docker client, not in its argv.
        let envs: Vec<_> = std_cmd.get_envs().collect();
        assert_eq!(envs, vec![(OsStr::new("K"), Some(OsStr::new("V")))]);
    }

    #[test]
    fn config_hash_follows_what_shapes_the_container() {
        let base = config_hash(&ws("a1"), &[]);
        assert_eq!(base, config_hash(&ws("a1"), &[]));

        let mut renamed = ws("a1");
        renamed.name = "Other".into();
        assert_eq!(
            base,
            config_hash(&renamed, &[]),
            "the name does not reach the container"
        );

        let mut bigger = ws("a1");
        bigger.cpus = Some(2.0);
        assert_ne!(base, config_hash(&bigger, &[]));
        assert_ne!(base, config_hash(&ws("a1"), &[mount("/srv/x", false)]));
        assert_ne!(base, config_hash(&ws("a1"), &[mount("/srv/x", true)]));
    }

    #[test]
    fn mounts_are_checked_by_shape() {
        for bad in ["relative/dir", "/srv/a,b", "/var/run/docker.sock", "/", "/srv/x\"y"] {
            let err = check_mount(&mount(bad, false)).unwrap_err();
            assert_eq!(err.reason(), "invalid", "{bad}");
        }
        assert!(check_mount(&mount("/srv/my data", true)).is_ok());
        let relative_target = Mount {
            host: "/srv/a".into(),
            target: "data".into(),
            read_only: false,
        };
        assert_eq!(check_mount(&relative_target).unwrap_err().reason(), "invalid");
    }

    #[test]
    fn default_image_tag_is_fixed_by_its_dockerfile() {
        let tag = default_image_tag();
        assert!(tag.starts_with("bandito/workspace:"), "{tag}");
        assert_eq!(tag, default_image_tag());
        assert!(tag.len() > "bandito/workspace:".len());
    }

    #[test]
    fn container_name_is_derived_from_the_id() {
        assert_eq!(container_name("0191-abc"), "bandito-ws-0191-abc");
    }

    #[tokio::test]
    async fn missing_docker_is_reported_as_docker_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        let m = WorkspaceManager::new(PathBuf::from("/nonexistent/bandito-docker"), dir.path().join("build"));
        let err = m.ensure_running(&ws("a1"), &[]).await.unwrap_err();
        assert_eq!(err.reason(), "docker_unavailable");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn first_start_creates_the_container_with_its_mounts() {
        let fake = testing::fake_docker(None);
        let m = WorkspaceManager::new(fake.docker.clone(), fake.dir.path().join("build"));
        m.ensure_running(&ws("a1"), &[mount("/srv/my data", false)])
            .await
            .unwrap();
        let log = fake.calls();
        assert!(
            log.iter().any(|l| l.starts_with("run -d --name bandito-ws-a1 ")),
            "{log:?}"
        );
        assert!(
            log.iter()
                .any(|l| l.contains("type=bind,source=/srv/my data,target=/srv/my data")),
            "{log:?}"
        );
        assert!(!log.iter().any(|l| l.starts_with("rm ")), "{log:?}");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_running_container_with_the_same_config_is_reused() {
        let w = ws("a1");
        let mounts = vec![mount("/srv/x", false)];
        let fake = testing::fake_docker(Some(&format!("cid true {}\n", config_hash(&w, &mounts))));
        let m = WorkspaceManager::new(fake.docker.clone(), fake.dir.path().join("build"));
        m.ensure_running(&w, &mounts).await.unwrap();
        let log = fake.calls();
        assert!(
            !log.iter()
                .any(|l| l.starts_with("run ") || l.starts_with("rm ") || l.starts_with("start ")),
            "{log:?}"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_stopped_container_is_started_and_a_changed_one_is_recreated() {
        let w = ws("a1");
        let stopped = testing::fake_docker(Some(&format!("cid false {}\n", config_hash(&w, &[]))));
        let m = WorkspaceManager::new(stopped.docker.clone(), stopped.dir.path().join("build"));
        m.ensure_running(&w, &[]).await.unwrap();
        let log = stopped.calls();
        assert!(log.iter().any(|l| l.starts_with("start bandito-ws-a1")), "{log:?}");
        assert!(!log.iter().any(|l| l.starts_with("run ")), "{log:?}");

        let changed = testing::fake_docker(Some("cid true someoldhash\n"));
        let m = WorkspaceManager::new(changed.docker.clone(), changed.dir.path().join("build"));
        m.ensure_running(&w, &[]).await.unwrap();
        let log = changed.calls();
        let rm = log
            .iter()
            .position(|l| l.starts_with("rm -f bandito-ws-a1"))
            .expect("removed");
        let run = log.iter().position(|l| l.starts_with("run ")).expect("recreated");
        assert!(rm < run, "{log:?}");
    }
}
