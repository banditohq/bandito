//! One actor task per agent: owns the runtime session, queues messages so a
//! single turn runs at a time, applies the approval policy, and turns runtime
//! output into stored events.

use crate::event::{AgentStatus, DecidedBy, Decision, EventBody, Source, TurnStatus, Usage};
use crate::hub::Hub;
use crate::policy::{self, Verdict};
use crate::runtime::{ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, Session, SpawnConfig};
use crate::store::{Agent, DEFAULT_CONTEXT_BUDGET, MemoryMode, RuleAction, new_id, now_ms};
use anyhow::{Result, anyhow, bail};
use chrono::{DateTime, Local, NaiveTime, TimeZone};
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
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
}

impl Inbound {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            source: Source::User,
            from_agent: None,
            hops: 0,
            chain: None,
        }
    }

    pub fn schedule(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            source: Source::Schedule,
            from_agent: None,
            hops: 0,
            chain: None,
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

enum Cmd {
    Send(Inbound, oneshot::Sender<Result<()>>),
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
    Reload(oneshot::Sender<()>),
    /// Checks the per-turn and hop limits and, if they pass, counts one crew
    /// message against the running turn. Done in the actor so the check and the
    /// count are one step.
    ReserveCrewSend(oneshot::Sender<Result<CrewContext>>),
}

pub struct Supervisor {
    hub: Hub,
    runtimes: Runtimes,
    /// Crew MCP server injected into every session.
    mcp: Option<(PathBuf, Vec<String>)>,
    actors: Mutex<HashMap<String, mpsc::Sender<Cmd>>>,
    /// Crew messages accepted so far, per chain id.
    chains: Mutex<HashMap<String, u32>>,
}

/// Approvals nobody answered are denied after this long.
pub const APPROVAL_TTL_MS: i64 = 24 * 60 * 60 * 1000;

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

impl Supervisor {
    pub fn new(hub: Hub, runtimes: Runtimes, mcp: Option<(PathBuf, Vec<String>)>) -> Arc<Self> {
        Arc::new(Self {
            hub,
            runtimes,
            mcp,
            actors: Mutex::new(HashMap::new()),
            chains: Mutex::new(HashMap::new()),
        })
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
            session: None,
            output: None,
            turn: None,
            turn_hops: 0,
            turn_chain: None,
            turn_crew_sends: 0,
            wrap_up: None,
            rotate_due: None,
            reload_after_turn: false,
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
        // Depth and per-turn limits are checked and counted by the sender's actor.
        let ctx = self.call(from_id, Cmd::ReserveCrewSend).await?;
        let chain = ctx.chain.unwrap_or_else(new_id);
        self.reserve_chain_message(&chain)?;
        let msg = Inbound {
            text: text.to_string(),
            source: Source::Crew,
            from_agent: Some(from.name),
            hops: ctx.hops.saturating_add(1),
            chain: Some(chain),
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
    /// resumes it with the new settings. Does nothing for an agent with no actor.
    pub async fn reload(&self, agent_id: &str) {
        let tx = self
            .actors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(agent_id)
            .cloned();
        if let Some(tx) = tx.filter(|tx| !tx.is_closed()) {
            let (reply, rx) = oneshot::channel();
            if tx.send(Cmd::Reload(reply)).await.is_ok() {
                let _ = rx.await;
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
}

struct Actor {
    id: String,
    hub: Hub,
    runtimes: Runtimes,
    mcp: Option<(PathBuf, Vec<String>)>,
    session: Option<Box<dyn Session>>,
    output: Option<mpsc::Receiver<RuntimeOutput>>,
    turn: Option<String>,
    turn_hops: u8,
    turn_chain: Option<String>,
    turn_crew_sends: u8,
    /// Set while the wrap-up turn of a chapter that is closing runs: the reason
    /// the chapter closes ("context" or "new day"). Messages wait in the queue meanwhile.
    wrap_up: Option<&'static str>,
    /// Set after a turn that left the chapter over budget: the chapter closes
    /// when the next message comes ("context"), so nothing runs while the agent is idle.
    rotate_due: Option<&'static str>,
    /// Settings changed while a session was running: close that session once it is idle.
    reload_after_turn: bool,
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
            Cmd::ReserveCrewSend(reply) => {
                let _ = reply.send(self.reserve_crew_send());
            }
            Cmd::Reload(reply) => {
                self.reload_after_turn = true;
                self.release_if_idle().await;
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
        let Some(p) = self.pending.get(approval_id) else {
            bail!("approval {approval_id} is not pending");
        };
        if self.hub.store.approval_resolve(approval_id, decision)?.is_none() {
            self.pending.remove(approval_id);
            bail!("approval {approval_id} was already answered");
        }
        let (key, subject) = (p.key.clone(), p.subject.clone());
        self.pending.remove(approval_id);
        if let Some(s) = &mut self.session {
            s.resolve(&key, decision).await?;
        }
        let remember = remember && decision == Decision::Allow;
        if remember {
            self.hub.store.rule_set(Some(&self.id), &subject, RuleAction::Allow)?;
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
        let rt = self
            .runtimes
            .get(agent.runtime)
            .ok_or_else(|| anyhow!("runtime {} is not available on this server", agent.runtime.as_str()))?;
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
        let spawned = rt
            .spawn(SpawnConfig {
                agent_id: agent.id.clone(),
                cwd: PathBuf::from(&agent.cwd),
                model: agent.model.clone(),
                system_prompt: (!prompt.is_empty()).then_some(prompt),
                resume: agent.runtime_session_id.clone(),
                program: None,
                mcp: self.mcp.clone().map(|(prog, mut args)| {
                    args.extend(["--agent".to_string(), agent.id.clone()]);
                    (prog, args)
                }),
                env: Vec::new(),
                effort: agent.effort,
                extra_dirs: agent.home_dir.iter().map(PathBuf::from).collect(),
            })
            .await?;
        self.session = Some(spawned.session);
        self.output = Some(spawned.output);
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
        // A chapter that outgrew its budget closes now, before the message goes out.
        if let Some(reason) = self.rotate_due.take() {
            if self.session.is_some() {
                if self.begin_rotation(reason).await {
                    return Ok(());
                }
            } else {
                let context_tokens = self
                    .hub
                    .store
                    .agent_get(&self.id)
                    .ok()
                    .flatten()
                    .map_or(0, |a| a.context_tokens);
                self.start_chapter_without_session(reason, context_tokens);
            }
        }
        // A new day opens a new chapter before the message goes out.
        // (If the agent can't be loaded, `ensure_session` reports it below.)
        if let Ok(agent) = self.agent()
            && new_day_due(&agent, Local::now())
        {
            if self.session.is_some() {
                if self.begin_rotation("new day").await {
                    return Ok(());
                }
            } else if agent.runtime_session_id.is_some() || agent.context_tokens > 0 {
                // No session to close, but a stored session id would resume the old chapter.
                self.start_chapter_without_session("new day", agent.context_tokens);
            }
        }
        let Some(msg) = self.queue.pop_front() else {
            return Ok(());
        };
        self.start_turn(msg).await
    }

    /// Start the next chapter when no CLI session is alive to close. The stored
    /// session id is dropped by the store, so the new session cannot resume the old chapter.
    fn start_chapter_without_session(&mut self, reason: &'static str, context_tokens: u64) {
        self.reload_after_turn = false;
        match self.hub.store.agent_next_chapter(&self.id) {
            Ok(chapter) => {
                self.hub.emit(
                    &self.id,
                    EventBody::SessionRotated {
                        chapter,
                        reason: reason.into(),
                        context_tokens,
                    },
                );
            }
            Err(e) => tracing::warn!(agent = self.id, "start next chapter: {e:#}"),
        }
    }

    /// Close the CLI session now unless something is running. A pending chapter
    /// rotation or a running turn leaves `reload_after_turn` set; whoever ends
    /// that work closes the session.
    async fn release_if_idle(&mut self) {
        if self.turn.is_some() || self.wrap_up.is_some() || self.rotate_due.is_some() {
            return;
        }
        self.release_session().await;
    }

    /// Shut the CLI session down and forget it, but keep the chapter: the next
    /// session resumes the same runtime session with the current settings.
    async fn release_session(&mut self) {
        if let Some(s) = self.session.take() {
            s.shutdown().await;
        }
        self.output = None;
        self.reload_after_turn = false;
    }

    /// Close the running chapter before the next message. With a home folder the
    /// agent first gets a wrap-up turn. Returns `true` when that turn is running;
    /// its end then finishes the rotation. Returns `false` when the chapter is
    /// already closed or there was nothing to close.
    async fn begin_rotation(&mut self, reason: &'static str) -> bool {
        if self.session.is_none() {
            return false;
        }
        let has_home = match self.agent() {
            Ok(agent) => agent.home_dir.is_some(),
            Err(e) => {
                tracing::warn!(agent = self.id, "rotation: {e:#}");
                false
            }
        };
        if !has_home {
            self.rotate(reason).await;
            return false;
        }
        self.wrap_up = Some(reason);
        let msg = Inbound {
            text: WRAP_UP.to_string(),
            source: Source::System,
            from_agent: None,
            hops: 0,
            chain: None,
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

    /// Drop the CLI session and start the next chapter. Tells the clients.
    async fn rotate(&mut self, reason: &'static str) {
        let context_tokens = match self.hub.store.agent_get(&self.id) {
            Ok(agent) => agent.map_or(0, |a| a.context_tokens),
            Err(e) => {
                tracing::warn!(agent = self.id, "read context size: {e:#}");
                0
            }
        };
        self.release_session().await;
        match self.hub.store.agent_next_chapter(&self.id) {
            Ok(chapter) => {
                self.hub.emit(
                    &self.id,
                    EventBody::SessionRotated {
                        chapter,
                        reason: reason.to_string(),
                        context_tokens,
                    },
                );
            }
            Err(e) => tracing::error!(agent = self.id, "start next chapter: {e:#}"),
        }
    }

    /// Record a finished turn's context size and time. Without usage the
    /// context size stays as it was. Returns the context size, if it could be recorded.
    fn note_turn(&self, usage: Option<Usage>) -> Option<u64> {
        let store = &self.hub.store;
        let tokens = match usage {
            Some(u) => u.input_tokens.saturating_add(u.output_tokens),
            None => match store.agent_get(&self.id) {
                Ok(agent) => agent.map_or(0, |a| a.context_tokens),
                Err(e) => {
                    tracing::warn!(agent = self.id, "read context size: {e:#}");
                    return None;
                }
            },
        };
        match store.agent_note_turn(&self.id, tokens, now_ms()) {
            Ok(()) => Some(tokens),
            Err(e) => {
                tracing::warn!(agent = self.id, "note turn: {e:#}");
                None
            }
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
        let turn_id = new_id();
        self.turn = Some(turn_id.clone());
        self.turn_hops = msg.hops;
        self.turn_chain = Some(msg.chain.clone().unwrap_or_else(new_id));
        self.turn_crew_sends = 0;
        self.hub.emit(
            &self.id,
            EventBody::TurnStarted {
                turn_id: turn_id.clone(),
                source: msg.source,
            },
        );
        self.hub.emit(
            &self.id,
            EventBody::MessageUser {
                text: msg.text.clone(),
                source: msg.source,
                from_agent: msg.from_agent.clone(),
            },
        );
        self.set_status(AgentStatus::Working, None);
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
                    turn_id,
                    status,
                    usage: None,
                    cost_usd: None,
                },
            );
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
                let turn_id = self.turn.take().unwrap_or_else(new_id);
                self.hub.emit(
                    &self.id,
                    EventBody::TurnCompleted {
                        turn_id,
                        status,
                        usage: usage.clone(),
                        cost_usd,
                    },
                );
                let context = self.note_turn(usage);
                // The wrap-up turn ended, however it ended: close the chapter now.
                if let Some(reason) = self.wrap_up.take() {
                    self.rotate(reason).await;
                    self.after_turn().await;
                    return;
                }
                if let Some(tokens) = context
                    && let Ok(agent) = self.agent()
                    && context_due(&agent, tokens)
                {
                    // Closed lazily: the next message runs the wrap-up first (see `pump`).
                    self.rotate_due = Some("context");
                }
                // A rotation still pending closes the session itself, so only a plain reload happens here.
                if self.reload_after_turn && self.rotate_due.is_none() {
                    self.release_session().await;
                }
                self.after_turn().await;
            }
            RuntimeOutput::Event(body) => {
                self.hub.emit(&self.id, body);
            }
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
                self.session = None;
                // The next session starts with the current settings anyway.
                self.reload_after_turn = false;
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

    async fn approval(&mut self, req: ApprovalRequest) -> Result<()> {
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
                    },
                );
                self.set_status(AgentStatus::NeedsYou, None);
                Ok(())
            }
        }
    }

    /// Store an approval and emit `approval.requested`. Returns its id.
    fn record(&self, req: &ApprovalRequest, reason: &str) -> Result<String> {
        let payload = json!({
            "command": req.command,
            "diff": req.diff,
            "input": req.input,
            "key": req.key,
            "reason": reason,
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
                reason: reason.to_string(),
            },
        );
        Ok(a.id)
    }

    async fn close(&mut self) {
        if let Some(s) = self.session.take() {
            s.shutdown().await;
        }
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
    use crate::store::{AgentPatch, ApprovalMode, ApprovalStatus, Effort, NewAgent, Store};
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
            })
            .unwrap();
        World {
            sup: Supervisor::new(hub, rts, None),
            store,
            log,
            out,
            spawns,
            events,
            agent: agent.id,
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
        } = e.body
        else {
            unreachable!()
        };
        assert_eq!(text, "please review");
        assert_eq!(source, Source::Crew);
        assert_eq!(from_agent.as_deref(), Some("Forge"));
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

        w.sup.reload(&w.agent).await;
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
        w.sup.reload(&w.agent).await;
        w.sup.reload(&w.agent).await;
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
        w.sup.reload(&w.agent).await;
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
        w.sup.reload(&w.agent).await;
        w.sup.reload("nobody").await;
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
}
