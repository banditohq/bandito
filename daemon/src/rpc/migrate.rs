//! `agents.migrate_*`: moving an agent to another server. The source packs the agent into an archive and serves it in
//! pieces; the target takes the pieces, checks them, unpacks them safely and makes the agent. Owner and apps only (the
//! trust list in `rpc::allowed` keeps agents and anonymous peers out). The archive and the rules are in
//! `crate::migrate`; see docs/ARCHITECTURE.md#agent-migration.

use super::templates::{CREATE_LOCK, catalog_url, shared_services};
use super::{
    App, INVALID_PARAMS, METHOD_NOT_FOUND, MIGRATE_ERROR, RpcError, RpcResult, SERVER_ERROR, create_agent, ok, params,
    schedules,
};
use crate::event::{AgentChange, EventBody};
use crate::migrate::{
    self, Export, ExportInput, Limits, MOVED_TO_MAX, MigrateError, READ_MAX, Remap, ScheduleSpec, TTL_MS, WRITE_MAX,
};
use crate::shared;
use crate::store::{NewAgent, NewSchedule, Store, now_ms, validate_name};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
struct ExportParams {
    agent_id: String,
}

#[derive(Deserialize)]
struct ReadParams {
    token: String,
    offset: u64,
    length: u64,
}

#[derive(Deserialize)]
struct DoneParams {
    token: String,
    #[serde(default)]
    moved_to: Option<String>,
}

#[derive(Deserialize)]
struct BeginParams {
    size: u64,
    sha256: String,
}

#[derive(Deserialize)]
struct WriteParams {
    upload_id: String,
    offset: u64,
    data: String,
}

#[derive(Deserialize)]
struct CommitParams {
    upload_id: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

/// The wire form of a refusal: `error.data.reason` says which.
fn fail(e: MigrateError) -> RpcError {
    RpcError::with_data(MIGRATE_ERROR, e.message, json!({ "reason": e.reason }))
}

fn refuse(reason: &'static str, message: impl Into<String>) -> RpcError {
    fail(MigrateError::new(reason, message))
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> Result<T, RpcError> {
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("migration task failed: {e}")))
}

/// Answers `agents.migrate_*`. `rpc::dispatch` has already refused agents and anonymous peers.
pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "agents.migrate_export" => export(app, params(p)?).await,
        "agents.migrate_read" => read(app, params(p)?).await,
        "agents.migrate_done" => done(app, params(p)?).await,
        "agents.migrate_import_begin" => begin(app, params(p)?).await,
        "agents.migrate_import_write" => write(app, params(p)?).await,
        "agents.migrate_import_commit" => commit(app, params(p)?).await,
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// The folder of the temporary files, with everything older than an hour removed.
fn prepare(app: &App) -> Result<PathBuf, RpcError> {
    let dir = migrate::migrate_dir(&app.data_home).map_err(fail)?;
    app.migrate.sweep(&dir, now_ms(), TTL_MS);
    Ok(dir)
}

/// Removes the leftovers of an earlier run. Called once at start.
pub fn cleanup_at_start(data_home: &Path) {
    if let Ok(dir) = migrate::migrate_dir(data_home) {
        migrate::Registry::default().sweep(&dir, now_ms(), TTL_MS);
    }
}

async fn export(app: &App, req: ExportParams) -> RpcResult {
    let dir = prepare(app)?;
    let store = app.sup.hub().store.clone();
    let agent = store
        .agent_get(&req.agent_id)?
        .ok_or_else(|| refuse("unknown_agent", format!("no agent {}", req.agent_id)))?;
    if !app.migrate.export_slot_free() {
        return Err(refuse(
            "too_many_exports",
            "other exports wait to be read: finish one first",
        ));
    }
    let services = shared_services(&store, &agent)?;
    let schedules: Vec<ScheduleSpec> = store
        .schedule_list(Some(&agent.id))?
        .into_iter()
        .map(|s| ScheduleSpec {
            cron: s.cron,
            tz: s.tz,
            prompt: s.prompt,
            title: s.title,
        })
        .collect();
    let avatar = if agent.avatar.as_ref().is_some_and(|a| a.image) {
        crate::avatar::find(&app.data_home, &agent.id).and_then(|(path, mime)| {
            let ext = if mime == "image/png" { "png" } else { "jpg" };
            std::fs::read(path).ok().map(|bytes| (ext, bytes))
        })
    } else {
        None
    };
    let token = migrate::new_token("mg_");
    let limits = app.migrate.limits().clone();
    let made = {
        let (dir, token, agent) = (dir.clone(), token.clone(), agent.clone());
        blocking(move || {
            migrate::export_archive(
                ExportInput {
                    store: &store,
                    agent: &agent,
                    services,
                    schedules,
                    avatar,
                },
                &dir,
                &token,
                &limits,
            )
        })
        .await?
        .map_err(fail)?
    };
    let export = Export {
        agent_id: agent.id.clone(),
        path: dir.join(format!("{token}.tgz")),
        size: made.size,
        sha256: made.sha256.clone(),
        created_ms: now_ms(),
    };
    let path = export.path.clone();
    if let Err(e) = app.migrate.add_export(token.clone(), export) {
        let _ = std::fs::remove_file(path);
        return Err(fail(e));
    }
    ok(json!({
        "token": token,
        "size": made.size,
        "sha256": made.sha256,
        "files": made.files,
        "events": made.events,
        "skipped": made.skipped,
    }))
}

async fn read(app: &App, req: ReadParams) -> RpcResult {
    prepare(app)?;
    if req.length == 0 {
        return Err(RpcError::new(INVALID_PARAMS, "length must be at least 1"));
    }
    let export = app
        .migrate
        .export(&req.token)
        .ok_or_else(|| refuse("unknown_token", "no such export (it may have expired)"))?;
    if req.offset > export.size {
        return Err(refuse(
            "bad_offset",
            format!("offset is past the end ({} bytes)", export.size),
        ));
    }
    let want = req.length.min(READ_MAX as u64).min(export.size - req.offset) as usize;
    let (path, size, offset) = (export.path.clone(), export.size, req.offset);
    let data = blocking(move || -> std::io::Result<Vec<u8>> {
        let file = std::fs::File::open(path)?;
        if file.metadata()?.len() != size {
            return Err(std::io::Error::other("the archive file changed"));
        }
        let mut buf = vec![0u8; want];
        let mut filled = 0;
        while filled < want {
            let n = file.read_at(&mut buf[filled..], offset + filled as u64)?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        buf.truncate(filled);
        Ok(buf)
    })
    .await?
    .map_err(|e| refuse("io", format!("read the archive: {e}")))?;
    let eof = export.size <= req.offset + data.len() as u64;
    ok(json!({ "data": STANDARD.encode(&data), "eof": eof }))
}

async fn done(app: &App, req: DoneParams) -> RpcResult {
    prepare(app)?;
    let moved_to = match req.moved_to.as_deref().map(str::trim) {
        None => None,
        Some(name) if name.is_empty() || name.chars().count() > MOVED_TO_MAX || name.chars().any(char::is_control) => {
            return Err(RpcError::new(
                INVALID_PARAMS,
                format!("moved_to must be 1 to {MOVED_TO_MAX} characters, without control characters"),
            ));
        }
        Some(name) => Some(name.to_string()),
    };
    let export = app
        .migrate
        .export(&req.token)
        .ok_or_else(|| refuse("unknown_token", "no such export (it may have expired)"))?;
    let store = &app.sup.hub().store;
    let Some(name) = moved_to else {
        app.migrate.remove_export(&req.token);
        return ok(json!({ "ok": true, "agent": Value::Null }));
    };
    let marked = store.agent_set_migrated(&export.agent_id, &name, now_ms());
    app.migrate.remove_export(&req.token);
    if marked.is_err() {
        return Err(refuse("unknown_agent", format!("no agent {}", export.agent_id)));
    }
    app.sup.set_paused(&export.agent_id, true).await?;
    app.sup.hub().emit(
        &export.agent_id,
        EventBody::AgentChanged {
            action: AgentChange::Updated,
        },
    );
    let view = store.agent_view(&export.agent_id)?;
    ok(json!({ "ok": true, "agent": view }))
}

async fn begin(app: &App, req: BeginParams) -> RpcResult {
    let dir = prepare(app)?;
    let id = app
        .migrate
        .begin_upload(&dir, req.size, &req.sha256, app.migrate.limits(), now_ms())
        .map_err(fail)?;
    ok(json!({ "upload_id": id }))
}

async fn write(app: &App, req: WriteParams) -> RpcResult {
    prepare(app)?;
    // Checked on the text first, so a huge chunk is refused before it is decoded.
    if req.data.len() > WRITE_MAX / 3 * 4 + 4 {
        return Err(RpcError::new(
            INVALID_PARAMS,
            format!("a chunk is at most {} MiB", WRITE_MAX / 1024 / 1024),
        ));
    }
    let bytes = STANDARD
        .decode(req.data.trim())
        .map_err(|_| RpcError::new(INVALID_PARAMS, "data is not base64"))?;
    if bytes.len() > WRITE_MAX {
        return Err(RpcError::new(
            INVALID_PARAMS,
            format!("a chunk is at most {} MiB", WRITE_MAX / 1024 / 1024),
        ));
    }
    let app_migrate = &app.migrate;
    // The write is a short append; it runs here and not on a blocking thread, so the registry needs no `Arc`.
    let written = app_migrate
        .write_upload(&req.upload_id, req.offset, &bytes, now_ms())
        .map_err(fail)?;
    ok(json!({ "written": written }))
}

/// The folder the person chose: an absolute path to a folder that exists on this server.
fn check_folder(cwd: &str) -> Result<String, RpcError> {
    let cwd = cwd.trim();
    let p = Path::new(cwd);
    if !p.is_absolute() {
        return Err(refuse("bad_folder", "cwd must be an absolute path on the server"));
    }
    if !p.is_dir() {
        return Err(refuse("bad_folder", format!("folder not found on the server: {cwd}")));
    }
    Ok(cwd.to_string())
}

async fn commit(app: &App, req: CommitParams) -> RpcResult {
    let dir = prepare(app)?;
    // What the person chose is checked first: a wrong folder or name leaves the upload as it is, to try again.
    let cwd = match req.cwd.as_deref() {
        Some(c) if !c.trim().is_empty() => Some(check_folder(c)?),
        _ => None,
    };
    let name = match req.name.as_deref().map(str::trim) {
        Some(n) if !n.is_empty() => {
            validate_name(n).map_err(|e| refuse("bad_name", format!("{e:#}")))?;
            Some(n.to_string())
        }
        _ => None,
    };
    let ticket = app.migrate.take_for_commit(&req.upload_id).map_err(fail)?;
    let result = commit_checked(app, &dir, &ticket.path, cwd, name).await;
    // Done or refused, the upload is spent: a second commit finds nothing.
    app.migrate.finish_upload(&req.upload_id);
    result
}

async fn commit_checked(app: &App, dir: &Path, archive: &Path, cwd: Option<String>, name: Option<String>) -> RpcResult {
    let work = dir.join(migrate::new_token("x-"));
    let limits = app.migrate.limits().clone();
    let unpacked = {
        let (archive, work, limits) = (archive.to_path_buf(), work.clone(), limits.clone());
        blocking(move || {
            let unpacked = migrate::unpack(&archive, &work, &limits)?;
            if let Err(e) = migrate::check_events(&unpacked.events, unpacked.manifest.events_count, &limits) {
                let _ = std::fs::remove_dir_all(&work);
                return Err(e);
            }
            Ok(unpacked)
        })
        .await?
        .map_err(fail)?
    };
    let result = make_agent(app, &unpacked, cwd, name, &limits).await;
    let work_dir = work.clone();
    let _ = blocking(move || std::fs::remove_dir_all(work_dir)).await;
    result
}

/// The unpacked archive is whole and checked: nothing has been created yet. Makes the agent as `agents.create` makes it,
/// then fills it. From the agent's creation on nothing is rolled back: a step that fails is listed in `errors`.
async fn make_agent(
    app: &App,
    unpacked: &migrate::Unpacked,
    cwd: Option<String>,
    name: Option<String>,
    limits: &Limits,
) -> RpcResult {
    let spec = &unpacked.manifest.agent;
    let store = app.sup.hub().store.clone();

    // Every check that can refuse runs before the agent exists.
    let tz = crate::schedule_text::local_zone();
    for s in &spec.schedules {
        if s.prompt.trim().is_empty() {
            return Err(refuse("bad_manifest", "a schedule has no prompt"));
        }
    }
    let mut known: Vec<String> = Vec::new();
    for service in &spec.services {
        if shared::is_catalog_service(service) && !known.contains(service) {
            known.push(service.clone());
        }
    }
    let mut new_agent: NewAgent = serde_json::from_value(json!({ "name": spec.name, "runtime": spec.runtime }))
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent defaults: {e}")))?;
    new_agent.role = spec.role.clone();
    new_agent.model = spec.model.clone();
    new_agent.approval_mode = spec.approval_mode;
    new_agent.system_prompt = spec.system_prompt.clone();
    new_agent.effort = spec.effort;
    new_agent.memory_mode = spec.memory_mode;
    new_agent.context_budget = spec.context_budget;
    new_agent.fallback_runtime = spec.fallback_runtime;
    new_agent.fallback_model = spec.fallback_model.clone();
    new_agent.use_personal_settings = spec.use_personal_settings;
    new_agent.avatar = spec.avatar();
    new_agent.capabilities = spec.capabilities.clone();
    if let Some(cwd) = &cwd {
        new_agent.cwd = cwd.clone();
    }
    // The agent may use the enabled integrations whose catalog id it used before, and no other.
    let mut granted: Vec<String> = Vec::new();
    for integration in store.integration_list()? {
        if !integration.enabled {
            continue;
        }
        let Some(service) = shared::catalog_service(&integration.name, integration.url.as_deref()) else {
            continue;
        };
        if known.contains(&service) && !granted.contains(&integration.id) {
            granted.push(integration.id);
        }
    }
    new_agent.integrations = Some(granted);
    let picture = unpacked.avatar.clone();
    if let Some(path) = &picture {
        let path = path.clone();
        let bytes = blocking(move || std::fs::read(path)).await?;
        let ok_picture = bytes
            .as_ref()
            .map(|b| b.len() <= crate::avatar::MAX_BYTES && crate::avatar::sniff(b).is_some())
            .unwrap_or(false);
        if !ok_picture {
            return Err(refuse(
                "bad_archive",
                "the avatar picture is not a PNG or JPEG of at most 1 MB",
            ));
        }
    }

    let id = {
        // The name is picked and the agent made in one step, as for templates.
        let _creating = CREATE_LOCK.lock().await;
        let wanted = name.unwrap_or_else(|| spec.name.clone());
        let free = fit_name(&store, &wanted)?;
        new_agent.name = free;
        create_agent(app, new_agent, None)?
    };

    let mut errors: Vec<Value> = Vec::new();
    let created = match store.agent_get(&id) {
        Ok(Some(agent)) => Some(agent),
        Ok(None) => {
            note(&mut errors, "agent", format!("agent {id} was created but is not found"));
            None
        }
        Err(e) => {
            note(
                &mut errors,
                "agent",
                format!("agent {id} was created but cannot be read: {e:#}"),
            );
            None
        }
    };

    // The memory folder.
    let mut files_moved = 0;
    let mut new_home: Option<PathBuf> = None;
    match created.as_ref().and_then(|a| a.home_dir.clone()) {
        Some(home) => {
            let (memory, home_path) = (unpacked.memory.clone(), PathBuf::from(&home));
            let moved = blocking({
                let home_path = home_path.clone();
                move || migrate::install_memory(&memory, &home_path)
            })
            .await?;
            match moved {
                Ok(n) => files_moved = n,
                Err(e) => note(
                    &mut errors,
                    "memory",
                    format!("the memory could not be put in {home}: {e}"),
                ),
            }
            new_home = Some(home_path);
        }
        None => note(&mut errors, "memory", "the agent has no folder for its memory".into()),
    }

    // The picture.
    if let Some(path) = picture {
        let (data_home, id) = (app.data_home.clone(), id.clone());
        let store = store.clone();
        let done = blocking(move || -> anyhow::Result<()> {
            let bytes = std::fs::read(path)?;
            crate::avatar::write(&data_home, &id, &bytes)?;
            store.agent_set_avatar_image(&id, Some(now_ms()))?;
            Ok(())
        })
        .await?;
        if let Err(e) = done {
            note(&mut errors, "avatar", format!("{e:#}"));
        }
    }

    // The history, in one transaction.
    let mut events_written = 0;
    {
        let remap = Remap {
            old_home: spec.source_home.clone(),
            new_home: new_home.unwrap_or_default(),
        };
        let (store, id, path, limits) = (store.clone(), id.clone(), unpacked.events.clone(), limits.clone());
        let imported = blocking(move || -> anyhow::Result<usize> {
            let rows = migrate::read_events(&path, &limits)?;
            store.events_import(&id, rows, |kind, payload, map| remap.apply(kind, payload, map))
        })
        .await?;
        match imported {
            Ok(n) => events_written = n,
            Err(e) => note(&mut errors, "events", format!("the history was not moved: {e:#}")),
        }
    }

    // The schedules, off until the person turns them on.
    let mut schedule_ids = Vec::new();
    for (index, s) in spec.schedules.iter().enumerate() {
        let new = NewSchedule {
            agent_id: id.clone(),
            cron: s.cron.clone(),
            tz: if s.tz.trim().is_empty() {
                tz.clone()
            } else {
                s.tz.clone()
            },
            prompt: s.prompt.clone(),
            enabled: false,
            title: s.title.clone(),
        };
        match schedules::create(app, new) {
            Ok(view) => schedule_ids.push(view["id"].clone()),
            Err(e) => errors.push(json!({ "step": "schedule", "index": index, "message": e.message })),
        }
    }

    // The services that have no enabled integration here.
    let mut missing_services: Vec<String> = Vec::new();
    match store.integration_list() {
        Ok(connected) => {
            for service in &spec.services {
                let url = catalog_url(service);
                let present = known.contains(service)
                    && connected
                        .iter()
                        .any(|i| i.enabled && (i.name == *service || (url.is_some() && i.url == url)));
                if !present && !missing_services.contains(service) {
                    missing_services.push(service.clone());
                }
            }
        }
        Err(e) => errors.push(json!({ "step": "integrations", "message": format!("{e:#}") })),
    }

    app.sup.hub().emit(
        &id,
        EventBody::AgentChanged {
            action: AgentChange::Updated,
        },
    );
    let agent = store.agent_view(&id).ok().flatten();
    ok(json!({
        "agent": agent,
        "missing_services": missing_services,
        "schedule_ids": schedule_ids,
        "events": events_written,
        "files": files_moved,
        "errors": errors,
    }))
}

/// `base`, or `base 2`, `base 3`…: the first no agent has (compared without case and outer spaces), cut so that it
/// stays within the 32 characters an agent name may have.
fn fit_name(store: &Store, base: &str) -> Result<String, RpcError> {
    let taken: HashSet<String> = store
        .agent_list()?
        .iter()
        .map(|a| a.name.trim().to_lowercase())
        .collect();
    let base = base.trim();
    for n in 1..1000 {
        let suffix = if n == 1 { String::new() } else { format!(" {n}") };
        let room = 32 - suffix.chars().count();
        let head: String = base.chars().take(room).collect();
        let candidate = format!("{}{suffix}", head.trim_end());
        if !taken.contains(&candidate.to_lowercase()) {
            validate_name(&candidate).map_err(|e| refuse("bad_name", format!("{e:#}")))?;
            return Ok(candidate);
        }
    }
    Err(refuse("bad_name", "no free name for the agent"))
}

fn note(errors: &mut Vec<Value>, step: &str, message: String) {
    errors.push(json!({ "step": step, "message": message }));
}

#[cfg(test)]
mod tests;
