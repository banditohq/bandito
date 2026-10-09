//! `fs.*` JSON-RPC methods: the app's view of files on the server. The logic is
//! in `crate::files::FileService`; this module maps params, runs the blocking
//! calls on the blocking pool and turns `FsError` into an RPC error whose
//! `data.reason` is the stable code from `FsError::code`.

use super::{App, FS_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::files::{FileService, FsError, Result as FsResult, TEXT_LIMIT};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use std::ops::RangeInclusive;

/// Largest decoded chunk one `fs.upload.append` accepts.
const MAX_CHUNK_BYTES: usize = 1024 * 1024;
const SEARCH_LIMIT: RangeInclusive<usize> = 1..=1000;
const PROJECTS_LIMIT: RangeInclusive<usize> = 1..=200;

/// Answers `fs.*` methods. `None` for any other method.
pub(super) async fn dispatch(app: &App, method: &str, p: Value) -> Option<RpcResult> {
    if !method.starts_with("fs.") {
        return None;
    }
    Some(call(app, method, p).await)
}

async fn call(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "fs.list" => {
            let p: ListParams = params(p)?;
            ok(blocking(app, move |f| f.list(&p.path, p.hidden)).await?)
        }
        "fs.stat" => {
            let p: PathParams = params(p)?;
            ok(blocking(app, move |f| f.stat(&p.path)).await?)
        }
        "fs.read" => {
            let p: PathParams = params(p)?;
            ok(blocking(app, move |f| f.read_text(&p.path, TEXT_LIMIT)).await?)
        }
        "fs.write" => {
            let p: WriteParams = params(p)?;
            let etag = blocking(app, move |f| {
                f.write_text(&p.path, &p.content, p.etag.as_deref(), p.create)
            })
            .await?;
            ok(json!({ "etag": etag }))
        }
        "fs.create_file" => {
            let p: PathParams = params(p)?;
            ok(blocking(app, move |f| f.create_file(&p.path)).await?)
        }
        "fs.mkdir" => {
            let p: PathParams = params(p)?;
            ok(blocking(app, move |f| f.mkdir(&p.path)).await?)
        }
        "fs.rename" => {
            let p: TwoPathParams = params(p)?;
            ok(blocking(app, move |f| f.rename(&p.from, &p.to)).await?)
        }
        "fs.copy" => {
            let p: TwoPathParams = params(p)?;
            ok(blocking(app, move |f| f.copy(&p.from, &p.to)).await?)
        }
        "fs.trash" => {
            let p: PathParams = params(p)?;
            let trashed_to = blocking(app, move |f| f.trash(&p.path)).await?;
            ok(json!({ "trashed_to": trashed_to }))
        }
        "fs.search" => {
            let p: SearchParams = params(p)?;
            check_limit(p.limit, &SEARCH_LIMIT)?;
            ok(blocking(app, move |f| f.search(&p.root, &p.query, p.limit)).await?)
        }
        "fs.projects" => {
            let p: ProjectsParams = params(p)?;
            check_limit(p.limit, &PROJECTS_LIMIT)?;
            ok(blocking(app, move |f| f.project_hints(p.limit)).await?)
        }
        "fs.upload.begin" => {
            let p: PathParams = params(p)?;
            let upload_id = blocking(app, move |f| f.begin_upload(&p.path)).await?;
            ok(json!({ "upload_id": upload_id }))
        }
        "fs.upload.append" => {
            let p: UploadAppend = params(p)?;
            let data = STANDARD
                .decode(&p.data)
                .map_err(|_| RpcError::new(INVALID_PARAMS, "data is not valid base64"))?;
            if data.len() > MAX_CHUNK_BYTES {
                return Err(RpcError::new(INVALID_PARAMS, "chunk is larger than 1 MiB"));
            }
            let written = blocking(app, move |f| f.append_upload(&p.upload_id, p.offset, &data)).await?;
            ok(json!({ "written": written }))
        }
        "fs.upload.commit" => {
            let p: UploadCommit = params(p)?;
            ok(blocking(app, move |f| f.commit_upload(&p.upload_id, p.overwrite)).await?)
        }
        "fs.upload.abort" => {
            let p: UploadRef = params(p)?;
            blocking(app, move |f| f.abort_upload(&p.upload_id)).await?;
            ok(json!({}))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// Runs one `FileService` call on the blocking pool; file errors become RPC errors.
async fn blocking<T, F>(app: &App, f: F) -> Result<T, RpcError>
where
    T: Send + 'static,
    F: FnOnce(&FileService) -> FsResult<T> + Send + 'static,
{
    let files = app.files.clone();
    let out = tokio::task::spawn_blocking(move || f(&files))
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("file task failed: {e}")))?;
    out.map_err(fs_error)
}

/// `data.reason` is the stable code; conflicts carry the current etag, size limits the sizes.
fn fs_error(e: FsError) -> RpcError {
    let mut data = json!({ "reason": e.code() });
    match &e {
        FsError::Conflict { etag } => data["etag"] = json!(etag),
        FsError::TooLarge { size, limit } => {
            data["size"] = json!(size);
            data["limit"] = json!(limit);
        }
        _ => {}
    }
    RpcError::with_data(FS_ERROR, e.to_string(), data)
}

fn check_limit(limit: usize, allowed: &RangeInclusive<usize>) -> Result<(), RpcError> {
    if allowed.contains(&limit) {
        Ok(())
    } else {
        Err(RpcError::new(
            INVALID_PARAMS,
            format!("limit must be between {} and {}", allowed.start(), allowed.end()),
        ))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PathParams {
    path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListParams {
    path: String,
    #[serde(default)]
    hidden: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WriteParams {
    path: String,
    content: String,
    #[serde(default)]
    etag: Option<String>,
    #[serde(default)]
    create: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TwoPathParams {
    from: String,
    to: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchParams {
    root: String,
    query: String,
    #[serde(default = "default_search_limit")]
    limit: usize,
}

fn default_search_limit() -> usize {
    200
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProjectsParams {
    #[serde(default = "default_projects_limit")]
    limit: usize,
}

fn default_projects_limit() -> usize {
    30
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadAppend {
    upload_id: String,
    offset: u64,
    /// Standard base64 of the chunk.
    data: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadCommit {
    upload_id: String,
    #[serde(default)]
    overwrite: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UploadRef {
    upload_id: String,
}

#[cfg(test)]
mod tests {
    use crate::files::FileService;
    use crate::hub::Hub;
    use crate::rpc::{
        App, FS_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, UNAUTHORIZED, dispatch,
    };
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;
    use serde_json::{Value, json};
    use std::path::Path;
    use std::sync::Arc;

    /// An app whose file service serves `dir` (no roots: the whole filesystem, as in production).
    fn app_in(dir: &Path) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new_with_files(sup, dir.join("agents"), FileService::new(dir.to_path_buf(), None))
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    /// `error.data.reason` of a failed `fs.*` call.
    fn reason_of(err: &RpcError) -> String {
        err.data
            .as_ref()
            .and_then(|d| d["reason"].as_str())
            .unwrap_or_default()
            .to_string()
    }

    fn path_of(dir: &Path, rel: &str) -> String {
        dir.join(rel).display().to_string()
    }

    #[tokio::test]
    async fn list_and_read_return_the_etag_and_writes_check_it() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "one").unwrap();
        let app = app_in(dir.path());
        let root = dir.path().display().to_string();

        let listing = call(&app, "fs.list", json!({ "path": root })).await.unwrap();
        let names: Vec<&str> = listing["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["a.txt"]);

        let file = call(&app, "fs.read", json!({ "path": path_of(dir.path(), "a.txt") }))
            .await
            .unwrap();
        assert_eq!(file["content"], "one");
        let etag = file["etag"].as_str().unwrap().to_string();

        let written = call(
            &app,
            "fs.write",
            json!({ "path": path_of(dir.path(), "a.txt"), "content": "two", "etag": etag }),
        )
        .await
        .unwrap();
        let new_etag = written["etag"].as_str().unwrap().to_string();
        assert_ne!(new_etag, etag);

        // The first etag is stale now: the write is refused and the file stays as it was.
        let err = call(
            &app,
            "fs.write",
            json!({ "path": path_of(dir.path(), "a.txt"), "content": "three", "etag": etag }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, FS_ERROR);
        assert_eq!(reason_of(&err), "conflict");
        assert_eq!(err.data.as_ref().unwrap()["etag"], new_etag);
        assert_eq!(std::fs::read_to_string(dir.path().join("a.txt")).unwrap(), "two");
    }

    #[tokio::test]
    async fn write_creates_a_missing_file_only_when_asked() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        let path = path_of(dir.path(), "new.md");

        let err = call(&app, "fs.write", json!({ "path": path, "content": "hi" }))
            .await
            .unwrap_err();
        assert_eq!(reason_of(&err), "not_found");

        call(
            &app,
            "fs.write",
            json!({ "path": path, "content": "hi", "create": true }),
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read_to_string(dir.path().join("new.md")).unwrap(), "hi");
    }

    #[tokio::test]
    async fn folders_and_files_can_be_created_moved_copied_and_trashed() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        let sub = path_of(dir.path(), "docs");

        let made = call(&app, "fs.mkdir", json!({ "path": sub })).await.unwrap();
        assert_eq!(made["kind"], "dir");
        let err = call(&app, "fs.mkdir", json!({ "path": sub })).await.unwrap_err();
        assert_eq!(reason_of(&err), "exists");

        let created = call(&app, "fs.create_file", json!({ "path": format!("{sub}/note.md") }))
            .await
            .unwrap();
        assert_eq!(created["kind"], "file");

        let renamed = call(
            &app,
            "fs.rename",
            json!({ "from": format!("{sub}/note.md"), "to": format!("{sub}/todo.md") }),
        )
        .await
        .unwrap();
        assert_eq!(renamed["name"], "todo.md");

        let copied = call(
            &app,
            "fs.copy",
            json!({ "from": format!("{sub}/todo.md"), "to": format!("{sub}/copy.md") }),
        )
        .await
        .unwrap();
        assert_eq!(copied["name"], "copy.md");

        let trashed = call(&app, "fs.trash", json!({ "path": format!("{sub}/copy.md") }))
            .await
            .unwrap();
        let trashed_to = trashed["trashed_to"].as_str().unwrap();
        assert!(Path::new(trashed_to).exists());
        assert!(!dir.path().join("docs/copy.md").exists());
        assert!(dir.path().join("docs/todo.md").exists());
    }

    #[tokio::test]
    async fn search_finds_names_and_checks_the_limits() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("src/deep")).unwrap();
        std::fs::write(dir.path().join("src/deep/report-final.txt"), "x").unwrap();
        std::fs::write(dir.path().join("src/other.txt"), "x").unwrap();
        let app = app_in(dir.path());
        let root = dir.path().display().to_string();

        let found = call(&app, "fs.search", json!({ "root": root, "query": "report" }))
            .await
            .unwrap();
        let names: Vec<&str> = found
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"report-final.txt"), "{names:?}");

        for limit in [0, 1001] {
            let err = call(
                &app,
                "fs.search",
                json!({ "root": root, "query": "report", "limit": limit }),
            )
            .await
            .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "limit {limit}");
        }
    }

    #[tokio::test]
    async fn projects_checks_the_limits() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        assert!(
            call(&app, "fs.projects", json!({ "limit": 5 }))
                .await
                .unwrap()
                .is_array()
        );
        for limit in [0, 201] {
            let err = call(&app, "fs.projects", json!({ "limit": limit })).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "limit {limit}");
        }
    }

    #[tokio::test]
    async fn upload_in_chunks_then_commit() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        let begun = call(
            &app,
            "fs.upload.begin",
            json!({ "path": path_of(dir.path(), "clip.bin") }),
        )
        .await
        .unwrap();
        let id = begun["upload_id"].as_str().unwrap().to_string();

        let first = call(
            &app,
            "fs.upload.append",
            json!({ "upload_id": id, "offset": 0, "data": STANDARD.encode("hello ") }),
        )
        .await
        .unwrap();
        assert_eq!(first["written"], 6);

        let second = call(
            &app,
            "fs.upload.append",
            json!({ "upload_id": id, "offset": 6, "data": STANDARD.encode("world") }),
        )
        .await
        .unwrap();
        assert_eq!(second["written"], 11);

        let entry = call(&app, "fs.upload.commit", json!({ "upload_id": id }))
            .await
            .unwrap();
        assert_eq!(entry["size"], 11);
        assert_eq!(std::fs::read(dir.path().join("clip.bin")).unwrap(), b"hello world");
    }

    #[tokio::test]
    async fn upload_refuses_bad_base64_wrong_offsets_and_big_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        let begun = call(
            &app,
            "fs.upload.begin",
            json!({ "path": path_of(dir.path(), "big.bin") }),
        )
        .await
        .unwrap();
        let id = begun["upload_id"].as_str().unwrap().to_string();

        let err = call(
            &app,
            "fs.upload.append",
            json!({ "upload_id": id, "offset": 0, "data": "!!! not base64 !!!" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);

        let err = call(
            &app,
            "fs.upload.append",
            json!({ "upload_id": id, "offset": 3, "data": STANDARD.encode("abc") }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, FS_ERROR);
        assert_eq!(reason_of(&err), "invalid_path");

        let too_big = vec![7u8; 1024 * 1024 + 1];
        let err = call(
            &app,
            "fs.upload.append",
            json!({ "upload_id": id, "offset": 0, "data": STANDARD.encode(&too_big) }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);

        // Exactly 1 MiB is allowed.
        let exact = vec![7u8; 1024 * 1024];
        let written = call(
            &app,
            "fs.upload.append",
            json!({ "upload_id": id, "offset": 0, "data": STANDARD.encode(&exact) }),
        )
        .await
        .unwrap();
        assert_eq!(written["written"], 1024 * 1024);

        call(&app, "fs.upload.abort", json!({ "upload_id": id })).await.unwrap();
        assert!(!has_upload_temp(dir.path()), "abort removes the temp file");
        let err = call(&app, "fs.upload.commit", json!({ "upload_id": id }))
            .await
            .unwrap_err();
        assert_eq!(reason_of(&err), "not_found");
        assert!(!dir.path().join("big.bin").exists());
    }

    fn has_upload_temp(dir: &Path) -> bool {
        std::fs::read_dir(dir)
            .unwrap()
            .filter_map(Result::ok)
            .any(|e| e.file_name().to_string_lossy().contains("bandito-upload-"))
    }

    #[tokio::test]
    async fn unknown_fs_method_unknown_fields_and_anonymous_peers_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        let root = dir.path().display().to_string();

        let err = call(&app, "fs.nope", json!({})).await.unwrap_err();
        assert_eq!(err.code, METHOD_NOT_FOUND);

        let err = call(&app, "fs.list", json!({ "path": root, "bogus": true }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);

        let err = dispatch(&app, &Peer::Anonymous, "fs.list", json!({ "path": root }))
            .await
            .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
    }

    #[tokio::test]
    async fn bad_paths_and_binary_files_come_back_with_a_reason() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("blob.bin"), [0u8, 1, 2, 0]).unwrap();
        let app = app_in(dir.path());

        for path in ["", "relative/x.txt"] {
            let err = call(&app, "fs.stat", json!({ "path": path })).await.unwrap_err();
            assert_eq!(err.code, FS_ERROR, "path {path:?}");
            assert_eq!(reason_of(&err), "invalid_path", "path {path:?}");
        }

        let err = call(&app, "fs.read", json!({ "path": path_of(dir.path(), "missing.txt") }))
            .await
            .unwrap_err();
        assert_eq!(reason_of(&err), "not_found");

        let err = call(&app, "fs.read", json!({ "path": path_of(dir.path(), "blob.bin") }))
            .await
            .unwrap_err();
        assert_eq!(reason_of(&err), "binary");
    }

    #[tokio::test]
    async fn error_data_is_sent_only_when_it_is_set() {
        let plain = super::super::response(json!(1), Err(RpcError::new(INVALID_PARAMS, "bad")));
        let plain: Value = serde_json::from_str(&plain).unwrap();
        assert!(plain["error"].get("data").is_none());

        let rich = super::super::response(
            json!(2),
            Err(RpcError::with_data(
                FS_ERROR,
                "conflict",
                json!({ "reason": "conflict" }),
            )),
        );
        let rich: Value = serde_json::from_str(&rich).unwrap();
        assert_eq!(rich["error"]["code"], FS_ERROR);
        assert_eq!(rich["error"]["data"]["reason"], "conflict");
    }

    #[tokio::test]
    async fn daemon_info_lists_the_files_feature() {
        let dir = tempfile::tempdir().unwrap();
        let app = app_in(dir.path());
        let info = call(&app, "daemon.info", json!({})).await.unwrap();
        let features: Vec<&str> = info["features"]
            .as_array()
            .unwrap()
            .iter()
            .map(|f| f.as_str().unwrap())
            .collect();
        assert!(features.contains(&"files"), "{features:?}");
    }
}
