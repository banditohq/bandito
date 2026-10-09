//! One actor task per agent: owns the runtime session, queues messages so a
//! single turn runs at a time, applies the approval policy, and turns runtime
//! output into stored events.

use crate::agent_token::{AgentTokens, SessionToken};
use crate::checkpoint;
use crate::event::LimitWindow;
use crate::event::{AgentStatus, DecidedBy, Decision, EventBody, Source, TurnStatus, Usage};
use crate::hub::Hub;
use crate::limit;
use crate::policy::{self, Verdict};
use crate::redact::Redactor;
use crate::runtime::sandbox::SandboxPolicy;
use crate::runtime::{ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, Session, SpawnConfig};
use crate::store::{
    Agent, CheckpointKind, DEFAULT_CONTEXT_BUDGET, MemoryMode, RuleAction, Store, UsageEntry, WorkspaceKind, new_id,
    now_ms,
};
use crate::workspace::{self, WorkspaceManager, WorkspaceSpec};
use anyhow::{Result, anyhow, bail};
use chrono::{DateTime, Local, NaiveTime, TimeZone};
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// Available runtimes by kind.
#[derive(Default, Clone)]
pub struct Runtimes {
    map: HashMap<RuntimeKind, Arc<dyn Runtime>>,
}

impl Runtimes {
    pub fn insert(&mut self, rt: Arc<dyn Runtime>) {
        self.map.insert(rt.kind(), rt);
    }
    pub fn get(&self, kind: RuntimeKind) -> Option<Arc<dyn Runtime>> {
        self.map.get(&kind).cloned()
    }
    pub fn all(&self) -> Vec<Arc<dyn Runtime>> {
        self.map.values().cloned().collect()
    }
}

/// A message for an agent.
#[derive(Debug, Clone)]
pub struct Inbound {
    pub text: String,
    pub source: Source,
    pub from_agent: Option<String>,
    /// Crew messages in a row since a human or a schedule last spoke.
    pub hops: u8,
    /// Crew conversation this message belongs to. `None` for user and schedule
    /// messages: the turn they start gets a new chain id.
    pub chain: Option<String>,
    /// What the person typed, when `text` is an expansion of it (a slash command for a runtime
    /// that does not run it itself). The thread shows this; the runtime gets `text`.
    pub typed: Option<String>,
    /// Name of the slash command in the message, if one was recognised.
    pub command: Option<String>,
}

impl Inbound {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            source: Source::User,
            from_agent: None,
            hops: 0,
            chain: None,
            typed: None,
            command: None,
        }
    }

    pub fn schedule(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            source: Source::Schedule,
            from_agent: None,
            hops: 0,
            chain: None,
            typed: None,
            command: None,
        }
    }
}

/// Crew loop guards. They stop accidental loops between agents; they are not a
/// security boundary (an agent with shell access can do anything you can).
///
/// Depth: a crew chain stops after this many agent-to-agent hops without a human.
pub const MAX_CREW_HOPS: u8 = 8;
/// Crew messages one turn may send.
pub const MAX_CREW_SENDS_PER_TURN: u8 = 3;
/// Crew messages one chain may carry in total, across all its turns.
pub const MAX_CREW_MESSAGES_PER_CHAIN: u32 = 20;
/// Chain counters are dropped all at once when there are more than this many.
const MAX_TRACKED_CHAINS: usize = 10_000;

/// Crew state of the turn that is running for one agent.
#[derive(Debug, Clone, PartialEq)]
pub struct CrewContext {
    /// Hops of the running turn's message (0 when no turn is running).
    pub hops: u8,
    /// Chain of the running turn (`None` when no turn is running).
    pub chain: Option<String>,
    /// Crew messages this turn has sent, including the one being reserved.
    pub sends: u8,
}

/// An approval the daemon asks for itself, not a runtime (such as a risky browser click).
#[derive(Debug, Clone)]
pub struct ApprovalSpec {
    /// Tool name shown in the app, e.g. `browser_click`.
    pub tool: String,
    pub title: String,
    pub command: Option<String>,
    /// Why the human is asked; shown with the approval.
    pub reason: String,
    /// What the answer is about. Stored and shown with the approval.
    pub input: serde_json::Value,
}

enum Cmd {
    Send(Inbound, oneshot::Sender<Result<()>>),
    /// A daemon-asked approval (see [`Supervisor::ask_external`]). Replies with the approval id and
    /// the channel that carries the answer.
    AskExternal {
        spec: ApprovalSpec,
        reply: oneshot::Sender<Result<(String, oneshot::Receiver<Decision>)>>,
    },
    Interrupt(oneshot::Sender<Result<()>>),
    Resolve {
        approval_id: String,
        decision: Decision,
        by: DecidedBy,
        remember: bool,
        reply: oneshot::Sender<Result<()>>,
    },
    Stop(oneshot::Sender<()>),
    /// New settings for the next session: close the session now, or after the running turn.
    /// `new_chapter`: why the next session starts a new chapter (the folder or the runtime changed).
    Reload {
        new_chapter: Option<&'static str>,
        reply: oneshot::Sender<()>,
    },
    /// Checks the per-turn and hop limits and, if they pass, counts one crew
    /// message against the running turn. Done in the actor so the check and the
    /// count are one step.
    /// Also redacts the message text with the sender's session secrets, before it is delivered.
    ReserveCrewSend(String, oneshot::Sender<Result<(CrewContext, String)>>),
}

pub struct Supervisor {
    hub: Hub,
    runtimes: Runtimes,
    /// Crew MCP server injected into every session.
    mcp: Option<(PathBuf, Vec<String>)>,
    actors: Mutex<HashMap<String, mpsc::Sender<Cmd>>>,
    /// Crew messages accepted so far, per chain id.
    chains: Mutex<HashMap<String, u32>>,
    /// Docker for the container workspaces (see docs/ARCHITECTURE.md#workspaces).
    workspaces: Arc<WorkspaceManager>,
    /// Live session tokens of the agents (see docs/ARCHITECTURE.md#trust-model).
    agent_tokens: Arc<AgentTokens>,
    /// Whether agent sessions run under the macOS sandbox (see `runtime::sandbox`).
    agent_sandbox: Arc<AtomicBool>,
}

/// Approvals nobody answered are denied after this long.
pub const APPROVAL_TTL_MS: i64 = 24 * 60 * 60 * 1000;

/// The snapshot before a turn may take this long. Past it, the turn goes on without a checkpoint.
const CHECKPOINT_BEFORE_TIMEOUT: Duration = Duration::from_secs(10);

/// Put first in the system prompt of an agent that has a home folder. `{home}` is replaced by the folder.
const MEMORY_BRIEFING: &str = "Your memory lives in {home} — plain Markdown files that you own:
- MEMORY.md: a short index. Read it at the start of every session before anything else. Keep it under 200 lines: who the user is, current work, open tasks, decisions, and links to notes.
- notes/<topic>.md: details worth keeping (how things work, decisions and why, preferences).
- journal/<YYYY-MM-DD>.md: one line per finished piece of work.
- files/: anything you make for yourself.
This conversation is split into sessions to stay fast and cheap; older messages are not in your context. If you need something from before, check your memory files, or use the history_search and history_day tools.";

/// Turn sent before a chapter closes, so the agent saves what matters.
const WRAP_UP: &str = "Before we continue: Bandito is about to start a fresh session to keep this conversation fast and cheap. Update your memory now — MEMORY.md (short: user, current work, open tasks, decisions, links), notes/<topic>.md for details, and today's journal. Then reply with one short line saying what you saved.";

/// The memory day starts at this local time.
const DAY_START: (u32, u32) = (4, 0);

/// Start of the memory day that contains `now`: today's 04:00 local, or yesterday's when it is not yet 04:00.
fn day_start(now: DateTime<Local>) -> Option<DateTime<Local>> {
    let (h, m) = DAY_START;
    let at = NaiveTime::from_hms_opt(h, m, 0)?;
    let mut day = now.date_naive();
    if now.time() < at {
        day = day.pred_opt()?;
    }
    Local.from_local_datetime(&day.and_time(at)).earliest()
}

/// True when a new memory day has begun since the last turn: the last turn was before
/// the current day's start (04:00 local).
pub fn new_day_started(last_turn_at: Option<i64>, now: DateTime<Local>) -> bool {
    let (Some(last), Some(start)) = (last_turn_at, day_start(now)) else {
        return false;
    };
    now >= start && last < start.timestamp_millis()
}

/// True when the chapter's context has grown past its budget (`DEFAULT_CONTEXT_BUDGET` if unset).
pub fn over_budget(context_tokens: u64, budget: Option<u32>) -> bool {
    context_tokens > u64::from(budget.unwrap_or(DEFAULT_CONTEXT_BUDGET))
}

/// Should the next message open a new chapter, because a new day began?
fn new_day_due(agent: &Agent, now: DateTime<Local>) -> bool {
    agent.memory_mode != MemoryMode::Full && new_day_started(agent.last_turn_at, now)
}

/// Should a turn that left `context_tokens` close the chapter? Only `smart` memory does this.
fn context_due(agent: &Agent, context_tokens: u64) -> bool {
    agent.memory_mode == MemoryMode::Smart && over_budget(context_tokens, agent.context_budget)
}

/// Why the chapter should close before the next message, if it should: its
/// context is over budget, or a new memory day began while it was open. Read
/// from the store, so it holds after a daemon restart too.
fn chapter_due(agent: &Agent, now: DateTime<Local>) -> Option<&'static str> {
    if context_due(agent, agent.context_tokens) {
        return Some("context");
    }
    // A new day closes only a chapter that has something in it.
    let has_chapter = agent.runtime_session_id.is_some() || agent.context_tokens > 0;
    (has_chapter && new_day_due(agent, now)).then_some("new day")
}

/// The runtime an agent runs on now: its fallback while it is active there, else its primary one.
fn effective_runtime(agent: &Agent) -> RuntimeKind {
    agent.active_runtime.unwrap_or(agent.runtime)
}

/// The runtime to switch to when `current` runs out of usage: the fallback from the primary
/// runtime, the primary one from the fallback. `None` when the agent has no fallback to use.
fn other_runtime(agent: &Agent, current: RuntimeKind) -> Option<RuntimeKind> {
    if current == agent.runtime {
        agent.fallback_runtime.filter(|fb| *fb != current)
    } else {
        Some(agent.runtime)
    }
}

/// The reason shown when a chapter closes without its wrap-up turn.
fn unsaved(reason: &'static str) -> &'static str {
    match reason {
        "context" => "context, memory not saved",
        _ => "new day, memory not saved",
    }
}

/// Start the agent's next chapter in the store and tell the clients. The stored
/// session id is dropped, so the next session cannot resume the old chapter.
fn next_chapter(hub: &Hub, agent_id: &str, reason: &'static str) {
    let context_tokens = match hub.store.agent_get(agent_id) {
        Ok(agent) => agent.map_or(0, |a| a.context_tokens),
        Err(e) => {
            tracing::warn!(agent = agent_id, "read context size: {e:#}");
            0
        }
    };
    match hub.store.agent_next_chapter(agent_id) {
        Ok(chapter) => {
            hub.emit(
                agent_id,
                EventBody::SessionRotated {
                    chapter,
                    reason: reason.to_string(),
                    context_tokens,
                },
            );
        }
        Err(e) => tracing::error!(agent = agent_id, "start next chapter: {e:#}"),
    }
}

impl Supervisor {
    pub fn new(hub: Hub, runtimes: Runtimes, mcp: Option<(PathBuf, Vec<String>)>) -> Arc<Self> {
        Self::new_with_workspaces(hub, runtimes, mcp, WorkspaceManager::system())
    }

    pub fn new_with_workspaces(
        hub: Hub,
        runtimes: Runtimes,
        mcp: Option<(PathBuf, Vec<String>)>,
        workspaces: Arc<WorkspaceManager>,
    ) -> Arc<Self> {
        Arc::new(Self {
            hub,
            runtimes,
            mcp,
            actors: Mutex::new(HashMap::new()),
            chains: Mutex::new(HashMap::new()),
            workspaces,
            agent_tokens: AgentTokens::new(),
            agent_sandbox: Arc::new(AtomicBool::new(true)),
        })
    }

    /// Turns the sandbox for agent sessions on or off (from the config file, at start).
    pub fn set_agent_sandbox(&self, on: bool) {
        self.agent_sandbox.store(on, Ordering::Relaxed);
    }

    /// The live agent session tokens, for `agent.sock`.
    pub fn agent_tokens(&self) -> Arc<AgentTokens> {
        Arc::clone(&self.agent_tokens)
    }

    pub fn workspaces(&self) -> &Arc<WorkspaceManager> {
        &self.workspaces
    }

    pub fn hub(&self) -> &Hub {
        &self.hub
    }

    pub fn runtimes(&self) -> &Runtimes {
        &self.runtimes
    }

    /// After a daemon restart no session is alive, so pending approvals from
    /// the previous run can never be answered: deny them.
    pub fn recover(&self) -> Result<()> {
        for a in self.hub.store.approval_expire_older_than(i64::MAX)? {
            self.hub.emit(
                &a.agent_id,
                EventBody::ApprovalResolved {
                    approval_id: a.id,
                    decision: Decision::Deny,
                    by: DecidedBy::Policy,
                    remember: false,
                },
            );
        }
        Ok(())
    }

    fn actor(&self, agent_id: &str) -> Result<mpsc::Sender<Cmd>> {
        let mut actors = self.actors.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(tx) = actors.get(agent_id).filter(|tx| !tx.is_closed()) {
            return Ok(tx.clone());
        }
        if self.hub.store.agent_get(agent_id)?.is_none() {
            bail!("no agent {agent_id}");
        }
        let (tx, rx) = mpsc::channel(64);
        let actor = Actor {
            id: agent_id.to_string(),
            hub: self.hub.clone(),
            runtimes: self.runtimes.clone(),
            mcp: self.mcp.clone(),
            workspaces: self.workspaces.clone(),
            tokens: self.agent_tokens.clone(),
            sandbox_on: self.agent_sandbox.clone(),
            agent_token: None,
            session: None,
            output: None,
            redactor: Redactor::default(),
            turn: None,
            turn_hops: 0,
            turn_chain: None,
            turn_crew_sends: 0,
            wrap_up: None,
            turn_context: None,
            turn_checkpoints: false,
            reload_after_turn: false,
            new_chapter_after_turn: None,
            session_kind: None,
            turn_limit: false,
            turn_retry: false,
            next_turn_is_retry: false,
            last_message: None,
            queue: VecDeque::new(),
            pending: HashMap::new(),
            status: None,
        };
        tokio::spawn(actor.run(rx));
        actors.insert(agent_id.to_string(), tx.clone());
        Ok(tx)
    }

    async fn call<T>(&self, agent_id: &str, make: impl FnOnce(oneshot::Sender<Result<T>>) -> Cmd) -> Result<T> {
        let (reply, rx) = oneshot::channel();
        self.actor(agent_id)?
            .send(make(reply))
            .await
            .map_err(|_| anyhow!("agent {agent_id} stopped"))?;
        rx.await.map_err(|_| anyhow!("agent {agent_id} stopped"))?
    }

    pub async fn send(&self, agent_id: &str, msg: Inbound) -> Result<()> {
        self.call(agent_id, |r| Cmd::Send(msg, r)).await
    }

    /// One agent messages another by name (the crew MCP tool `crew_send`).
    /// Returns the target agent's id.
    pub async fn crew_send(&self, from_id: &str, to_name: &str, text: &str) -> Result<String> {
        let store = &self.hub.store;
        let from = store.agent_get(from_id)?.ok_or_else(|| anyhow!("no agent {from_id}"))?;
        let to = store
            .agent_by_name(to_name)?
            .ok_or_else(|| anyhow!("no agent named '{to_name}' in this crew"))?;
        if to.id == from.id {
            bail!("an agent can't message itself");
        }
        if text.trim().is_empty() {
            bail!("message is empty");
        }
        // The text is the sender's to protect: redacted with the secrets it holds now, and with
        // those its running session was started with (the actor does that), before the recipient
        // gets it. The recipient's thread and its CLI see only the redacted text.
        let current = Redactor::new(store.secrets_for_agent(from_id)?);
        let text = current.redact(text).into_owned();
        // Depth and per-turn limits are checked and counted by the sender's actor.
        let (ctx, text) = self
            .call(from_id, move |reply| Cmd::ReserveCrewSend(text, reply))
            .await?;
        let chain = ctx.chain.unwrap_or_else(new_id);
        self.reserve_chain_message(&chain)?;
        let msg = Inbound {
            text,
            source: Source::Crew,
            from_agent: Some(from.name),
            hops: ctx.hops.saturating_add(1),
            chain: Some(chain),
            typed: None,
            command: None,
        };
        self.send(&to.id, msg).await?;
        Ok(to.id)
    }

    /// Count one crew message against its chain, refusing past the chain limit.
    fn reserve_chain_message(&self, chain: &str) -> Result<()> {
        let mut chains = self.chains.lock().unwrap_or_else(|e| e.into_inner());
        if chains.len() > MAX_TRACKED_CHAINS {
            tracing::warn!(
                tracked = chains.len(),
                "crew chain counters exceeded {MAX_TRACKED_CHAINS}; clearing them"
            );
            chains.clear();
        }
        let count = chains.entry(chain.to_string()).or_insert(0);
        if *count >= MAX_CREW_MESSAGES_PER_CHAIN {
            bail!(
                "this crew conversation reached its limit ({MAX_CREW_MESSAGES_PER_CHAIN} messages); report back to the user"
            );
        }
        *count += 1;
        Ok(())
    }

    pub async fn interrupt(&self, agent_id: &str) -> Result<()> {
        self.call(agent_id, Cmd::Interrupt).await
    }

    pub async fn resolve(&self, approval_id: &str, decision: Decision, remember: bool) -> Result<()> {
        let a = self
            .hub
            .store
            .approval_get(approval_id)?
            .ok_or_else(|| anyhow!("no approval {approval_id}"))?;
        let approval_id = approval_id.to_string();
        self.call(&a.agent_id, |reply| Cmd::Resolve {
            approval_id,
            decision,
            by: DecidedBy::User,
            remember,
            reply,
        })
        .await
    }

    /// Ask the human before the daemon acts for the agent. The request is recorded and shown in the
    /// agent's feed like a runtime approval, and answered with `approvals.resolve`. No answer within
    /// `limit` denies it, and so does a stop of the agent while it waits (its pending approvals are
    /// expired then). `remember` is ignored for these: no rule is created.
    pub async fn ask_external(&self, agent_id: &str, spec: ApprovalSpec, limit: Duration) -> Result<Decision> {
        let (approval_id, mut answer) = self.call(agent_id, |reply| Cmd::AskExternal { spec, reply }).await?;
        match tokio::time::timeout(limit, &mut answer).await {
            Ok(Ok(decision)) => Ok(decision),
            Ok(Err(_)) => Ok(Decision::Deny),
            Err(_) => {
                // Too late: deny it through the actor, so the store and the feed record it. An answer
                // that arrived meanwhile is kept.
                let _ = self
                    .call(agent_id, |reply| Cmd::Resolve {
                        approval_id,
                        decision: Decision::Deny,
                        by: DecidedBy::Policy,
                        remember: false,
                        reply,
                    })
                    .await;
                Ok(answer.try_recv().unwrap_or(Decision::Deny))
            }
        }
    }

    /// Deny approvals older than [`APPROVAL_TTL_MS`]. Call periodically.
    pub async fn expire_stale_approvals(&self) -> Result<()> {
        let cutoff = now_ms() - APPROVAL_TTL_MS;
        for a in self.hub.store.approval_list_pending(None)? {
            if a.created_at < cutoff {
                let approval_id = a.id.clone();
                let res = self
                    .call(&a.agent_id, |reply| Cmd::Resolve {
                        approval_id,
                        decision: Decision::Deny,
                        by: DecidedBy::Policy,
                        remember: false,
                        reply,
                    })
                    .await;
                if let Err(e) = res {
                    tracing::warn!(approval = a.id, "expire approval: {e:#}");
                }
            }
        }
        Ok(())
    }

    /// Stop the agent's session and its actor (on delete). Settings changes use
    /// [`Supervisor::reload`] instead. The next message starts a fresh session.
    pub async fn stop(&self, agent_id: &str) {
        let tx = self.actors.lock().unwrap_or_else(|e| e.into_inner()).remove(agent_id);
        if let Some(tx) = tx {
            let (reply, rx) = oneshot::channel();
            if tx.send(Cmd::Stop(reply)).await.is_ok() {
                let _ = rx.await;
            }
        }
    }

    /// Apply changed settings to the agent's next session without interrupting a
    /// running turn: the session is closed now, or when the running turn ends.
    /// The chapter goes on (the runtime session id is kept), so the next message
    /// resumes it with the new settings. With `new_chapter` (why: "folder changed",
    /// "runtime changed") the next session starts a new chapter instead: CLI sessions
    /// are tied to their folder and their runtime. An agent with no actor has no
    /// session to close; its next chapter still starts in the store.
    pub async fn reload(&self, agent_id: &str, new_chapter: Option<&'static str>) {
        let tx = self
            .actors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(agent_id)
            .cloned();
        match tx.filter(|tx| !tx.is_closed()) {
            Some(tx) => {
                let (reply, rx) = oneshot::channel();
                if tx.send(Cmd::Reload { new_chapter, reply }).await.is_ok() {
                    let _ = rx.await;
                }
            }
            None => {
                if let Some(reason) = new_chapter {
                    next_chapter(&self.hub, agent_id, reason);
                }
            }
        }
    }

    pub async fn stop_all(&self) {
        let ids: Vec<String> = self
            .actors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .cloned()
            .collect();
        for id in ids {
            self.stop(&id).await;
        }
    }
}

struct PendingApproval {
    key: String,
    /// What a "remember" rule should match: the command, or the title.
    subject: String,
    /// Set for a daemon-asked approval: the answer goes here instead of to a runtime session.
    external: Option<oneshot::Sender<Decision>>,
}

struct Actor {
    id: String,
    hub: Hub,
    runtimes: Runtimes,
    mcp: Option<(PathBuf, Vec<String>)>,
    workspaces: Arc<WorkspaceManager>,
    tokens: Arc<AgentTokens>,
    sandbox_on: Arc<AtomicBool>,
    /// The token of the running session. Dropping it (when the session ends) revokes the token.
    agent_token: Option<SessionToken>,
    session: Option<Box<dyn Session>>,
    output: Option<mpsc::Receiver<RuntimeOutput>>,
    /// Replaces the values of the secrets this session was started with, in everything it stores or sends.
    redactor: Redactor,
    turn: Option<String>,
    turn_hops: u8,
    turn_chain: Option<String>,
    turn_crew_sends: u8,
    /// Set while the wrap-up turn of a chapter that is closing runs: the reason
    /// the chapter closes ("context" or "new day"). Messages wait in the queue meanwhile.
    wrap_up: Option<&'static str>,
    /// Context size the CLI reported for the running turn (see `RuntimeOutput::ContextSize`).
    turn_context: Option<u64>,
    /// The running turn is checkpointed: a "before" snapshot was attempted and an "after" one is due.
    turn_checkpoints: bool,
    /// Settings changed while a session was running: close that session once it is idle.
    reload_after_turn: bool,
    /// A folder or runtime change while a session was running: the next session starts a new chapter, for this reason.
    new_chapter_after_turn: Option<&'static str>,
    /// The runtime of the running session (the primary one or the fallback).
    session_kind: Option<RuntimeKind>,
    /// The running turn reported that the runtime's usage is used up (see `marks_limit`).
    turn_limit: bool,
    /// The running turn is the retry of a message after a switch: it does not echo the message again.
    turn_retry: bool,
    /// The next turn started is a retry (set just before `start_turn`).
    next_turn_is_retry: bool,
    /// The last message a turn was started for, to repeat it on another runtime.
    last_message: Option<Inbound>,
    queue: VecDeque<Inbound>,
    pending: HashMap<String, PendingApproval>,
    status: Option<AgentStatus>,
}

async fn recv_opt(rx: &mut Option<mpsc::Receiver<RuntimeOutput>>) -> Option<RuntimeOutput> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending().await,
    }
}

impl Actor {
    async fn run(mut self, mut rx: mpsc::Receiver<Cmd>) {
        loop {
            tokio::select! {
                cmd = rx.recv() => match cmd {
                    Some(Cmd::Stop(reply)) => {
                        self.close().await;
                        let _ = reply.send(());
                        return;
                    }
                    Some(cmd) => self.command(cmd).await,
                    None => break,
                },
                out = recv_opt(&mut self.output) => match out {
                    Some(o) => self.output(o).await,
                    None => self.output = None,
                },
            }
        }
        self.close().await;
    }

    fn set_status(&mut self, status: AgentStatus, detail: Option<String>) {
        if self.status != Some(status) || detail.is_some() {
            self.status = Some(status);
            self.hub.emit(&self.id, EventBody::AgentStatus { status, detail });
        }
    }

    async fn command(&mut self, cmd: Cmd) {
        match cmd {
            Cmd::Send(msg, reply) => {
                self.queue.push_back(msg);
                let _ = reply.send(self.pump().await);
            }
            Cmd::Interrupt(reply) => {
                let res = match (&mut self.session, &self.turn) {
                    (Some(s), Some(_)) => s.interrupt().await,
                    _ => Ok(()),
                };
                let _ = reply.send(res);
            }
            Cmd::Resolve {
                approval_id,
                decision,
                by,
                remember,
                reply,
            } => {
                let _ = reply.send(self.resolve(&approval_id, decision, by, remember).await);
            }
            Cmd::AskExternal { spec, reply } => {
                let _ = reply.send(self.ask_external(spec));
            }
            Cmd::ReserveCrewSend(text, reply) => {
                let result = self
                    .reserve_crew_send()
                    .map(|ctx| (ctx, self.redactor.redact(&text).into_owned()));
                let _ = reply.send(result);
            }
            Cmd::Reload { new_chapter, reply } => {
                self.reload_after_turn = true;
                self.new_chapter_after_turn = self.new_chapter_after_turn.or(new_chapter);
                self.apply_reload_if_idle().await;
                let _ = reply.send(());
            }
            Cmd::Stop(_) => unreachable!("handled in run"),
        }
    }

    /// Check the hop and per-turn limits, then count one crew message for the
    /// running turn. Without a running turn there is nothing to count against.
    fn reserve_crew_send(&mut self) -> Result<CrewContext> {
        if self.turn.is_none() {
            return Ok(CrewContext {
                hops: 0,
                chain: None,
                sends: 0,
            });
        }
        if self.turn_hops.saturating_add(1) > MAX_CREW_HOPS {
            bail!(
                "crew chain limit reached ({MAX_CREW_HOPS} messages between agents without a human); report back to the user instead"
            );
        }
        if self.turn_crew_sends >= MAX_CREW_SENDS_PER_TURN {
            bail!(
                "crew message limit reached for this turn ({MAX_CREW_SENDS_PER_TURN}); finish the turn and report back to the user"
            );
        }
        self.turn_crew_sends += 1;
        Ok(CrewContext {
            hops: self.turn_hops,
            chain: self.turn_chain.clone(),
            sends: self.turn_crew_sends,
        })
    }

    async fn resolve(&mut self, approval_id: &str, decision: Decision, by: DecidedBy, remember: bool) -> Result<()> {
        let Some(p) = self.pending.remove(approval_id) else {
            bail!("approval {approval_id} is not pending");
        };
        if self.hub.store.approval_resolve(approval_id, decision)?.is_none() {
            bail!("approval {approval_id} was already answered");
        }
        let external = p.external.is_some();
        match p.external {
            // The daemon's own question: whoever asked is waiting for this answer.
            Some(answer) => {
                let _ = answer.send(decision);
            }
            None => {
                if let Some(s) = &mut self.session {
                    s.resolve(&p.key, decision).await?;
                }
            }
        }
        let remember = remember && decision == Decision::Allow && !external;
        if remember {
            self.hub.store.rule_set(Some(&self.id), &p.subject, RuleAction::Allow)?;
        }
        self.hub.emit(
            &self.id,
            EventBody::ApprovalResolved {
                approval_id: approval_id.to_string(),
                decision,
                by,
                remember,
            },
        );
        if self.pending.is_empty() && self.turn.is_some() {
            self.set_status(AgentStatus::Working, None);
        }
        Ok(())
    }

    fn agent(&self) -> Result<Agent> {
        self.hub
            .store
            .agent_get(&self.id)?
            .ok_or_else(|| anyhow!("agent {} was deleted", self.id))
    }

    async fn ensure_session(&mut self) -> Result<()> {
        if self.session.is_some() {
            return Ok(());
        }
        let agent = self.agent()?;
        let kind = effective_runtime(&agent);
        let rt = self
            .runtimes
            .get(kind)
            .ok_or_else(|| anyhow!("runtime {} is not available on this server", kind.as_str()))?;
        // Blocks: memory briefing, role, the user's own instructions.
        let mut blocks: Vec<String> = Vec::new();
        if let Some(home) = agent.home_dir.as_deref() {
            blocks.push(MEMORY_BRIEFING.replace("{home}", home));
        }
        if !agent.role.trim().is_empty() {
            blocks.push(format!(
                "You are {}, the {} in a crew of AI agents run by Bandito.",
                agent.name,
                agent.role.trim()
            ));
        }
        if let Some(sp) = agent.system_prompt.as_deref().filter(|s| !s.trim().is_empty()) {
            blocks.push(sp.to_string());
        }
        let prompt = blocks.join("\n\n");
        let secrets = self.hub.store.secrets_for_agent(&agent.id)?;
        let (token, token_guard) = self.tokens.issue(&agent.id)?;
        // Containers are isolated already; the sandbox is for the agents that run on the server itself.
        let sandbox = match self.tokens.home() {
            Some(home)
                if agent.workspace_id == crate::store::SHARED_WORKSPACE && self.sandbox_on.load(Ordering::Relaxed) =>
            {
                Some(SandboxPolicy {
                    home,
                    exe: std::env::current_exe().ok(),
                    session_files: token_guard
                        .token_file()
                        .into_iter()
                        .chain(token_guard.config_file())
                        .map(Path::to_path_buf)
                        .collect(),
                })
            }
            _ => None,
        };
        let ws = self
            .hub
            .store
            .workspace_get(&agent.workspace_id)?
            .ok_or_else(|| anyhow!("workspace {} is gone", agent.workspace_id))?;
        let (workspace, mcp) = match ws.kind {
            WorkspaceKind::Shared => (WorkspaceSpec::Shared, self.mcp.clone()),
            WorkspaceKind::Container => {
                let mounts = workspace::mounts_for(&self.hub.store, &ws)?;
                self.workspaces.ensure_running(&ws, &mounts).await?;
                // The crew server talks to the daemon socket, which is not mounted: no crew inside a container.
                (self.workspaces.spec(&ws), None)
            }
        };
        let spawned = rt
            .spawn(SpawnConfig {
                agent_id: agent.id.clone(),
                cwd: PathBuf::from(&agent.cwd),
                model: if kind == agent.runtime {
                    agent.model.clone()
                } else {
                    agent.fallback_model.clone()
                },
                system_prompt: (!prompt.is_empty()).then_some(prompt),
                resume: agent.runtime_session_id.clone(),
                program: None,
                mcp: mcp.map(|(prog, mut args)| {
                    args.extend(["--agent".to_string(), agent.id.clone()]);
                    // The bridge reads the token from this file, so the token stays out of argument lists.
                    if let Some(file) = token_guard.token_file() {
                        args.extend(["--token-file".to_string(), file.display().to_string()]);
                    }
                    (prog, args)
                }),
                env: secrets.clone(),
                effort: agent.effort,
                extra_dirs: agent.home_dir.iter().map(PathBuf::from).collect(),
                workspace: Some(workspace),
                agent_token: Some(token.clone()),
                agent_mcp_file: token_guard.config_file().map(Path::to_path_buf),
                sandbox,
            })
            .await?;
        self.session = Some(spawned.session);
        self.output = Some(spawned.output);
        self.session_kind = Some(kind);
        self.agent_token = Some(token_guard);
        // The same values the child got, so what it prints is redacted exactly for them, the token too.
        self.redactor = Redactor::new(secrets.into_iter().chain([("BANDITO_AGENT_TOKEN".to_string(), token)]));
        Ok(())
    }

    /// Start the next queued message if no turn is running.
    async fn pump(&mut self) -> Result<()> {
        if self.turn.is_some() || self.wrap_up.is_some() {
            return Ok(());
        }
        if self.queue.is_empty() {
            return Ok(());
        }
        // A chapter that is over budget, or a new memory day, closes before the message goes out.
        // (If the agent can't be loaded, `ensure_session` reports it below.)
        if let Ok(agent) = self.agent()
            && let Some(reason) = chapter_due(&agent, Local::now())
            && self.begin_rotation(reason, &agent).await
        {
            return Ok(());
        }
        // On a fallback: the primary runtime goes back in as soon as its limit has reset.
        if let Ok(agent) = self.agent()
            && let Some(active) = agent.active_runtime
            && self.runtimes.get(agent.runtime).is_some()
            && self.runtime_free(agent.runtime, now_ms())
        {
            self.switch_runtime(&agent, active, agent.runtime, None).await;
        }
        let Some(msg) = self.queue.pop_front() else {
            return Ok(());
        };
        self.start_turn(msg).await
    }

    /// True when the next message would first close the chapter.
    fn chapter_pending(&self) -> bool {
        self.agent()
            .is_ok_and(|agent| chapter_due(&agent, Local::now()).is_some())
    }

    /// Close the running chapter before the next message. With a home folder the
    /// agent first gets a wrap-up turn; if its session is gone, the session is
    /// resumed for that turn. When that is impossible, the chapter closes without
    /// a wrap-up (logged, and shown in the thread). Returns `true` when the wrap-up
    /// turn is running; its end then finishes the rotation.
    async fn begin_rotation(&mut self, reason: &'static str, agent: &Agent) -> bool {
        if agent.home_dir.is_none() {
            self.rotate(reason).await;
            return false;
        }
        if self.session.is_none() {
            if agent.runtime_session_id.is_none() {
                tracing::warn!(agent = self.id, "chapter closes without a wrap-up: nothing to resume");
                self.rotate(unsaved(reason)).await;
                return false;
            }
            if let Err(e) = self.ensure_session().await {
                tracing::warn!(agent = self.id, "resume for the wrap-up failed: {e:#}");
                self.rotate(unsaved(reason)).await;
                return false;
            }
        }
        self.wrap_up = Some(reason);
        let msg = Inbound {
            text: WRAP_UP.to_string(),
            source: Source::System,
            from_agent: None,
            hops: 0,
            chain: None,
            typed: None,
            command: None,
        };
        match self.start_turn(msg).await {
            Ok(()) => true,
            Err(e) => {
                tracing::warn!(agent = self.id, "wrap-up turn: {e:#}");
                self.wrap_up = None;
                self.rotate(reason).await;
                false
            }
        }
    }

    /// Apply a pending reload now, unless a turn is running or a chapter is about to
    /// close (that close shuts the session down anyway).
    async fn apply_reload_if_idle(&mut self) {
        if self.turn.is_some() || self.wrap_up.is_some() || self.chapter_pending() {
            return;
        }
        self.apply_reload().await;
    }

    /// Apply changed settings: the session is closed, and the next one starts with
    /// them. A folder change also starts a new chapter.
    async fn apply_reload(&mut self) {
        let new_chapter = self.new_chapter_after_turn;
        self.release_session().await;
        if let Some(reason) = new_chapter {
            next_chapter(&self.hub, &self.id, reason);
        }
    }

    /// Shut the CLI session down and forget it, keeping the chapter: the next session
    /// resumes the same runtime session with the current settings. Approvals still
    /// waiting on the closed session are denied.
    async fn release_session(&mut self) {
        if let Some(s) = self.session.take() {
            s.shutdown().await;
        }
        self.agent_token = None;
        self.output = None;
        self.session_kind = None;
        self.reload_after_turn = false;
        self.new_chapter_after_turn = None;
        self.expire_pending();
    }

    /// Drop the CLI session and start the next chapter. Tells the clients.
    async fn rotate(&mut self, reason: &'static str) {
        self.release_session().await;
        next_chapter(&self.hub, &self.id, reason);
    }

    /// Record a finished turn's context size and time. `context` is the size the CLI
    /// reported; without it the turn's usage is the size. With neither, the size stays as it was.
    fn note_turn(&self, context: Option<u64>, usage: Option<Usage>) {
        let store = &self.hub.store;
        let tokens = match context.or_else(|| usage.map(|u| u.input_tokens.saturating_add(u.output_tokens))) {
            Some(tokens) => tokens,
            None => match store.agent_get(&self.id) {
                Ok(agent) => agent.map_or(0, |a| a.context_tokens),
                Err(e) => {
                    tracing::warn!(agent = self.id, "read context size: {e:#}");
                    return;
                }
            },
        };
        if let Err(e) = store.agent_note_turn(&self.id, tokens, now_ms()) {
            tracing::warn!(agent = self.id, "note turn: {e:#}");
        }
    }

    /// Start a turn for `msg` on the session, spawning it if needed.
    async fn start_turn(&mut self, msg: Inbound) -> Result<()> {
        if let Err(e) = self.ensure_session().await {
            let message = format!("could not start the agent: {e:#}");
            self.hub.emit(
                &self.id,
                EventBody::Error {
                    message: message.clone(),
                },
            );
            self.set_status(AgentStatus::Error, Some(message));
            return Err(e);
        }
        let retry = std::mem::take(&mut self.next_turn_is_retry);
        self.turn_retry = retry;
        self.turn_limit = false;
        if !retry && msg.source != Source::System {
            self.last_message = Some(msg.clone());
        }
        let turn_id = new_id();
        self.turn = Some(turn_id.clone());
        self.turn_hops = msg.hops;
        self.turn_chain = Some(msg.chain.clone().unwrap_or_else(new_id));
        self.turn_crew_sends = 0;
        self.turn_context = None;
        self.hub.emit(
            &self.id,
            EventBody::TurnStarted {
                turn_id: turn_id.clone(),
                source: msg.source,
            },
        );
        if !retry {
            self.hub.emit(
                &self.id,
                EventBody::MessageUser {
                    text: msg.typed.clone().unwrap_or_else(|| msg.text.clone()),
                    source: msg.source,
                    from_agent: msg.from_agent.clone(),
                    command: msg.command.clone(),
                },
            );
        }
        self.set_status(AgentStatus::Working, None);
        let dirs = if msg.source == Source::System || retry {
            None
        } else {
            self.checkpoint_dirs()
        };
        self.turn_checkpoints = dirs.is_some();
        if let Some((home, cwd)) = dirs {
            snapshot_before(&self.hub.store, &self.id, &home, &cwd, &msg.text, &turn_id).await;
        }
        let sent = match &mut self.session {
            Some(s) => s.send(&msg.text).await,
            None => Err(anyhow!("no session")),
        };
        if let Err(e) = sent {
            self.end_turn(TurnStatus::Error, Some(format!("could not send the message: {e:#}")));
            return Err(e);
        }
        Ok(())
    }

    fn end_turn(&mut self, status: TurnStatus, error: Option<String>) {
        if let Some(message) = error {
            self.hub.emit(&self.id, EventBody::Error { message });
        }
        if let Some(turn_id) = self.turn.take() {
            self.hub.emit(
                &self.id,
                EventBody::TurnCompleted {
                    turn_id: turn_id.clone(),
                    status,
                    usage: None,
                    cost_usd: None,
                },
            );
            self.spawn_after_checkpoint(turn_id);
        }
    }

    async fn output(&mut self, o: RuntimeOutput) {
        match o {
            RuntimeOutput::Event(EventBody::TurnCompleted {
                status,
                usage,
                cost_usd,
                ..
            }) => {
                let limited = std::mem::take(&mut self.turn_limit);
                let retry = self.turn_retry;
                let turn_id = self.turn.take().unwrap_or_else(new_id);
                self.hub.emit(
                    &self.id,
                    EventBody::TurnCompleted {
                        turn_id: turn_id.clone(),
                        status,
                        usage: usage.clone(),
                        cost_usd,
                    },
                );
                self.spawn_after_checkpoint(turn_id);
                let context = self.turn_context.take();
                self.note_turn(context, usage);
                // The wrap-up turn ended, however it ended: close the chapter now.
                if let Some(reason) = self.wrap_up.take() {
                    self.rotate(reason).await;
                    self.after_turn().await;
                    return;
                }
                // Out of usage: another runtime takes the message, once per message.
                if limited && status == TurnStatus::Error && !retry && self.switch_on_limit().await {
                    return;
                }
                // A chapter over budget closes when the next message comes (see `pump`).
                if self.reload_after_turn && !self.chapter_pending() {
                    self.apply_reload().await;
                }
                self.after_turn().await;
            }
            RuntimeOutput::Event(body) => {
                if self.turn.is_some() && self.marks_limit(&body) {
                    self.turn_limit = true;
                }
                let body = self.redactor.redact_event(body);
                self.hub.emit(&self.id, body);
            }
            RuntimeOutput::ContextSize(tokens) => self.turn_context = Some(tokens),
            RuntimeOutput::ApprovalCancelled { key } => self.cancel_approval(&key),
            RuntimeOutput::SessionId(sid) => {
                if let Err(e) = self.hub.store.agent_set_session(&self.id, Some(&sid)) {
                    tracing::warn!(agent = self.id, "save session id: {e:#}");
                }
            }
            RuntimeOutput::Approval(req) => {
                if let Err(e) = self.approval(req).await {
                    tracing::error!(agent = self.id, "approval: {e:#}");
                }
            }
            RuntimeOutput::Exited { code, stderr_tail } => {
                let stderr_tail = self.redactor.redact(&stderr_tail).into_owned();
                self.session = None;
                self.agent_token = None;
                let failed = code != Some(0);
                let detail = if failed {
                    let tail: Vec<&str> = stderr_tail.lines().rev().take(5).collect();
                    let tail: Vec<&str> = tail.into_iter().rev().collect();
                    Some(
                        format!("the agent process exited (code {code:?}). {}", tail.join(" ").trim())
                            .trim()
                            .to_string(),
                    )
                } else {
                    None
                };
                if self.turn.is_some() {
                    self.end_turn(
                        TurnStatus::Error,
                        detail.clone().or(Some("the agent process exited".into())),
                    );
                } else if let Some(d) = &detail {
                    self.hub.emit(&self.id, EventBody::Error { message: d.clone() });
                }
                self.expire_pending();
                // A wrap-up turn that died still closes its chapter, and the
                // messages waiting behind it go to the fresh session.
                if let Some(reason) = self.wrap_up.take() {
                    self.rotate(reason).await;
                    self.after_turn().await;
                    return;
                }
                // The next session starts with the current settings anyway; a folder change still starts a chapter.
                self.reload_after_turn = false;
                if let Some(reason) = self.new_chapter_after_turn.take() {
                    next_chapter(&self.hub, &self.id, reason);
                }
                if failed {
                    self.set_status(AgentStatus::Error, detail);
                    // Don't respawn in a loop: drop what was queued behind the crash.
                    self.queue.clear();
                } else {
                    self.after_turn().await;
                }
            }
        }
    }

    /// Whether a runtime output says that the running session's usage is used up: an error
    /// message of the runtime, or a usage window reported full.
    fn marks_limit(&self, body: &EventBody) -> bool {
        let Some(kind) = self.session_kind else {
            return false;
        };
        match body {
            EventBody::Error { message } => limit::error_marks_limit(kind, message),
            EventBody::UsageLimits { runtime, windows } => {
                runtime == kind.as_str() && windows.iter().any(limit::window_full)
            }
            _ => false,
        }
    }

    /// The usage cache entry of `kind`, as the runtime last reported it.
    fn usage_of(&self, kind: RuntimeKind) -> Option<UsageEntry> {
        match self.hub.store.usage_list() {
            Ok(list) => list.into_iter().find(|e| e.runtime == kind.as_str()),
            Err(e) => {
                tracing::warn!(agent = self.id, "read usage: {e:#}");
                None
            }
        }
    }

    /// Whether `kind` can take a message now: no usage window blocks it.
    fn runtime_free(&self, kind: RuntimeKind, now_ms: i64) -> bool {
        self.usage_of(kind)
            .is_none_or(|e| !limit::blocked(&e.windows, e.updated_at, now_ms))
    }

    /// The running turn ended because its runtime is out of usage. When the other runtime
    /// (the fallback, or the primary one) is free, switch to it and repeat the last message
    /// there. Returns `true` when the switch was made and the retry turn was started (or
    /// failed to start, with its error shown); `false` leaves the turn as a plain error.
    async fn switch_on_limit(&mut self) -> bool {
        let Ok(agent) = self.agent() else {
            return false;
        };
        let Some(current) = self.session_kind else {
            return false;
        };
        let Some(target) = other_runtime(&agent, current) else {
            return false;
        };
        let now = now_ms();
        if self.runtimes.get(target).is_none() || !self.runtime_free(target, now) {
            tracing::info!(agent = self.id, "no runtime to switch to from {}", current.as_str());
            return false;
        }
        let Some(msg) = self.last_message.clone() else {
            return false;
        };
        // The runtime we leave is recorded as used up, so the primary one waits for its reset
        // (or for a recheck, when the reset time is unknown).
        self.mark_exhausted(current, now);
        let until = self
            .usage_of(current)
            .and_then(|e| limit::blocked_until(&e.windows, e.updated_at, now));
        self.switch_runtime(&agent, current, target, until).await;
        self.next_turn_is_retry = true;
        if let Err(e) = self.start_turn(msg).await {
            tracing::warn!(agent = self.id, "retry on {}: {e:#}", target.as_str());
        }
        true
    }

    /// Records that `kind` is out of usage, when its cache does not say so yet.
    fn mark_exhausted(&self, kind: RuntimeKind, now: i64) {
        let entry = self.usage_of(kind);
        let (mut windows, reported_at) = match entry {
            Some(e) if limit::blocked(&e.windows, e.updated_at, now) => return,
            Some(e) => (e.windows, now),
            None => (Vec::new(), now),
        };
        windows.push(LimitWindow {
            name: "limit".into(),
            utilization: 1.0,
            resets_at: None,
        });
        if let Err(e) = self.hub.store.usage_set(kind.as_str(), &windows, reported_at) {
            tracing::warn!(agent = self.id, "record the limit of {}: {e:#}", kind.as_str());
        }
    }

    /// Makes `to` the agent's runtime for the next session and starts a new chapter, which
    /// has no CLI session to resume. The memory carries over in the agent's files.
    async fn switch_runtime(&mut self, agent: &Agent, from: RuntimeKind, to: RuntimeKind, until: Option<i64>) {
        self.release_session().await;
        let active = (to != agent.runtime).then_some(to);
        if let Err(e) = self.hub.store.agent_set_active_runtime(&self.id, active) {
            tracing::warn!(agent = self.id, "set the active runtime: {e:#}");
        }
        self.hub.emit(
            &self.id,
            EventBody::RuntimeSwitched {
                from: from.as_str().to_string(),
                to: to.as_str().to_string(),
                until,
            },
        );
        next_chapter(&self.hub, &self.id, "runtime switched");
    }

    async fn after_turn(&mut self) {
        if self.queue.is_empty() {
            self.set_status(AgentStatus::Idle, None);
        } else if let Err(e) = self.pump().await {
            tracing::warn!(agent = self.id, "next message: {e:#}");
        }
    }

    /// The runtime withdrew a request: close the approval as denied by policy.
    fn cancel_approval(&mut self, key: &str) {
        let Some(id) = self
            .pending
            .iter()
            .find(|(_, p)| p.key == key)
            .map(|(id, _)| id.clone())
        else {
            return;
        };
        self.pending.remove(&id);
        match self.hub.store.approval_resolve(&id, Decision::Deny) {
            Ok(Some(_)) => {
                self.hub.emit(
                    &self.id,
                    EventBody::ApprovalResolved {
                        approval_id: id,
                        decision: Decision::Deny,
                        by: DecidedBy::Policy,
                        remember: false,
                    },
                );
            }
            Ok(None) => {}
            Err(e) => tracing::error!(agent = self.id, "cancel approval: {e:#}"),
        }
        if self.pending.is_empty() && self.turn.is_some() {
            self.set_status(AgentStatus::Working, None);
        }
    }

    fn expire_pending(&mut self) {
        self.pending.clear();
        match self.hub.store.approval_expire_agent(&self.id) {
            Ok(list) => {
                for a in list {
                    self.hub.emit(
                        &self.id,
                        EventBody::ApprovalResolved {
                            approval_id: a.id,
                            decision: Decision::Deny,
                            by: DecidedBy::Policy,
                            remember: false,
                        },
                    );
                }
            }
            Err(e) => tracing::error!(agent = self.id, "expire approvals: {e:#}"),
        }
    }

    async fn approval(&mut self, mut req: ApprovalRequest) -> Result<()> {
        // Before the policy looks at it, so what is stored, shown and remembered has no secret in it.
        self.redactor.redact_approval(&mut req);
        let agent = self.agent()?;
        let rules = self.hub.store.rule_list(Some(&self.id))?;
        // The agent's own folders: its working folder, and its home when it has one.
        let mut roots = vec![agent.cwd.as_str()];
        roots.extend(agent.home_dir.as_deref());
        let verdict = policy::evaluate(agent.approval_mode, &req, &roots, &rules);
        let subject = req.command.clone().unwrap_or_else(|| req.title.clone());
        match verdict {
            Verdict::Allow => match self.session.as_mut() {
                Some(s) => s.resolve(&req.key, Decision::Allow).await,
                None => Ok(()),
            },
            Verdict::Deny(reason) => {
                let a = self.record(&req, &reason)?;
                self.hub.store.approval_resolve(&a, Decision::Deny)?;
                self.hub.emit(
                    &self.id,
                    EventBody::ApprovalResolved {
                        approval_id: a,
                        decision: Decision::Deny,
                        by: DecidedBy::Policy,
                        remember: false,
                    },
                );
                match self.session.as_mut() {
                    Some(s) => s.resolve(&req.key, Decision::Deny).await,
                    None => Ok(()),
                }
            }
            Verdict::Ask(reason) => {
                let a = self.record(&req, &reason)?;
                self.pending.insert(
                    a,
                    PendingApproval {
                        key: req.key.clone(),
                        subject,
                        external: None,
                    },
                );
                self.set_status(AgentStatus::NeedsYou, None);
                Ok(())
            }
        }
    }

    /// Record a daemon-asked approval. Its answer channel waits in `pending`, and it shows in the feed
    /// like a policy `Ask`. Returns the approval id and the receiver for the answer.
    fn ask_external(&mut self, spec: ApprovalSpec) -> Result<(String, oneshot::Receiver<Decision>)> {
        let mut req = ApprovalRequest {
            key: new_id(),
            call_id: new_id(),
            tool: spec.tool,
            title: spec.title,
            command: spec.command,
            diff: None,
            paths: Vec::new(),
            input: spec.input,
        };
        self.redactor.redact_approval(&mut req);
        let approval_id = self.record(&req, &spec.reason)?;
        let (answer, received) = oneshot::channel();
        self.pending.insert(
            approval_id.clone(),
            PendingApproval {
                key: req.key,
                subject: String::new(),
                external: Some(answer),
            },
        );
        self.set_status(AgentStatus::NeedsYou, None);
        Ok((approval_id, received))
    }

    /// Store an approval and emit `approval.requested`. Returns its id.
    fn record(&self, req: &ApprovalRequest, reason: &str) -> Result<String> {
        let reason = self.redactor.redact(reason);
        let payload = json!({
            "command": req.command,
            "diff": req.diff,
            "input": req.input,
            "key": req.key,
            "reason": reason.as_ref(),
        });
        let a = self
            .hub
            .store
            .approval_create(&self.id, &req.call_id, &req.tool, &req.title, payload)?;
        self.hub.emit(
            &self.id,
            EventBody::ApprovalRequested {
                approval_id: a.id.clone(),
                call_id: req.call_id.clone(),
                tool: req.tool.clone(),
                title: req.title.clone(),
                command: req.command.clone(),
                diff: req.diff.clone(),
                reason: reason.into_owned(),
            },
        );
        Ok(a.id)
    }

    /// The folders a checkpoint needs: the agent's home folder and its working folder, which must
    /// exist. `None` when the agent has no home folder or its folder is gone.
    fn checkpoint_dirs(&self) -> Option<(PathBuf, PathBuf)> {
        let agent = self.agent().ok()?;
        let home = PathBuf::from(agent.home_dir?);
        let cwd = PathBuf::from(agent.cwd);
        cwd.is_dir().then_some((home, cwd))
    }

    /// Snapshot after a turn, in the background: the actor does not wait for git.
    fn spawn_after_checkpoint(&mut self, turn_id: String) {
        if !std::mem::take(&mut self.turn_checkpoints) {
            return;
        }
        let Some((home, cwd)) = self.checkpoint_dirs() else {
            return;
        };
        let store = self.hub.store.clone();
        let agent = self.id.clone();
        tokio::spawn(async move {
            match checkpoint::snapshot(&home, &cwd, "after").await {
                Ok(Some(snap)) => save_checkpoint(
                    &store,
                    &agent,
                    &snap.sha,
                    "after",
                    CheckpointKind::After,
                    Some(&turn_id),
                ),
                Ok(None) => {}
                Err(e) => tracing::warn!(agent = %agent, "checkpoint after the turn: {e}"),
            }
        });
    }

    async fn close(&mut self) {
        if let Some(s) = self.session.take() {
            s.shutdown().await;
        }
        self.agent_token = None;
        self.output = None;
        if self.turn.is_some() {
            self.end_turn(TurnStatus::Interrupted, None);
        }
        self.expire_pending();
        if self.status.is_some() {
            self.set_status(AgentStatus::Offline, None);
        }
    }
}

/// The start of a message as a checkpoint label: its first 60 characters on one line.
fn checkpoint_label(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(60)
        .collect()
}

/// Snapshot before a turn's message reaches the session. A slow or failing snapshot is
/// logged and the turn goes on without it.
async fn snapshot_before(
    store: &Store,
    agent: &str,
    home: &std::path::Path,
    cwd: &std::path::Path,
    text: &str,
    turn_id: &str,
) {
    let label = format!("before: {}", checkpoint_label(text));
    let snap = tokio::time::timeout(CHECKPOINT_BEFORE_TIMEOUT, checkpoint::snapshot(home, cwd, &label));
    match snap.await {
        Ok(Ok(Some(snap))) => save_checkpoint(store, agent, &snap.sha, &label, CheckpointKind::Before, Some(turn_id)),
        Ok(Ok(None)) => {}
        Ok(Err(e)) => tracing::warn!(agent = %agent, "checkpoint before the turn: {e}"),
        Err(_) => tracing::warn!(agent = %agent, "checkpoint before the turn timed out"),
    }
}

/// Store a checkpoint. A failure is logged; the turn is not affected.
fn save_checkpoint(store: &Store, agent: &str, sha: &str, label: &str, kind: CheckpointKind, turn_id: Option<&str>) {
    if let Err(e) = store.checkpoint_add(agent, sha, label, kind, turn_id) {
        tracing::warn!(agent = %agent, "save checkpoint: {e:#}");
    }
}

/// Test doubles shared by the supervisor and RPC tests: a runtime whose sessions
/// log what they are asked to do.
#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use crate::runtime::{RuntimeStatus, Spawned};
    use async_trait::async_trait;

    /// What the mock sessions were asked to do.
    pub type Log = Arc<Mutex<Vec<String>>>;
    /// Output channel of each spawned session, by agent id.
    pub type Outs = Arc<Mutex<HashMap<String, mpsc::Sender<RuntimeOutput>>>>;

    pub struct MockRuntime {
        pub log: Log,
        /// The test pushes runtime output through these.
        pub out: Outs,
        pub spawns: Arc<Mutex<Vec<SpawnConfig>>>,
    }

    struct MockSession {
        log: Log,
    }

    #[async_trait]
    impl Session for MockSession {
        async fn send(&mut self, text: &str) -> Result<()> {
            self.log.lock().unwrap().push(format!("send {text}"));
            Ok(())
        }
        async fn interrupt(&mut self) -> Result<()> {
            self.log.lock().unwrap().push("interrupt".into());
            Ok(())
        }
        async fn resolve(&mut self, key: &str, decision: Decision) -> Result<()> {
            self.log.lock().unwrap().push(format!("resolve {key} {decision:?}"));
            Ok(())
        }
        async fn shutdown(self: Box<Self>) {
            self.log.lock().unwrap().push("shutdown".into());
        }
    }

    #[async_trait]
    impl Runtime for MockRuntime {
        fn kind(&self) -> RuntimeKind {
            RuntimeKind::Claude
        }
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus {
                kind: RuntimeKind::Claude,
                installed: true,
                version: None,
                logged_in: None,
                detail: None,
            }
        }
        async fn spawn(&self, cfg: SpawnConfig) -> Result<Spawned> {
            let (tx, rx) = mpsc::channel(64);
            self.out.lock().unwrap().insert(cfg.agent_id.clone(), tx);
            self.spawns.lock().unwrap().push(cfg);
            Ok(Spawned {
                session: Box::new(MockSession { log: self.log.clone() }),
                output: rx,
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{Log, MockRuntime, Outs};
    use super::*;
    use crate::event::Event;
    use crate::store::{AgentPatch, ApprovalMode, ApprovalStatus, CheckpointKind, Effort, NewAgent, Store};
    use std::time::Duration;
    use tokio::sync::broadcast;

    struct World {
        sup: Arc<Supervisor>,
        store: Arc<Store>,
        log: Log,
        out: Outs,
        spawns: Arc<Mutex<Vec<SpawnConfig>>>,
        events: broadcast::Receiver<Event>,
        agent: String,
    }

    fn world(mode: ApprovalMode) -> World {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                name: "Forge".into(),
                role: "builder".into(),
                runtime: RuntimeKind::Claude,
                model: Some("opus".into()),
                cwd: "/home/u/app".into(),
                approval_mode: mode,
                system_prompt: Some("Keep PRs small.".into()),
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        attach(store, agent.id)
    }

    /// A world over an existing store and agent, with a fresh supervisor and a mock runtime
    /// (as after a daemon restart).
    fn attach(store: Arc<Store>, agent: String) -> World {
        let hub = Hub::new(store.clone());
        let events = hub.subscribe();
        let log: Log = Arc::default();
        let out: Outs = Arc::default();
        let spawns = Arc::new(Mutex::new(Vec::new()));
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(MockRuntime {
            log: log.clone(),
            out: out.clone(),
            spawns: spawns.clone(),
        }));
        World {
            sup: Supervisor::new(hub, rts, None),
            store,
            log,
            out,
            spawns,
            events,
            agent,
        }
    }

    impl World {
        /// Runtime output for this world's agent.
        async fn push(&self, o: RuntimeOutput) {
            self.push_as(&self.agent, o).await;
        }

        async fn push_as(&self, agent: &str, o: RuntimeOutput) {
            let tx = self.out.lock().unwrap().get(agent).cloned().expect("session spawned");
            tx.send(o).await.unwrap();
        }

        /// Next stored/broadcast event matching `pred`, skipping others.
        async fn wait(&mut self, pred: impl Fn(&EventBody) -> bool) -> Event {
            loop {
                let e = tokio::time::timeout(Duration::from_secs(3), self.events.recv())
                    .await
                    .expect("timed out waiting for event")
                    .unwrap();
                if pred(&e.body) {
                    return e;
                }
            }
        }

        async fn wait_log(&self, line: &str) {
            for _ in 0..300 {
                if self.log.lock().unwrap().iter().any(|l| l == line) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            panic!("log never had {line:?}: {:?}", self.log.lock().unwrap());
        }

        fn kinds(&self) -> Vec<String> {
            self.store
                .events_since(0, 1000, None)
                .unwrap()
                .into_iter()
                .map(|e| e.body.to_parts().0)
                .collect()
        }
    }

    fn approval(key: &str, cmd: &str) -> RuntimeOutput {
        RuntimeOutput::Approval(ApprovalRequest {
            key: key.into(),
            call_id: format!("call-{key}"),
            tool: "Bash".into(),
            title: cmd.into(),
            command: Some(cmd.into()),
            diff: None,
            paths: vec![],
            input: json!({"command": cmd}),
        })
    }

    fn done() -> RuntimeOutput {
        RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: String::new(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: Some(0.01),
        })
    }

    fn is_status(s: AgentStatus) -> impl Fn(&EventBody) -> bool {
        move |b| matches!(b, EventBody::AgentStatus { status, .. } if *status == s)
    }

    #[tokio::test]
    async fn turn_lifecycle_and_spawn_config() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("add tests")).await.unwrap();
        w.wait(is_status(AgentStatus::Working)).await;
        w.wait_log("send add tests").await;
        {
            let spawns = w.spawns.lock().unwrap();
            assert_eq!(spawns.len(), 1);
            assert_eq!(spawns[0].model.as_deref(), Some("opus"));
            assert_eq!(spawns[0].cwd, PathBuf::from("/home/u/app"));
            let sp = spawns[0].system_prompt.as_deref().unwrap();
            assert!(sp.contains("You are Forge, the builder"));
            assert!(sp.ends_with("Keep PRs small."));
        }
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.push(RuntimeOutput::Event(EventBody::MessageAssistant { text: "ok".into() }))
            .await;
        w.push(done()).await;
        let e = w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        let EventBody::TurnCompleted { turn_id, cost_usd, .. } = e.body else {
            unreachable!()
        };
        assert!(!turn_id.is_empty(), "supervisor fills the turn id");
        assert_eq!(cost_usd, Some(0.01));
        w.wait(is_status(AgentStatus::Idle)).await;
        assert_eq!(
            w.store
                .agent_get(&w.agent)
                .unwrap()
                .unwrap()
                .runtime_session_id
                .as_deref(),
            Some("sess-1")
        );
        assert_eq!(
            w.kinds(),
            [
                "turn.started",
                "message.user",
                "agent.status",
                "message.assistant",
                "turn.completed",
                "agent.status"
            ]
        );
    }

    #[tokio::test]
    async fn secrets_reach_the_session_env_and_are_redacted_before_storing() {
        let mut w = world(ApprovalMode::Always);
        let value = "sk-live-0123456789";
        w.store.secret_set("OPENAI_API_KEY", value, &["*".into()]).unwrap();
        w.store
            .secret_set("ELSEWHERE_TOKEN", "tok-elsewhere-999", &["someone-else".into()])
            .unwrap();

        w.sup.send(&w.agent, Inbound::user("use the key")).await.unwrap();
        w.wait_log("send use the key").await;
        {
            let spawns = w.spawns.lock().unwrap();
            assert_eq!(spawns[0].env, vec![("OPENAI_API_KEY".to_string(), value.to_string())]);
        }

        w.push(RuntimeOutput::Event(EventBody::ToolCall {
            call_id: "c0".into(),
            tool: "Bash".into(),
            title: format!("echo {value}"),
            input: json!({"command": format!("echo {value}")}),
        }))
        .await;
        w.wait(|b| matches!(b, EventBody::ToolCall { .. })).await;
        w.push(RuntimeOutput::Event(EventBody::MessageAssistant {
            text: format!("the key is {value}"),
        }))
        .await;
        let e = w.wait(|b| matches!(b, EventBody::MessageAssistant { .. })).await;
        assert_eq!(
            e.body,
            EventBody::MessageAssistant {
                text: "the key is ••••OPENAI_API_KEY".into()
            }
        );
        w.push(RuntimeOutput::Approval(ApprovalRequest {
            key: "k1".into(),
            call_id: "c1".into(),
            tool: "Bash".into(),
            title: format!("curl {value}"),
            command: Some(format!("curl -H 'Bearer {value}'")),
            diff: None,
            paths: vec![],
            input: json!({"command": format!("curl -H 'Bearer {value}'")}),
        }))
        .await;
        w.wait(|b| matches!(b, EventBody::ApprovalRequested { .. })).await;

        let stored = serde_json::to_string(&w.store.events_since(0, 1000, None).unwrap()).unwrap();
        assert!(!stored.contains(value), "value stored in an event: {stored}");
        assert!(stored.contains("••••OPENAI_API_KEY"));
        assert!(!stored.contains("tok-elsewhere-999"), "not given to this agent");
    }

    #[tokio::test]
    async fn queues_messages_one_turn_at_a_time() {
        let w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("first")).await.unwrap();
        w.sup.send(&w.agent, Inbound::user("second")).await.unwrap();
        w.wait_log("send first").await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!w.log.lock().unwrap().iter().any(|l| l == "send second"));
        w.push(done()).await;
        w.wait_log("send second").await;
        assert_eq!(w.spawns.lock().unwrap().len(), 1, "one session for both turns");
    }

    #[tokio::test]
    async fn risky_command_waits_for_the_human() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("ship it")).await.unwrap();
        w.wait_log("send ship it").await;

        // routine command: auto-allowed, nothing stored
        w.push(approval("k1", "cargo test")).await;
        w.wait_log("resolve k1 Allow").await;

        w.push(approval("k2", "git push origin main")).await;
        let e = w.wait(|b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        let EventBody::ApprovalRequested {
            approval_id,
            reason,
            command,
            ..
        } = e.body
        else {
            unreachable!()
        };
        assert_eq!(reason, "risky: git push*");
        assert_eq!(command.as_deref(), Some("git push origin main"));
        w.wait(is_status(AgentStatus::NeedsYou)).await;
        assert_eq!(w.store.approval_list_pending(None).unwrap().len(), 1);

        w.sup.resolve(&approval_id, Decision::Allow, true).await.unwrap();
        w.wait_log("resolve k2 Allow").await;
        let e = w.wait(|b| matches!(b, EventBody::ApprovalResolved { .. })).await;
        assert!(matches!(
            e.body,
            EventBody::ApprovalResolved {
                decision: Decision::Allow,
                by: DecidedBy::User,
                remember: true,
                ..
            }
        ));
        w.wait(is_status(AgentStatus::Working)).await;

        // remembered: an allow rule for the exact command
        let rules = w.store.rule_list(Some(&w.agent)).unwrap();
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].pattern, "git push origin main");
        w.push(approval("k3", "git push origin main")).await;
        w.wait_log("resolve k3 Allow").await;

        // answering twice fails
        assert!(w.sup.resolve(&approval_id, Decision::Deny, false).await.is_err());
    }

    #[tokio::test]
    async fn cancelled_approval_is_closed() {
        let mut w = world(ApprovalMode::Always);
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;
        w.push(approval("k1", "ls")).await;
        let e = w.wait(|b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        let EventBody::ApprovalRequested { approval_id, .. } = e.body else {
            unreachable!()
        };
        w.push(RuntimeOutput::ApprovalCancelled { key: "k1".into() }).await;
        let e = w.wait(|b| matches!(b, EventBody::ApprovalResolved { .. })).await;
        assert!(matches!(
            e.body,
            EventBody::ApprovalResolved {
                by: DecidedBy::Policy,
                ..
            }
        ));
        w.wait(is_status(AgentStatus::Working)).await;
        assert!(w.sup.resolve(&approval_id, Decision::Allow, false).await.is_err());
        assert!(!w.log.lock().unwrap().iter().any(|l| l.starts_with("resolve k1")));
    }

    #[tokio::test]
    async fn deny_rule_is_applied_without_asking() {
        let mut w = world(ApprovalMode::Never);
        w.store.rule_set(None, "rm -rf*", RuleAction::Deny).unwrap();
        w.sup.send(&w.agent, Inbound::user("clean")).await.unwrap();
        w.wait_log("send clean").await;
        w.push(approval("k1", "rm -rf /")).await;
        w.wait_log("resolve k1 Deny").await;
        let e = w.wait(|b| matches!(b, EventBody::ApprovalResolved { .. })).await;
        assert!(matches!(
            e.body,
            EventBody::ApprovalResolved {
                decision: Decision::Deny,
                by: DecidedBy::Policy,
                ..
            }
        ));
        assert!(w.store.approval_list_pending(None).unwrap().is_empty());
    }

    #[tokio::test]
    async fn crash_ends_turn_expires_approvals_and_respawns_later() {
        let mut w = world(ApprovalMode::Always);
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;
        w.push(approval("k1", "ls")).await;
        w.wait(is_status(AgentStatus::NeedsYou)).await;
        w.push(RuntimeOutput::Exited {
            code: Some(1),
            stderr_tail: "boom\nPlease run /login".into(),
        })
        .await;
        let e = w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        assert!(matches!(
            e.body,
            EventBody::TurnCompleted {
                status: TurnStatus::Error,
                ..
            }
        ));
        let e = w.wait(is_status(AgentStatus::Error)).await;
        let EventBody::AgentStatus { detail, .. } = e.body else {
            unreachable!()
        };
        assert!(detail.unwrap().contains("Please run /login"));
        let a = w.store.approval_list_pending(None).unwrap();
        assert!(a.is_empty());

        w.sup.send(&w.agent, Inbound::user("again")).await.unwrap();
        w.wait_log("send again").await;
        assert_eq!(w.spawns.lock().unwrap().len(), 2, "a new session after the crash");
    }

    #[tokio::test]
    async fn stop_shuts_down_and_marks_offline() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;
        w.sup.stop(&w.agent).await;
        w.wait_log("shutdown").await;
        let e = w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        assert!(matches!(
            e.body,
            EventBody::TurnCompleted {
                status: TurnStatus::Interrupted,
                ..
            }
        ));
        w.wait(is_status(AgentStatus::Offline)).await;
    }

    #[tokio::test]
    async fn recover_denies_leftover_approvals() {
        let w = world(ApprovalMode::Risky);
        let a = w
            .store
            .approval_create(&w.agent, "c", "Bash", "git push", json!({}))
            .unwrap();
        w.sup.recover().unwrap();
        assert_eq!(
            w.store.approval_get(&a.id).unwrap().unwrap().status,
            ApprovalStatus::Expired
        );
    }

    fn add_agent(store: &Store, name: &str) -> String {
        store
            .agent_create(NewAgent {
                name: name.into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
            .id
    }

    #[tokio::test]
    async fn crew_send_delivers_by_name_with_sender() {
        let mut w = world(ApprovalMode::Risky);
        let scout = add_agent(&w.store, "Scout");
        let to = w.sup.crew_send(&w.agent, "scout", "please review").await.unwrap();
        assert_eq!(to, scout);
        let e = w.wait(|b| matches!(b, EventBody::MessageUser { .. })).await;
        assert_eq!(e.agent_id, scout);
        let EventBody::MessageUser {
            text,
            source,
            from_agent,
            ..
        } = e.body
        else {
            unreachable!()
        };
        assert_eq!(text, "please review");
        assert_eq!(source, Source::Crew);
        assert_eq!(from_agent.as_deref(), Some("Forge"));
    }

    #[tokio::test]
    async fn crew_text_reaches_the_recipient_redacted_with_the_senders_secrets() {
        let mut w = world(ApprovalMode::Risky);
        let scout = add_agent(&w.store, "Scout");
        let old = "sk-old-0123456789";
        w.store.secret_set("OPENAI_API_KEY", old, &[w.agent.clone()]).unwrap();
        // The sender's turn starts its session with the old value in its environment.
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;

        let to = w
            .sup
            .crew_send(&w.agent, "scout", &format!("use {old} now"))
            .await
            .unwrap();
        assert_eq!(to, scout);
        let e = w
            .wait(|b| {
                matches!(
                    b,
                    EventBody::MessageUser {
                        source: Source::Crew,
                        ..
                    }
                )
            })
            .await;
        assert_eq!(e.agent_id, scout);
        assert_eq!(
            e.body,
            EventBody::MessageUser {
                text: "use ••••OPENAI_API_KEY now".into(),
                source: Source::Crew,
                from_agent: Some("Forge".into()),
                command: None,
            }
        );

        // The recipient's turn ends, so its queued next message starts (and is stored) now.
        w.push_as(&scout, done()).await;
        // Rotated while the turn runs: the running session still holds the old value, the store has the new one.
        let new = "sk-new-9876543210";
        w.store.secret_set("OPENAI_API_KEY", new, &[w.agent.clone()]).unwrap();
        w.sup
            .crew_send(&w.agent, "scout", &format!("old {old} and new {new}"))
            .await
            .unwrap();
        let e = w
            .wait(|b| {
                matches!(
                    b,
                    EventBody::MessageUser {
                        source: Source::Crew,
                        ..
                    }
                )
            })
            .await;
        let EventBody::MessageUser { text, .. } = e.body else {
            unreachable!()
        };
        assert_eq!(text, "old ••••OPENAI_API_KEY and new ••••OPENAI_API_KEY");

        let stored = serde_json::to_string(&w.store.events_since(0, 1000, None).unwrap()).unwrap();
        assert!(
            !stored.contains(old) && !stored.contains(new),
            "a value reached the store: {stored}"
        );
    }

    #[tokio::test]
    async fn crew_send_rejects_unknown_self_and_empty() {
        let w = world(ApprovalMode::Risky);
        add_agent(&w.store, "Scout");
        assert!(
            w.sup
                .crew_send(&w.agent, "Nobody", "x")
                .await
                .unwrap_err()
                .to_string()
                .contains("no agent named")
        );
        assert!(
            w.sup
                .crew_send(&w.agent, "forge", "x")
                .await
                .unwrap_err()
                .to_string()
                .contains("itself")
        );
        assert!(
            w.sup
                .crew_send(&w.agent, "Scout", "  ")
                .await
                .unwrap_err()
                .to_string()
                .contains("empty")
        );
    }

    #[tokio::test]
    async fn crew_chain_stops_after_the_hop_limit() {
        let w = world(ApprovalMode::Risky);
        add_agent(&w.store, "Scout");
        // Forge is in a turn that started from a crew message with the maximum hops.
        let msg = Inbound {
            text: "hi".into(),
            source: Source::Crew,
            from_agent: Some("Scout".into()),
            hops: MAX_CREW_HOPS,
            chain: Some("chain-1".into()),
            typed: None,
            command: None,
        };
        w.sup.send(&w.agent, msg).await.unwrap();
        w.wait_log("send hi").await;
        let err = w.sup.crew_send(&w.agent, "Scout", "and again").await.unwrap_err();
        assert!(err.to_string().contains("crew chain limit"));
        // after the turn ends, a fresh chain may start
        w.push(done()).await;
        for _ in 0..100 {
            if w.sup.crew_send(&w.agent, "Scout", "new chain").await.is_ok() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("chain did not reset after the turn");
    }

    #[tokio::test]
    async fn crew_sends_are_limited_per_turn() {
        let mut w = world(ApprovalMode::Risky);
        add_agent(&w.store, "Scout");
        w.sup.send(&w.agent, Inbound::user("review everything")).await.unwrap();
        w.wait_log("send review everything").await;
        for i in 0..MAX_CREW_SENDS_PER_TURN {
            w.sup.crew_send(&w.agent, "Scout", &format!("task {i}")).await.unwrap();
        }
        let err = w.sup.crew_send(&w.agent, "Scout", "one more").await.unwrap_err();
        assert_eq!(
            err.to_string(),
            "crew message limit reached for this turn (3); finish the turn and report back to the user"
        );
        // The next turn gets a fresh allowance.
        w.push(done()).await;
        w.sup.send(&w.agent, Inbound::user("next")).await.unwrap();
        w.wait(|b| matches!(b, EventBody::MessageUser { text, .. } if text == "next"))
            .await;
        w.sup.crew_send(&w.agent, "Scout", "after").await.unwrap();
    }

    #[tokio::test]
    async fn crew_chain_stops_at_the_chain_limit() {
        let mut w = world(ApprovalMode::Risky);
        let forge = w.agent.clone();
        let scout = add_agent(&w.store, "Scout");
        w.sup.send(&forge, Inbound::user("start the relay")).await.unwrap();
        // Every turn that starts sends the maximum per turn to the other agent,
        // then ends. Messages to a busy agent wait in its queue and start later
        // turns. Each turn adds one level of depth and three messages, so the
        // chain reaches 20 messages at depth 7, below MAX_CREW_HOPS: the chain
        // limit is what refuses the 21st.
        let mut accepted = 0;
        let refusal = loop {
            let e = w.wait(|b| matches!(b, EventBody::TurnStarted { .. })).await;
            let (me, to) = if e.agent_id == forge {
                (forge.clone(), "Scout")
            } else {
                (scout.clone(), "Forge")
            };
            let mut refusal = None;
            for _ in 0..MAX_CREW_SENDS_PER_TURN {
                match w.sup.crew_send(&me, to, "ping").await {
                    Ok(_) => accepted += 1,
                    Err(e) => {
                        refusal = Some(e.to_string());
                        break;
                    }
                }
            }
            w.push_as(&me, done()).await;
            if let Some(r) = refusal {
                break r;
            }
        };
        assert_eq!(accepted, MAX_CREW_MESSAGES_PER_CHAIN);
        assert!(refusal.contains("reached its limit (20 messages)"), "{refusal}");
    }

    #[tokio::test]
    async fn user_message_starts_a_new_chain() {
        let mut w = world(ApprovalMode::Risky);
        add_agent(&w.store, "Scout");
        // A chain that has already used all its messages.
        w.sup
            .chains
            .lock()
            .unwrap()
            .insert("spent".into(), MAX_CREW_MESSAGES_PER_CHAIN);
        let msg = Inbound {
            text: "hi".into(),
            source: Source::Crew,
            from_agent: Some("Scout".into()),
            hops: 1,
            chain: Some("spent".into()),
            typed: None,
            command: None,
        };
        w.sup.send(&w.agent, msg).await.unwrap();
        w.wait_log("send hi").await;
        let err = w.sup.crew_send(&w.agent, "Scout", "again").await.unwrap_err();
        assert!(err.to_string().contains("reached its limit"), "{err}");
        w.push(done()).await;
        w.sup.send(&w.agent, Inbound::user("continue")).await.unwrap();
        w.wait(|b| matches!(b, EventBody::MessageUser { text, .. } if text == "continue"))
            .await;
        w.sup.crew_send(&w.agent, "Scout", "fresh").await.unwrap();
    }

    #[tokio::test]
    async fn mcp_server_gets_the_agent_id() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let hub = Hub::new(store.clone());
        let log: Log = Arc::default();
        let spawns = Arc::new(Mutex::new(Vec::new()));
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(MockRuntime {
            log: log.clone(),
            out: Arc::default(),
            spawns: spawns.clone(),
        }));
        let id = add_agent(&store, "Forge");
        let sup = Supervisor::new(hub, rts, Some((PathBuf::from("/bin/bandito"), vec!["mcp".into()])));
        sup.send(&id, Inbound::user("go")).await.unwrap();
        let (prog, args) = spawns.lock().unwrap()[0].mcp.clone().unwrap();
        assert_eq!(prog, PathBuf::from("/bin/bandito"));
        assert_eq!(args, vec!["mcp".to_string(), "--agent".to_string(), id]);
    }

    #[tokio::test]
    async fn unknown_agent_and_missing_runtime() {
        let w = world(ApprovalMode::Risky);
        assert!(w.sup.send("nope", Inbound::user("x")).await.is_err());
        let codex = w
            .store
            .agent_create(NewAgent {
                name: "Scout".into(),
                role: String::new(),
                runtime: RuntimeKind::Codex,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        let err = w.sup.send(&codex.id, Inbound::user("x")).await.unwrap_err();
        assert!(err.to_string().contains("runtime codex is not available"));
    }

    const DAY_MS: i64 = 24 * 60 * 60 * 1000;
    const HOME: &str = "/home/u/bandito/agents/forge";

    fn done_with_usage(input_tokens: u64, output_tokens: u64) -> RuntimeOutput {
        RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: String::new(),
            status: TurnStatus::Ok,
            usage: Some(Usage {
                input_tokens,
                output_tokens,
            }),
            cost_usd: None,
        })
    }

    /// Waits for `session.rotated`: (chapter, reason, context_tokens).
    async fn rotated(w: &mut World) -> (u32, String, u64) {
        let e = w.wait(|b| matches!(b, EventBody::SessionRotated { .. })).await;
        let EventBody::SessionRotated {
            chapter,
            reason,
            context_tokens,
        } = e.body
        else {
            unreachable!()
        };
        (chapter, reason, context_tokens)
    }

    fn was_sent(w: &World, text: &str) -> bool {
        let line = format!("send {text}");
        w.log.lock().unwrap().contains(&line)
    }

    #[tokio::test]
    async fn spawn_gets_memory_briefing_effort_and_home() {
        let w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.store
            .agent_update(
                &w.agent,
                AgentPatch {
                    effort: Some(Some(Effort::High)),
                    ..Default::default()
                },
            )
            .unwrap();
        w.sup.send(&w.agent, Inbound::user("hello")).await.unwrap();
        w.wait_log("send hello").await;
        let spawns = w.spawns.lock().unwrap();
        let cfg = &spawns[0];
        let sp = cfg.system_prompt.as_deref().unwrap();
        let briefing = MEMORY_BRIEFING.replace("{home}", HOME);
        assert!(sp.starts_with(&briefing), "briefing comes first: {sp}");
        assert!(sp[briefing.len()..].starts_with("\n\nYou are Forge, the builder"));
        assert!(sp.ends_with("Keep PRs small."));
        assert!(sp.contains(HOME));
        assert_eq!(cfg.effort, Some(Effort::High));
        assert_eq!(cfg.extra_dirs, vec![PathBuf::from(HOME)]);
    }

    #[tokio::test]
    async fn spawn_without_home_has_no_briefing_or_extra_dirs() {
        let w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("hello")).await.unwrap();
        w.wait_log("send hello").await;
        let spawns = w.spawns.lock().unwrap();
        assert!(
            !spawns[0]
                .system_prompt
                .as_deref()
                .unwrap()
                .contains("Your memory lives")
        );
        assert!(spawns[0].extra_dirs.is_empty());
        assert_eq!(spawns[0].effort, None);
    }

    #[tokio::test]
    async fn smart_chapter_closes_before_the_next_message() {
        let mut w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        // 130k is over the 120k default budget
        w.push(done_with_usage(120_000, 10_000)).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        // nothing closes while the agent is idle
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!w.kinds().iter().any(|k| k == "session.rotated"));
        assert!(!was_sent(&w, WRAP_UP));

        // the next message runs the wrap-up first, and waits behind it
        w.sup.send(&w.agent, Inbound::user("while saving")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!was_sent(&w, "while saving"));

        w.push(done()).await;
        let (chapter, reason, context_tokens) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str(), context_tokens), (2, "context", 130_000));
        w.wait_log("shutdown").await;
        let a = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(a.runtime_session_id, None);
        assert_eq!((a.chapter, a.context_tokens), (2, 0));
        let wrap_up_stored = w.store.events_since(0, 1000, None).unwrap().into_iter().any(|e| {
            matches!(
                e.body,
                EventBody::MessageUser {
                    source: Source::System,
                    ..
                }
            )
        });
        assert!(wrap_up_stored, "the wrap-up turn is in the thread");

        // the held message starts in a fresh session
        w.wait_log("send while saving").await;
        let spawns = w.spawns.lock().unwrap();
        assert_eq!(spawns.len(), 2);
        assert_eq!(spawns[1].resume, None);
    }
    #[tokio::test]
    async fn full_memory_never_starts_a_new_chapter() {
        let w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.store
            .agent_update(
                &w.agent,
                AgentPatch {
                    memory_mode: Some(MemoryMode::Full),
                    ..Default::default()
                },
            )
            .unwrap();
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(done_with_usage(400_000, 100_000)).await;
        w.sup.send(&w.agent, Inbound::user("more")).await.unwrap();
        w.wait_log("send more").await;
        assert!(
            !w.log
                .lock()
                .unwrap()
                .iter()
                .any(|l| l.starts_with("send Before we continue"))
        );
        assert_eq!(w.spawns.lock().unwrap().len(), 1);
        assert!(!w.kinds().iter().any(|k| k == "session.rotated"));
    }

    #[tokio::test]
    async fn without_home_the_chapter_closes_without_wrap_up() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(done_with_usage(130_000, 0)).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        assert!(!w.kinds().iter().any(|k| k == "session.rotated"));

        w.sup.send(&w.agent, Inbound::user("next")).await.unwrap();
        let (chapter, reason, context_tokens) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str(), context_tokens), (2, "context", 130_000));
        w.wait_log("shutdown").await;
        w.wait_log("send next").await;
        assert!(
            !w.log
                .lock()
                .unwrap()
                .iter()
                .any(|l| l.starts_with("send Before we continue"))
        );
        assert_eq!(w.spawns.lock().unwrap().len(), 2);
    }
    #[tokio::test]
    async fn a_failed_wrap_up_turn_still_closes_the_chapter() {
        let mut w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(done_with_usage(130_000, 0)).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        w.sup.send(&w.agent, Inbound::user("next")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        w.push(RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: String::new(),
            status: TurnStatus::Error,
            usage: None,
            cost_usd: None,
        }))
        .await;
        let (chapter, reason, _) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str()), (2, "context"));
        w.wait_log("shutdown").await;
    }
    #[tokio::test]
    async fn a_crashed_wrap_up_turn_still_closes_the_chapter() {
        let mut w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.push(done_with_usage(130_000, 0)).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        w.sup.send(&w.agent, Inbound::user("next")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        w.push(RuntimeOutput::Exited {
            code: Some(1),
            stderr_tail: "boom".into(),
        })
        .await;
        let (chapter, reason, _) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str()), (2, "context"));
        let a = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(
            a.runtime_session_id, None,
            "the next chapter does not resume the old session"
        );
    }
    #[tokio::test]
    async fn reload_while_idle_closes_the_session_and_keeps_the_chapter() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("first")).await.unwrap();
        w.wait_log("send first").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.push(done()).await;
        w.wait(is_status(AgentStatus::Idle)).await;

        w.sup.reload(&w.agent, None).await;
        assert!(w.log.lock().unwrap().iter().any(|l| l == "shutdown"));
        let a = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(a.runtime_session_id.as_deref(), Some("sess-1"), "the chapter goes on");

        // the next message starts a new session that resumes the same chapter
        w.sup.send(&w.agent, Inbound::user("second")).await.unwrap();
        w.wait_log("send second").await;
        let spawns = w.spawns.lock().unwrap();
        assert_eq!(spawns.len(), 2);
        assert_eq!(spawns[1].resume.as_deref(), Some("sess-1"));
    }

    #[tokio::test]
    async fn reload_during_a_turn_waits_for_the_turn_and_shuts_down_once() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.sup.reload(&w.agent, None).await;
        w.sup.reload(&w.agent, None).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !w.log.lock().unwrap().iter().any(|l| l == "shutdown"),
            "the turn is not cut"
        );

        w.push(done()).await;
        w.wait_log("shutdown").await;
        w.wait(is_status(AgentStatus::Idle)).await;
        let shutdowns = w.log.lock().unwrap().iter().filter(|l| *l == "shutdown").count();
        assert_eq!(shutdowns, 1, "two reloads, one shutdown");
        let a = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(a.runtime_session_id.as_deref(), Some("sess-1"));
    }

    #[tokio::test]
    async fn reload_does_not_cut_short_a_pending_chapter_rotation() {
        let mut w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(done_with_usage(130_000, 0)).await;
        w.wait(is_status(AgentStatus::Idle)).await;

        // over budget and idle: the wrap-up still runs before the next message
        w.sup.reload(&w.agent, None).await;
        assert!(!w.log.lock().unwrap().iter().any(|l| l == "shutdown"));
        w.sup.send(&w.agent, Inbound::user("next")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        w.push(done()).await;
        let (chapter, reason, _) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str()), (2, "context"));
        w.wait_log("send next").await;
        assert_eq!(w.spawns.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn reload_without_an_actor_does_nothing() {
        let w = world(ApprovalMode::Risky);
        w.sup.reload(&w.agent, None).await;
        w.sup.reload("nobody", None).await;
        assert!(w.spawns.lock().unwrap().is_empty(), "no session was started");
        assert!(w.log.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn new_day_wraps_up_before_the_next_message() {
        let mut w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.sup.send(&w.agent, Inbound::user("first")).await.unwrap();
        w.wait_log("send first").await;
        w.push(done()).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        // the last turn was two days ago (always before today's 04:00)
        w.store.agent_note_turn(&w.agent, 5_000, now_ms() - 2 * DAY_MS).unwrap();

        w.sup.send(&w.agent, Inbound::user("second")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        assert!(!was_sent(&w, "second"));

        w.push(done()).await;
        let (chapter, reason, context_tokens) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str(), context_tokens), (2, "new day", 5_000));
        w.wait_log("send second").await;
        assert_eq!(w.spawns.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn new_day_without_a_session_starts_the_next_chapter() {
        let w = world(ApprovalMode::Risky);
        // a session id from before a restart: it must not be resumed on a new day
        w.store.agent_set_session(&w.agent, Some("old-session")).unwrap();
        w.store.agent_note_turn(&w.agent, 5_000, now_ms() - 2 * DAY_MS).unwrap();
        w.sup.send(&w.agent, Inbound::user("hi")).await.unwrap();
        w.wait_log("send hi").await;
        assert_eq!(w.spawns.lock().unwrap()[0].resume, None);
        assert_eq!(w.store.agent_get(&w.agent).unwrap().unwrap().chapter, 2);
        // the thread still shows where the new chapter began
        assert!(w.kinds().iter().any(|k| k == "session.rotated"));
    }

    #[tokio::test]
    async fn after_a_restart_an_over_budget_chapter_still_wraps_up() {
        let w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.store.agent_set_session(&w.agent, Some("sess-1")).unwrap();
        w.store.agent_note_turn(&w.agent, 130_000, now_ms()).unwrap();

        // the daemon restarts: a new supervisor over the same store
        let mut w = attach(w.store.clone(), w.agent.clone());
        w.sup.send(&w.agent, Inbound::user("first")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        assert_eq!(w.spawns.lock().unwrap()[0].resume.as_deref(), Some("sess-1"));
        w.push(done()).await;
        let (chapter, reason, context_tokens) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str(), context_tokens), (2, "context", 130_000));
        w.wait_log("send first").await;
        let spawns = w.spawns.lock().unwrap();
        assert_eq!(spawns.len(), 2);
        assert_eq!(spawns[1].resume, None);
    }

    #[tokio::test]
    async fn an_idle_session_that_died_is_resumed_for_the_wrap_up() {
        let mut w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.push(done_with_usage(130_000, 0)).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        // the CLI process exits while the agent is idle
        w.push(RuntimeOutput::Exited {
            code: Some(0),
            stderr_tail: String::new(),
        })
        .await;
        tokio::time::sleep(Duration::from_millis(50)).await;

        w.sup.send(&w.agent, Inbound::user("next")).await.unwrap();
        w.wait_log(&format!("send {WRAP_UP}")).await;
        assert_eq!(w.spawns.lock().unwrap()[1].resume.as_deref(), Some("sess-1"));
        w.push(done()).await;
        let (chapter, reason, _) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str()), (2, "context"));
        w.wait_log("send next").await;
        assert_eq!(w.spawns.lock().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn a_chapter_whose_session_cannot_resume_closes_unsaved() {
        let w = world(ApprovalMode::Risky);
        w.store.agent_set_home(&w.agent, HOME).unwrap();
        w.store.agent_set_session(&w.agent, Some("sess-1")).unwrap();
        w.store.agent_note_turn(&w.agent, 130_000, now_ms()).unwrap();
        // no runtime on this server: the resume fails
        let sup = Supervisor::new(Hub::new(w.store.clone()), Runtimes::default(), None);
        assert!(sup.send(&w.agent, Inbound::user("first")).await.is_err());

        let rotated = w
            .store
            .events_since(0, 1000, None)
            .unwrap()
            .into_iter()
            .find_map(|e| match e.body {
                EventBody::SessionRotated { chapter, reason, .. } => Some((chapter, reason)),
                _ => None,
            });
        assert_eq!(rotated, Some((2, "context, memory not saved".to_string())));
        let a = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(
            a.runtime_session_id, None,
            "the new chapter does not resume the old one"
        );
    }

    #[tokio::test]
    async fn the_reported_context_size_decides_the_chapter_not_the_turn_total() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("work")).await.unwrap();
        w.wait_log("send work").await;
        // the turn's total is over budget, but the context the chapter holds is small
        w.push(RuntimeOutput::ContextSize(20_000)).await;
        w.push(done_with_usage(400_000, 100_000)).await;
        w.wait(is_status(AgentStatus::Idle)).await;
        w.sup.send(&w.agent, Inbound::user("more")).await.unwrap();
        w.wait_log("send more").await;
        assert!(!w.kinds().iter().any(|k| k == "session.rotated"));
        assert_eq!(w.spawns.lock().unwrap().len(), 1);
        assert_eq!(w.store.agent_get(&w.agent).unwrap().unwrap().context_tokens, 20_000);
    }

    #[tokio::test]
    async fn a_folder_change_starts_a_new_chapter_without_resuming() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("first")).await.unwrap();
        w.wait_log("send first").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.push(done()).await;
        w.wait(is_status(AgentStatus::Idle)).await;

        w.sup.reload(&w.agent, Some("folder changed")).await;
        assert!(w.log.lock().unwrap().iter().any(|l| l == "shutdown"));
        let (chapter, reason, _) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str()), (2, "folder changed"));
        let a = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(a.runtime_session_id, None);

        w.sup.send(&w.agent, Inbound::user("second")).await.unwrap();
        w.wait_log("send second").await;
        assert_eq!(w.spawns.lock().unwrap()[1].resume, None);
    }

    #[tokio::test]
    async fn a_folder_change_during_a_turn_starts_the_chapter_after_it() {
        let mut w = world(ApprovalMode::Risky);
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;
        w.push(RuntimeOutput::SessionId("sess-1".into())).await;
        w.sup.reload(&w.agent, Some("folder changed")).await;
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !w.log.lock().unwrap().iter().any(|l| l == "shutdown"),
            "the turn is not cut"
        );

        w.push(done()).await;
        let (chapter, reason, _) = rotated(&mut w).await;
        assert_eq!((chapter, reason.as_str()), (2, "folder changed"));
        w.wait_log("shutdown").await;
        assert_eq!(w.store.agent_get(&w.agent).unwrap().unwrap().runtime_session_id, None);
    }

    #[tokio::test]
    async fn closing_a_session_denies_its_pending_approvals() {
        let mut w = world(ApprovalMode::Always);
        w.sup.send(&w.agent, Inbound::user("go")).await.unwrap();
        w.wait_log("send go").await;
        w.push(approval("k1", "ls")).await;
        w.wait(|b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        w.sup.reload(&w.agent, None).await;
        w.push(done()).await;
        w.wait_log("shutdown").await;
        assert!(w.store.approval_list_pending(None).unwrap().is_empty());
    }

    #[test]
    fn new_day_starts_at_four_local() {
        let at = |d: u32, h: u32, m: u32| Local.with_ymd_and_hms(2026, 10, d, h, m, 0).single().unwrap();
        let ms = |t: DateTime<Local>| t.timestamp_millis();

        // 03:59 on the 9th: the memory day began at 04:00 on the 8th
        let now = at(9, 3, 59);
        assert!(
            !new_day_started(Some(ms(at(8, 4, 0))), now),
            "the day start itself is this day"
        );
        assert!(!new_day_started(Some(ms(at(8, 23, 0))), now));
        assert!(new_day_started(Some(ms(at(8, 3, 59))), now));

        // 04:01 on the 9th: the memory day began at 04:00 on the 9th
        let now = at(9, 4, 1);
        assert!(new_day_started(Some(ms(at(8, 23, 0))), now), "last turn was yesterday");
        assert!(
            new_day_started(Some(ms(at(9, 3, 59))), now),
            "last turn before 04:00 today"
        );
        assert!(!new_day_started(Some(ms(at(9, 4, 0))), now));
        assert!(!new_day_started(None, now), "no turn yet");
    }

    #[test]
    fn over_budget_uses_the_default_when_unset() {
        let default = u64::from(DEFAULT_CONTEXT_BUDGET);
        assert!(!over_budget(default, None));
        assert!(over_budget(default + 1, None));
        assert!(over_budget(50_001, Some(50_000)));
        assert!(!over_budget(50_000, Some(50_000)));
        assert!(!over_budget(100_000, Some(120_000)));
    }

    /// An agent that works in a real folder and has a home folder, so its turns are checkpointed.
    fn checkpoint_world(root: &std::path::Path) -> (World, PathBuf, PathBuf) {
        let proj = root.join("proj");
        let home = root.join("home");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(proj.join("a.txt"), "v1\n").unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                name: "Forge".into(),
                role: "builder".into(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: proj.display().to_string(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
        (attach(store, agent.id), proj, home)
    }

    /// The agent's checkpoints once there are at least `n` (the "after" one is written in the background).
    async fn wait_checkpoints(store: &Store, agent: &str, n: usize) -> Vec<crate::store::Checkpoint> {
        for _ in 0..300 {
            let list = store.checkpoint_list(agent, 50).unwrap();
            if list.len() >= n {
                return list;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("the agent never had {n} checkpoints");
    }

    #[tokio::test]
    async fn a_turn_is_checkpointed_before_and_after() {
        let root = tempfile::tempdir().unwrap();
        let (mut w, proj, home) = checkpoint_world(root.path());
        w.sup.send(&w.agent, Inbound::user("make it v2")).await.unwrap();
        let started = w.wait(|b| matches!(b, EventBody::TurnStarted { .. })).await;
        let EventBody::TurnStarted { turn_id, .. } = started.body else {
            unreachable!()
        };
        w.wait_log("send make it v2").await;
        // The "before" checkpoint is taken before the message reaches the session.
        let before = w.store.checkpoint_list(&w.agent, 10).unwrap();
        assert_eq!(before.len(), 1, "{before:?}");
        assert_eq!(before[0].kind, CheckpointKind::Before);
        assert_eq!(before[0].turn_id.as_deref(), Some(turn_id.as_str()));
        assert_eq!(before[0].label, "before: make it v2");

        std::fs::write(proj.join("a.txt"), "v2\n").unwrap(); // what the agent does
        w.push(done()).await;
        w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;

        let all = wait_checkpoints(&w.store, &w.agent, 2).await;
        assert_eq!(all[0].kind, CheckpointKind::After);
        assert_eq!(all[0].label, "after");
        assert_eq!(all[0].turn_id.as_deref(), Some(turn_id.as_str()));
        let files = crate::checkpoint::changes(&home, &proj, &before[0].sha, Some(&all[0].sha))
            .await
            .unwrap();
        assert_eq!(files.len(), 1, "{files:?}");
        assert_eq!(files[0].path, "a.txt");
        assert_eq!((files[0].additions, files[0].deletions), (Some(1), Some(1)));
    }

    #[tokio::test]
    async fn a_missing_folder_runs_the_turn_without_checkpoints() {
        let root = tempfile::tempdir().unwrap();
        let (mut w, proj, _home) = checkpoint_world(root.path());
        std::fs::remove_dir_all(&proj).unwrap();
        w.sup.send(&w.agent, Inbound::user("hello")).await.unwrap();
        w.wait_log("send hello").await;
        w.push(done()).await;
        w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        assert!(w.store.checkpoint_list(&w.agent, 10).unwrap().is_empty());
    }

    #[tokio::test]
    async fn wrap_up_turns_are_not_checkpointed() {
        let root = tempfile::tempdir().unwrap();
        let (mut w, _proj, _home) = checkpoint_world(root.path());
        let wrap_up = Inbound {
            text: "wrap up".into(),
            source: Source::System,
            from_agent: None,
            hops: 0,
            chain: None,
            typed: None,
            command: None,
        };
        w.sup.send(&w.agent, wrap_up).await.unwrap();
        w.wait_log("send wrap up").await;
        w.push(done()).await;
        w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        assert!(w.store.checkpoint_list(&w.agent, 10).unwrap().is_empty());
    }

    fn external_spec() -> ApprovalSpec {
        ApprovalSpec {
            tool: "browser_click".into(),
            title: "Нажать «Оплатить» на shop.example".into(),
            command: Some("https://shop.example/cart".into()),
            reason: "browser: risky click".into(),
            input: json!({"name": "Оплатить"}),
        }
    }

    #[tokio::test]
    async fn external_ask_is_denied_when_the_agent_stops_while_it_waits() {
        let mut w = world(ApprovalMode::Risky);
        let (sup, agent) = (w.sup.clone(), w.agent.clone());
        let asking =
            tokio::spawn(async move { sup.ask_external(&agent, external_spec(), Duration::from_secs(30)).await });
        w.wait(|b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        w.sup.stop(&w.agent).await;
        assert_eq!(asking.await.unwrap().unwrap(), Decision::Deny);
        assert!(w.store.approval_list_pending(None).unwrap().is_empty());
    }

    #[tokio::test]
    async fn external_ask_never_creates_a_remember_rule() {
        let mut w = world(ApprovalMode::Risky);
        let (sup, agent) = (w.sup.clone(), w.agent.clone());
        let asking =
            tokio::spawn(async move { sup.ask_external(&agent, external_spec(), Duration::from_secs(5)).await });
        let e = w.wait(|b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        let EventBody::ApprovalRequested { approval_id, .. } = e.body else {
            unreachable!()
        };
        w.sup.resolve(&approval_id, Decision::Allow, true).await.unwrap();
        assert_eq!(asking.await.unwrap().unwrap(), Decision::Allow);
        assert!(w.store.rule_list(Some(&w.agent)).unwrap().is_empty());
    }

    // ---- Fallback subscription -------------------------------------------------------

    use crate::event::LimitWindow;

    /// A mock reporting another runtime kind (the fallback). It shares the output map of the Claude mock.
    struct AsKind(MockRuntime, RuntimeKind);

    #[async_trait::async_trait]
    impl Runtime for AsKind {
        fn kind(&self) -> RuntimeKind {
            self.1
        }
        async fn status(&self) -> crate::runtime::RuntimeStatus {
            crate::runtime::RuntimeStatus {
                kind: self.1,
                installed: true,
                version: None,
                logged_in: None,
                detail: None,
            }
        }
        async fn spawn(&self, cfg: SpawnConfig) -> Result<crate::runtime::Spawned> {
            self.0.spawn(cfg).await
        }
    }

    /// A world whose agent runs on Claude with `fallback`. The Codex mock is in the runtimes only if
    /// `codex_available`. Returns the world and the log of the Codex mock.
    fn fallback_world(fallback: Option<RuntimeKind>, codex_available: bool) -> (World, Log) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                name: "Forge".into(),
                role: "builder".into(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/home/u/app".into(),
                approval_mode: ApprovalMode::Never,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: fallback,
                fallback_model: None,
            })
            .unwrap();
        let hub = Hub::new(store.clone());
        let events = hub.subscribe();
        let log: Log = Arc::default();
        let codex_log: Log = Arc::default();
        let out: Outs = Arc::default();
        let spawns = Arc::new(Mutex::new(Vec::new()));
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(MockRuntime {
            log: log.clone(),
            out: out.clone(),
            spawns: spawns.clone(),
        }));
        if codex_available {
            rts.insert(Arc::new(AsKind(
                MockRuntime {
                    log: codex_log.clone(),
                    out: out.clone(),
                    spawns: spawns.clone(),
                },
                RuntimeKind::Codex,
            )));
        }
        let world = World {
            sup: Supervisor::new(hub, rts, None),
            store,
            log,
            out,
            spawns,
            events,
            agent: agent.id,
        };
        (world, codex_log)
    }

    /// The Claude turn ends with the usage limit's error.
    fn limit_error() -> RuntimeOutput {
        RuntimeOutput::Event(EventBody::Error {
            message: "Claude AI usage limit reached|1791543600".into(),
        })
    }

    fn turn_failed() -> RuntimeOutput {
        RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: String::new(),
            status: TurnStatus::Error,
            usage: None,
            cost_usd: None,
        })
    }

    fn full_window(resets_at: Option<i64>) -> LimitWindow {
        LimitWindow {
            name: "five_hour".into(),
            utilization: 1.0,
            resets_at,
        }
    }

    async fn wait_in(log: &Log, line: &str) {
        for _ in 0..300 {
            if log.lock().unwrap().iter().any(|l| l == line) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("log never had {line:?}: {:?}", log.lock().unwrap());
    }

    fn switch_count(w: &World) -> usize {
        w.kinds().iter().filter(|k| *k == "runtime.switched").count()
    }

    #[tokio::test]
    async fn a_limit_error_switches_to_the_fallback_and_repeats_the_message() {
        let (mut w, codex_log) = fallback_world(Some(RuntimeKind::Codex), true);
        w.sup.send(&w.agent, Inbound::user("fix the build")).await.unwrap();
        w.wait_log("send fix the build").await;
        w.push(limit_error()).await;
        w.push(turn_failed()).await;

        let switched = w.wait(|b| matches!(b, EventBody::RuntimeSwitched { .. })).await;
        assert_eq!(
            switched.body,
            EventBody::RuntimeSwitched {
                from: "claude".into(),
                to: "codex".into(),
                until: None,
            }
        );
        wait_in(&codex_log, "send fix the build").await;
        let agent = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(agent.active_runtime, Some(RuntimeKind::Codex));
        assert_eq!(agent.chapter, 2, "the fallback starts a new chapter");
        assert!(
            agent.runtime_session_id.is_none(),
            "the Claude session id is not reused"
        );
        // The message is in the thread once: the retry does not echo it.
        assert_eq!(w.kinds().iter().filter(|k| *k == "message.user").count(), 1);

        w.push(done()).await;
        w.wait(|b| {
            matches!(
                b,
                EventBody::TurnCompleted {
                    status: TurnStatus::Ok,
                    ..
                }
            )
        })
        .await;
    }

    #[tokio::test]
    async fn a_fallback_that_is_also_out_of_usage_is_not_used() {
        let (mut w, codex_log) = fallback_world(Some(RuntimeKind::Codex), true);
        let now = now_ms();
        w.store
            .usage_set("codex", &[full_window(Some(now / 1000 + 3600))], now)
            .unwrap();
        w.sup.send(&w.agent, Inbound::user("fix")).await.unwrap();
        w.wait_log("send fix").await;
        w.push(limit_error()).await;
        w.push(turn_failed()).await;
        w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;

        assert_eq!(switch_count(&w), 0);
        assert!(codex_log.lock().unwrap().is_empty());
        let agent = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(agent.active_runtime, None);
        assert_eq!(agent.chapter, 1);
    }

    #[tokio::test]
    async fn a_retry_that_hits_the_limit_again_is_a_plain_error() {
        let (mut w, codex_log) = fallback_world(Some(RuntimeKind::Codex), true);
        w.sup.send(&w.agent, Inbound::user("fix")).await.unwrap();
        w.wait_log("send fix").await;
        w.push(limit_error()).await;
        w.push(turn_failed()).await;
        w.wait(|b| matches!(b, EventBody::RuntimeSwitched { .. })).await;
        wait_in(&codex_log, "send fix").await;

        w.push(limit_error()).await;
        w.push(turn_failed()).await;
        w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;

        assert_eq!(switch_count(&w), 1, "one switch per message");
        assert_eq!(w.log.lock().unwrap().iter().filter(|l| *l == "send fix").count(), 1);
        assert_eq!(codex_log.lock().unwrap().iter().filter(|l| *l == "send fix").count(), 1);
    }

    #[tokio::test]
    async fn without_a_fallback_a_limit_error_is_a_plain_error() {
        let (mut w, codex_log) = fallback_world(None, true);
        w.sup.send(&w.agent, Inbound::user("fix")).await.unwrap();
        w.wait_log("send fix").await;
        w.push(limit_error()).await;
        w.push(turn_failed()).await;
        let ended = w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        assert!(matches!(
            ended.body,
            EventBody::TurnCompleted {
                status: TurnStatus::Error,
                ..
            }
        ));
        assert_eq!(switch_count(&w), 0);
        assert!(codex_log.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_fallback_that_is_not_available_on_this_server_is_not_used() {
        let (mut w, codex_log) = fallback_world(Some(RuntimeKind::Codex), false);
        w.sup.send(&w.agent, Inbound::user("fix")).await.unwrap();
        w.wait_log("send fix").await;
        w.push(limit_error()).await;
        w.push(turn_failed()).await;
        w.wait(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
        assert_eq!(switch_count(&w), 0);
        assert!(codex_log.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_primary_comes_back_once_its_window_has_reset() {
        let (mut w, codex_log) = fallback_world(Some(RuntimeKind::Codex), true);
        let now = now_ms();
        w.store
            .agent_set_active_runtime(&w.agent, Some(RuntimeKind::Codex))
            .unwrap();
        w.store
            .usage_set("claude", &[full_window(Some(now / 1000 - 10))], now - 3_600_000)
            .unwrap();

        w.sup.send(&w.agent, Inbound::user("again")).await.unwrap();
        let switched = w.wait(|b| matches!(b, EventBody::RuntimeSwitched { .. })).await;
        assert_eq!(
            switched.body,
            EventBody::RuntimeSwitched {
                from: "codex".into(),
                to: "claude".into(),
                until: None,
            }
        );
        w.wait_log("send again").await;
        assert!(codex_log.lock().unwrap().is_empty());
        let agent = w.store.agent_get(&w.agent).unwrap().unwrap();
        assert_eq!(agent.active_runtime, None);
    }

    #[tokio::test]
    async fn the_fallback_stays_while_the_primary_window_is_still_full() {
        let (w, codex_log) = fallback_world(Some(RuntimeKind::Codex), true);
        let now = now_ms();
        w.store
            .agent_set_active_runtime(&w.agent, Some(RuntimeKind::Codex))
            .unwrap();
        w.store
            .usage_set("claude", &[full_window(Some(now / 1000 + 3600))], now)
            .unwrap();

        w.sup.send(&w.agent, Inbound::user("again")).await.unwrap();
        wait_in(&codex_log, "send again").await;
        assert_eq!(switch_count(&w), 0);
        assert!(w.log.lock().unwrap().is_empty());
    }
}

#[cfg(test)]
mod workspace_tests {
    use super::testing::MockRuntime;
    use super::*;
    use crate::store::{ApprovalMode, MemoryMode, Network, NewAgent, NewWorkspace, Store, WorkspaceKind};
    use crate::workspace::testing::fake_docker;
    use crate::workspace::{WorkspaceManager, WorkspaceSpec};
    use std::time::Duration;

    fn rig(store: Arc<Store>, manager: Arc<WorkspaceManager>) -> (Arc<Supervisor>, Arc<Mutex<Vec<SpawnConfig>>>) {
        let spawns = Arc::new(Mutex::new(Vec::new()));
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(MockRuntime {
            log: Arc::default(),
            out: Arc::default(),
            spawns: spawns.clone(),
        }));
        let hub = Hub::new(store);
        (Supervisor::new_with_workspaces(hub, rts, None, manager), spawns)
    }

    fn agent(store: &Store, name: &str, workspace: &str) -> String {
        store
            .agent_create_in(
                NewAgent {
                    name: name.into(),
                    role: String::new(),
                    runtime: RuntimeKind::Claude,
                    model: None,
                    cwd: std::env::temp_dir().display().to_string(),
                    approval_mode: ApprovalMode::Never,
                    system_prompt: None,
                    effort: None,
                    memory_mode: MemoryMode::Smart,
                    context_budget: None,
                    fallback_runtime: None,
                    fallback_model: None,
                },
                workspace,
            )
            .unwrap()
            .id
    }

    async fn first_spawn(spawns: &Arc<Mutex<Vec<SpawnConfig>>>) -> SpawnConfig {
        for _ in 0..100 {
            if let Some(cfg) = spawns.lock().unwrap().first().cloned() {
                return cfg;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("no session was spawned");
    }

    fn scratch_manager() -> Arc<WorkspaceManager> {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().to_path_buf();
        std::mem::forget(dir);
        WorkspaceManager::new(PathBuf::from("/nonexistent/bandito-docker"), path.join("build"))
    }

    #[tokio::test]
    async fn a_shared_agent_gets_the_shared_spec_and_its_mcp_server() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let id = agent(&store, "Forge", "shared");
        let (sup, spawns) = rig(store, scratch_manager());
        sup.send(&id, Inbound::user("go")).await.unwrap();
        let cfg = first_spawn(&spawns).await;
        assert_eq!(cfg.workspace, Some(WorkspaceSpec::Shared));
    }

    #[tokio::test]
    async fn a_session_gets_its_own_token_and_loses_it_when_it_ends() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let id = agent(&store, "Forge", "shared");
        let (sup, spawns) = rig(store, scratch_manager());
        sup.send(&id, Inbound::user("go")).await.unwrap();
        let cfg = first_spawn(&spawns).await;
        let token = cfg.agent_token.clone().expect("a session gets a token");
        assert!(token.starts_with("bat_"), "{token}");
        assert_eq!(sup.agent_tokens().agent_for(&token), Some(id.clone()));
        sup.stop(&id).await;
        assert_eq!(sup.agent_tokens().agent_for(&token), None);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_container_agent_starts_its_container_and_runs_inside_it() {
        let fake = fake_docker(None);
        let store = Arc::new(Store::open_in_memory().unwrap());
        let box_ws = store
            .workspace_create(NewWorkspace {
                name: "Box".into(),
                kind: WorkspaceKind::Container,
                image: Some("img:1".into()),
                cpus: None,
                memory_mb: None,
                network: Network::Internet,
                mounts: Vec::new(),
            })
            .unwrap();
        let id = agent(&store, "Scout", &box_ws.id);
        let manager = WorkspaceManager::new(fake.docker.clone(), fake.dir.path().join("build"));
        let (sup, spawns) = rig(store, manager);
        sup.send(&id, Inbound::user("go")).await.unwrap();

        let cfg = first_spawn(&spawns).await;
        let name = format!("bandito-ws-{}", box_ws.id);
        assert_eq!(
            cfg.workspace,
            Some(WorkspaceSpec::Container {
                name: name.clone(),
                docker: fake.docker.clone(),
            })
        );
        assert!(
            cfg.mcp.is_none(),
            "a container cannot reach the daemon socket, so no crew server"
        );
        let cwd = std::env::temp_dir().display().to_string();
        let log = fake.calls();
        let run = log
            .iter()
            .find(|l| l.starts_with(&format!("run -d --name {name} ")))
            .unwrap_or_else(|| panic!("container created: {log:?}"));
        assert!(
            run.contains(&format!("source={cwd},target={cwd}")),
            "the agent's folder is mounted: {run}"
        );
    }
    /// A mock that reports another runtime kind, as the fallback runtime does.
    struct OtherKind {
        kind: RuntimeKind,
        inner: MockRuntime,
    }

    #[async_trait::async_trait]
    impl Runtime for OtherKind {
        fn kind(&self) -> RuntimeKind {
            self.kind
        }
        async fn status(&self) -> crate::runtime::RuntimeStatus {
            crate::runtime::RuntimeStatus {
                kind: self.kind,
                installed: true,
                version: None,
                logged_in: None,
                detail: None,
            }
        }
        async fn spawn(&self, cfg: SpawnConfig) -> Result<crate::runtime::Spawned> {
            self.inner.spawn(cfg).await
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_fallback_runtime_runs_in_the_agents_container_too() {
        let fake = fake_docker(None);
        let store = Arc::new(Store::open_in_memory().unwrap());
        let box_ws = store
            .workspace_create(NewWorkspace {
                name: "Box".into(),
                kind: WorkspaceKind::Container,
                image: Some("img:1".into()),
                cpus: None,
                memory_mb: None,
                network: Network::Internet,
                mounts: Vec::new(),
            })
            .unwrap();
        let id = agent(&store, "Scout", &box_ws.id);
        // The agent has switched to its fallback (Codex) after a limit error on Claude.
        store.agent_set_active_runtime(&id, Some(RuntimeKind::Codex)).unwrap();

        let spawns = Arc::new(Mutex::new(Vec::new()));
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(OtherKind {
            kind: RuntimeKind::Codex,
            inner: MockRuntime {
                log: Arc::default(),
                out: Arc::default(),
                spawns: spawns.clone(),
            },
        }));
        let manager = WorkspaceManager::new(fake.docker.clone(), fake.dir.path().join("build"));
        let sup = Supervisor::new_with_workspaces(Hub::new(store.clone()), rts, None, manager);
        sup.send(&id, Inbound::user("go")).await.unwrap();

        let cfg = first_spawn(&spawns).await;
        assert_eq!(
            cfg.workspace,
            Some(WorkspaceSpec::Container {
                name: format!("bandito-ws-{}", box_ws.id),
                docker: fake.docker.clone(),
            })
        );
        assert!(
            fake.calls()
                .iter()
                .any(|l| l.starts_with(&format!("run -d --name bandito-ws-{} ", box_ws.id))),
            "the container is created for the fallback too"
        );
    }
}
