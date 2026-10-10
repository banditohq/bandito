//! A restore whose result does not open: the real daemon binary, started on a throwaway data folder with a restore
//! marker. Either the old database comes back, or the daemon starts in safe mode; it never starts on an empty
//! database over data that exists (docs/ARCHITECTURE.md#backups).

use bandito::backup;
use bandito::store::Store;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const COPY: &str = "bandito-20270115-080000-start.db";

/// A daemon process that is killed when the test ends.
struct Daemon(Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A copy that passes `quick_check` but that this daemon refuses to open: its schema version is from the future.
fn write_unopenable_copy(home: &Path) {
    let dir = backup::backups_dir(home);
    std::fs::create_dir_all(&dir).unwrap();
    let conn = rusqlite::Connection::open(dir.join(COPY)).unwrap();
    conn.execute_batch("CREATE TABLE t(x); PRAGMA user_version = 9999;")
        .unwrap();
}

fn start(home: &Path) -> Daemon {
    let child = Command::new(env!("CARGO_BIN_EXE_bandito"))
        .arg("--home")
        .arg(home)
        .args(["daemon", "--listen", "127.0.0.1:0"])
        .env("BANDITO_HOME", home)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    Daemon(child)
}

async fn wait_for_info(sock: &Path) -> Value {
    let end = Instant::now() + Duration::from_secs(40);
    loop {
        if let Ok(info) = bandito::rpc::unix::call(sock, "daemon.info", json!({})).await {
            return info;
        }
        assert!(Instant::now() < end, "the daemon did not answer in time");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn names_in(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .map(|r| {
            r.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    out.sort();
    out
}

fn short_home() -> (tempfile::TempDir, PathBuf) {
    // A unix socket path is short-limited: keep the folder directly under the temp dir.
    let dir = tempfile::Builder::new().prefix("bsm").tempdir().unwrap();
    let home = dir.path().to_path_buf();
    (dir, home)
}

#[tokio::test]
async fn a_restored_database_that_does_not_open_gives_the_old_one_back() {
    let (_guard, home) = short_home();
    {
        let store = Store::open(&home.join("bandito.db")).unwrap();
        store.device_add("laptop", "token-1").unwrap();
    }
    write_unopenable_copy(&home);
    let id = backup::request_restore(&home, COPY).unwrap();

    let _daemon = start(&home);
    let info = wait_for_info(&home.join("bandito.sock")).await;

    assert_eq!(info["safe_mode"], false);
    let record = &info["last_restore"];
    assert_eq!(record["id"], id.as_str());
    assert_eq!(record["ok"], false);
    assert!(record["error"].as_str().unwrap().contains("is back"), "{record}");
    // The old database is the one in use: its paired device is there.
    let devices = bandito::rpc::unix::call(&home.join("bandito.sock"), "devices.list", json!({}))
        .await
        .unwrap();
    assert_eq!(devices[0]["name"], "laptop");
    // The restored file that did not open is kept, not deleted.
    let kept = names_in(&home.join("backups"));
    assert!(
        kept.iter().any(|n| n.starts_with("broken-") && n.ends_with(".db")),
        "{kept:?}"
    );
}

#[tokio::test]
async fn with_no_way_back_the_daemon_starts_in_safe_mode_and_keeps_every_file() {
    let (_guard, home) = short_home();
    // No database yet, so the restore has nothing to set aside and nothing to go back to.
    write_unopenable_copy(&home);
    let id = backup::request_restore(&home, COPY).unwrap();

    let _daemon = start(&home);
    let sock = home.join("bandito.sock");
    let info = wait_for_info(&sock).await;

    assert_eq!(info["safe_mode"], true);
    assert!(
        info["safe_mode_error"]
            .as_str()
            .unwrap()
            .contains("no copy from before"),
        "{info}"
    );
    assert_eq!(info["last_restore"]["id"], id.as_str());
    assert_eq!(info["last_restore"]["ok"], false);
    // Only the backups methods answer; the rest says why.
    let refused = bandito::rpc::unix::call(&sock, "agents.list", json!({}))
        .await
        .unwrap_err();
    assert!(format!("{refused:#}").contains("safe mode"), "{refused:#}");
    let listed = bandito::rpc::unix::call(&sock, "backups.list", json!({}))
        .await
        .unwrap();
    assert!(listed.as_array().unwrap().iter().any(|c| c["name"] == COPY), "{listed}");
    // Nothing was deleted: the copy and the restored file are still there.
    assert!(home.join("bandito.db").exists());
    assert!(home.join("backups").join(COPY).exists());
}

/// A copy this daemon opens: made by `Store::open`, then closed.
fn write_good_copy(home: &Path, name: &str) {
    let dir = backup::backups_dir(home);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    drop(Store::open(&path).unwrap());
}

#[tokio::test]
async fn safe_mode_survives_restarts_without_a_marker_and_a_good_restore_ends_it() {
    let (_guard, home) = short_home();
    write_unopenable_copy(&home);
    backup::request_restore(&home, COPY).unwrap();
    let sock = home.join("bandito.sock");

    // The first start meets the marker. The next two have none: the database still does not open, and they must
    // stay in safe mode instead of failing in a loop.
    for round in 0..3 {
        let daemon = start(&home);
        let info = wait_for_info(&sock).await;
        assert_eq!(info["safe_mode"], true, "start {round}: {info}");
        assert!(home.join("run/safe-mode.json").exists(), "start {round}");
        assert!(home.join("bandito.db").exists());
        drop(daemon);
    }

    // A restore of a copy that opens ends it.
    let good = "bandito-20270115-090000-start.db";
    write_good_copy(&home, good);
    let id = backup::request_restore(&home, good).unwrap();
    let _daemon = start(&home);
    let info = wait_for_info(&sock).await;
    assert_eq!(info["safe_mode"], false, "{info}");
    assert_eq!(info["last_restore"]["id"], id.as_str());
    assert_eq!(info["last_restore"]["ok"], true);
    assert!(!home.join("run/safe-mode.json").exists());
    // The unopenable file it replaced is kept.
    let kept = names_in(&home.join("backups"));
    assert!(
        kept.iter().any(|n| n.starts_with("replaced-") && n.ends_with(".db")),
        "{kept:?}"
    );
}

#[tokio::test]
async fn a_database_that_does_not_open_with_set_aside_files_means_safe_mode_not_a_crash() {
    let (_guard, home) = short_home();
    // Not a marker run: an earlier restore left files set aside, and the live database is unusable.
    std::fs::write(home.join("bandito.db"), vec![3u8; 4096]).unwrap();
    let dir = home.join("backups");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("replaced-20270115-080000.db"), "old data").unwrap();

    let _daemon = start(&home);
    let info = wait_for_info(&home.join("bandito.sock")).await;
    assert_eq!(info["safe_mode"], true, "{info}");
    assert_eq!(
        std::fs::read(home.join("bandito.db")).unwrap(),
        vec![3u8; 4096],
        "left as it was"
    );
}
