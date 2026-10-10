//! `host.*` JSON-RPC methods: load, processes and ports of this server. The logic
//! is in `crate::host`; blocking reads run on the blocking pool.
//! See docs/ARCHITECTURE.md#host.

use super::{App, HOST_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::host::{self, HistoryRange, HostError, MAX_HISTORY_POINTS};
use serde::Deserialize;
use serde_json::{Value, json};

/// Answers `host.*` methods. `rpc::dispatch` has already refused anonymous peers.
pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "host.stats" => {
            let sampler = app.host.clone();
            // The last sample, and the processes read now: the list is always current.
            let (mut stats, top) = blocking(move || (sampler.latest_or_sample(), sampler.top_processes())).await?;
            stats.top_processes = top;
            ok(stats)
        }
        "host.history" => {
            #[derive(Deserialize)]
            struct HistoryParams {
                range: String,
            }
            let p: HistoryParams = params(p)?;
            let range = HistoryRange::parse(&p.range)
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, "range must be 1h or 24h"))?;
            let sampler = app.host.clone();
            let points = blocking(move || sampler.history(range, MAX_HISTORY_POINTS)).await?;
            ok(json!({ "points": points }))
        }
        "host.processes" => {
            let sampler = app.host.clone();
            ok(blocking(move || sampler.processes()).await?)
        }
        "host.ports" => {
            let sampler = app.host.clone();
            ok(blocking(move || sampler.ports()).await?)
        }
        "host.kill_process" => {
            #[derive(Deserialize)]
            struct KillProcessParams {
                pid: i32,
            }
            let KillProcessParams { pid } = params(p)?;
            let start = blocking(move || host::terminate_own(pid)).await?.map_err(host_error)?;
            // SIGTERM is sent. The answer says whether the process was gone within a second; SIGKILL follows
            // after the grace period if it is still the same process.
            let killed = blocking(move || host::wait_gone(pid, host::OWN_WAIT)).await?;
            tokio::spawn(host::force_own_after(pid, start, host::OWN_GRACE));
            ok(json!({ "ok": true, "killed": killed }))
        }
        "host.kill" => {
            #[derive(Deserialize)]
            struct KillParams {
                pid: i32,
            }
            let KillParams { pid } = params(p)?;
            let owner = blocking(move || host::terminate(pid)).await?.map_err(host_error)?;
            // SIGTERM is sent now; SIGKILL follows after the grace period if the process is still there.
            tokio::spawn(host::force_after_grace(pid, owner));
            ok(json!({}))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// Runs a host read or signal on the blocking pool.
async fn blocking<T, F>(f: F) -> Result<T, RpcError>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("host task failed: {e}")))
}

/// `error.data.reason` is the stable code: `forbidden`, `not_found` or `io`.
fn host_error(e: HostError) -> RpcError {
    match e {
        HostError::InvalidPid => RpcError::new(INVALID_PARAMS, "pid must be a positive process id"),
        HostError::Forbidden(why) => RpcError::with_data(
            HOST_ERROR,
            format!("forbidden: {why}"),
            json!({ "reason": "forbidden" }),
        ),
        HostError::NotFound => RpcError::with_data(
            HOST_ERROR,
            "not_found: no such process",
            json!({ "reason": "not_found" }),
        ),
        HostError::Io(msg) => RpcError::with_data(HOST_ERROR, format!("io: {msg}"), json!({ "reason": "io" })),
    }
}

#[cfg(test)]
mod tests {
    use super::super::{App, HOST_ERROR, INVALID_PARAMS, Peer, dispatch};
    use crate::host;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use serde_json::json;
    use std::net::TcpListener;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn app() -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, std::env::temp_dir().join("bandito-host-tests"))
    }

    /// `sleep 30` started with one marker variable. Killed when dropped. Linux only: macOS's `ps -E` hides the
    /// environment of Apple's own binaries such as `sleep`, so the marker cannot be read there.
    #[cfg(target_os = "linux")]
    struct Marked(std::process::Child);

    #[cfg(target_os = "linux")]
    impl Drop for Marked {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[cfg(target_os = "linux")]
    fn marked_sleep(var: &str, id: &str) -> Marked {
        Marked(
            std::process::Command::new("sleep")
                .arg("30")
                .env(var, id)
                .spawn()
                .unwrap(),
        )
    }

    #[tokio::test]
    async fn stats_describe_this_server() {
        let v = dispatch(&app(), &Peer::Local, "host.stats", json!({})).await.unwrap();
        assert!(v["cpus"].as_u64().unwrap() >= 1, "{v}");
        assert!(v["mem_total"].as_u64().unwrap() > 0, "{v}");
        assert!(!v["os"].as_str().unwrap().is_empty());
        let pct = v["cpu_percent"].as_f64().unwrap();
        assert!((0.0..=100.0).contains(&pct), "{pct}");
        assert!(v["disks"].as_array().unwrap().iter().any(|d| d["mount"] == "/"), "{v}");
    }

    #[tokio::test]
    async fn history_takes_1h_or_24h_only() {
        let app = app();
        let v = dispatch(&app, &Peer::Local, "host.history", json!({"range": "1h"}))
            .await
            .unwrap();
        assert!(v["points"].is_array(), "{v}");
        let err = dispatch(&app, &Peer::Local, "host.history", json!({"range": "7d"}))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
    }

    #[tokio::test]
    async fn kill_refuses_the_daemon_and_processes_it_does_not_own() {
        let app = app();
        // pid 1 is init: not an agent's or terminal's process.
        let err = dispatch(&app, &Peer::Local, "host.kill", json!({"pid": 1}))
            .await
            .unwrap_err();
        assert_eq!(err.code, HOST_ERROR);
        assert_eq!(err.data, Some(json!({"reason": "forbidden"})));
        // The daemon's own pid is never killable from the app.
        let err = dispatch(&app, &Peer::Local, "host.kill", json!({"pid": std::process::id()}))
            .await
            .unwrap_err();
        assert_eq!(err.data, Some(json!({"reason": "forbidden"})));
    }

    #[tokio::test]
    async fn kill_rejects_pids_that_would_signal_groups() {
        // kill(0) and kill(-1) signal whole process groups or everything.
        for pid in [0, -1] {
            let err = dispatch(&app(), &Peer::Local, "host.kill", json!({"pid": pid}))
                .await
                .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{pid}");
        }
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn processes_group_marked_children_under_their_agent() {
        let child = marked_sleep("BANDITO_AGENT_ID", "test-agent");
        let pid = child.0.id();
        let v = dispatch(&app(), &Peer::Local, "host.processes", json!({}))
            .await
            .unwrap();
        assert_eq!(v["supported"], true, "{v}");
        let owners = v["owners"].as_array().unwrap();
        let group = owners
            .iter()
            .find(|g| g["owner"] == json!({"kind": "agent", "id": "test-agent"}))
            .expect("agent group");
        assert!(
            group["processes"].as_array().unwrap().iter().any(|p| p["pid"] == pid),
            "{group}"
        );
        assert!(owners.iter().any(|g| g["owner"]["kind"] == "daemon"), "{v}");
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn kill_stops_a_marked_process() {
        let mut child = marked_sleep("BANDITO_AGENT_ID", "test-agent");
        let pid = child.0.id();
        dispatch(&app(), &Peer::Local, "host.kill", json!({"pid": pid}))
            .await
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while child.0.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "process {pid} still alive after SIGTERM");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    #[tokio::test]
    async fn ports_list_our_own_listener_as_the_daemon() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let v = dispatch(&app(), &Peer::Local, "host.ports", json!({})).await.unwrap();
        assert_eq!(v["supported"], true, "{v}");
        let entry = v["ports"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["port"] == port)
            .unwrap_or_else(|| panic!("port {port} not listed: {v}"));
        assert_eq!(entry["addr"], "127.0.0.1");
        assert_eq!(entry["pid"], std::process::id());
        assert_eq!(entry["owner"]["kind"], "daemon");
        drop(listener);
    }

    /// A child that is killed when dropped, whatever the test did with it.
    struct Owned(std::process::Child);

    impl Drop for Owned {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// Whether `pid` still exists (a zombie counts as gone on Linux only, so the tests poll with `kill(0)`).
    fn exists(pid: i32) -> bool {
        // SAFETY: signal 0 sends nothing; it only asks whether the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// A process that is not a child of the test: its parent exits at once, and init reaps it.
    fn orphan_sleep() -> i32 {
        let out = std::process::Command::new("sh")
            // The sleep keeps no pipe of ours open: `output()` returns at once.
            .args(["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
    }

    #[tokio::test]
    async fn kill_process_refuses_init_the_daemon_and_bad_pids() {
        let app = app();
        let err = dispatch(&app, &Peer::Local, "host.kill_process", json!({"pid": 1}))
            .await
            .unwrap_err();
        assert_eq!(err.code, HOST_ERROR);
        assert_eq!(err.data, Some(json!({"reason": "forbidden"})));
        let err = dispatch(
            &app,
            &Peer::Local,
            "host.kill_process",
            json!({"pid": std::process::id()}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.data, Some(json!({"reason": "forbidden"})));
        for pid in [0, -1] {
            let err = dispatch(&app, &Peer::Local, "host.kill_process", json!({"pid": pid}))
                .await
                .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{pid}");
        }
    }

    #[tokio::test]
    async fn kill_process_refuses_an_agents_process_on_every_platform() {
        // An agent's CLI (here a shell) is a registered root, and its child is the agent's process by the tree.
        let mut shell = std::process::Command::new("sh")
            .args(["-c", "sleep 30 & echo $!; wait"])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(&mut std::io::BufReader::new(shell.stdout.take().unwrap()), &mut line).unwrap();
        let pid: i32 = line.trim().parse().unwrap();
        let _root = host::register_root(shell.id() as i32, host::Owner::agent("test-agent"));
        let err = dispatch(&app(), &Peer::Local, "host.kill_process", json!({"pid": pid}))
            .await
            .unwrap_err();
        assert_eq!(err.data, Some(json!({"reason": "forbidden"})), "{err:?}");
        assert!(exists(pid), "the agent's process must not be signalled");
        // SAFETY: the child is this test's own and is signalled only here.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
        let _ = shell.kill();
        let _ = shell.wait();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn kill_process_refuses_a_process_marked_by_its_environment() {
        let child = marked_sleep("BANDITO_AGENT_ID", "test-agent");
        let pid = child.0.id() as i32;
        let err = dispatch(&app(), &Peer::Local, "host.kill_process", json!({"pid": pid}))
            .await
            .unwrap_err();
        assert_eq!(err.data, Some(json!({"reason": "forbidden"})), "{err:?}");
        assert!(exists(pid));
    }

    #[tokio::test]
    async fn kill_process_stops_an_own_process_and_says_so() {
        let pid = orphan_sleep();
        assert!(exists(pid));
        let v = dispatch(&app(), &Peer::Local, "host.kill_process", json!({"pid": pid}))
            .await
            .unwrap();
        assert_eq!(v, json!({"ok": true, "killed": true}), "{v}");
        let deadline = Instant::now() + Duration::from_secs(5);
        while exists(pid) {
            assert!(Instant::now() < deadline, "process {pid} still alive after SIGTERM");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    #[tokio::test]
    async fn kill_process_on_a_missing_pid_is_not_found() {
        let pid = orphan_sleep();
        let killed = dispatch(&app(), &Peer::Local, "host.kill_process", json!({"pid": pid}))
            .await
            .unwrap();
        assert_eq!(killed["ok"], true);
        let deadline = Instant::now() + Duration::from_secs(5);
        while exists(pid) {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let err = dispatch(&app(), &Peer::Local, "host.kill_process", json!({"pid": pid}))
            .await
            .unwrap_err();
        assert_eq!(err.data, Some(json!({"reason": "not_found"})));
    }

    #[tokio::test]
    async fn force_kills_only_the_same_process_after_the_grace_period() {
        // A shell that ignores SIGTERM: only SIGKILL ends it.
        let mut child = Owned(
            std::process::Command::new("sh")
                .args(["-c", "trap '' TERM; while :; do sleep 0.1; done"])
                .spawn()
                .unwrap(),
        );
        let pid = child.0.id() as i32;
        let start = host::terminate_own(pid).unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "SIGTERM is ignored, so the process lives"
        );
        // Another start time is another process with the same pid: it is left alone.
        host::force_own_after(pid, "not-its-start".into(), Duration::ZERO).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(child.0.try_wait().unwrap().is_none(), "a reused pid must not be killed");
        host::force_own_after(pid, start, Duration::ZERO).await;
        let deadline = Instant::now() + Duration::from_secs(5);
        while child.0.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "SIGKILL did not end {pid}");
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    #[tokio::test]
    async fn host_stats_lists_the_biggest_processes_with_their_owner_flag() {
        let v = dispatch(&app(), &Peer::Local, "host.stats", json!({})).await.unwrap();
        let top = v["top_processes"].as_array().expect("top_processes");
        // The biggest by memory and the busiest by CPU: at most two lists of `TOP_PROCESSES`.
        assert!(!top.is_empty() && top.len() <= 2 * host::TOP_PROCESSES, "{v}");
        let rss: Vec<u64> = top.iter().map(|p| p["rss_bytes"].as_u64().unwrap()).collect();
        assert!(rss.windows(2).all(|w| w[0] >= w[1]), "biggest first: {rss:?}");
        assert!(top.iter().any(|p| p["own"] == true), "{v}");
        for p in top {
            assert!(p["name"].is_string() && p["cpu_percent"].is_number(), "{p}");
            assert!(p["own_safe"].is_boolean(), "{p}");
            // Only the daemon's own user's processes can be stopped from the app.
            assert!(!p["own_safe"].as_bool().unwrap() || p["own"] == true, "{p}");
        }
    }
}
