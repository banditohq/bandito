//! One actor task per agent: owns the runtime session, queues messages so a
//! single turn runs at a time, applies the approval policy, and turns runtime
//! output into stored events.

use crate::event::{AgentStatus, DecidedBy, Decision, EventBody, Source, TurnStatus};
use crate::hub::Hub;
use crate::policy::{self, Verdict};
use crate::runtime::{ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, Session, SpawnConfig};
use crate::store::{Agent, RuleAction, new_id, now_ms};
use anyhow::{Result, anyhow, bail};
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
}

impl Inbound {
    pub fn user(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            source: Source::User,
            from_agent: None,
        }
    }
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
}

pub struct Supervisor {
    hub: Hub,
    runtimes: Runtimes,
    /// Crew MCP server injected into every session.
    mcp: Option<(PathBuf, Vec<String>)>,
    actors: Mutex<HashMap<String, mpsc::Sender<Cmd>>>,
}

/// Approvals nobody answered are denied after this long.
pub const APPROVAL_TTL_MS: i64 = 24 * 60 * 60 * 1000;

impl Supervisor {
    pub fn new(hub: Hub, runtimes: Runtimes, mcp: Option<(PathBuf, Vec<String>)>) -> Arc<Self> {
        Arc::new(Self {
            hub,
            runtimes,
            mcp,
            actors: Mutex::new(HashMap::new()),
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

    /// Stop the agent's session (on delete, or when its config changed).
    /// The next message starts a fresh session.
    pub async fn stop(&self, agent_id: &str) {
        let tx = self.actors.lock().unwrap_or_else(|e| e.into_inner()).remove(agent_id);
        if let Some(tx) = tx {
            let (reply, rx) = oneshot::channel();
            if tx.send(Cmd::Stop(reply)).await.is_ok() {
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
            Cmd::Stop(_) => unreachable!("handled in run"),
        }
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
        let mut prompt = String::new();
        if !agent.role.trim().is_empty() {
            prompt = format!(
                "You are {}, the {} in a crew of AI agents run by Bandito.",
                agent.name,
                agent.role.trim()
            );
        }
        if let Some(sp) = agent.system_prompt.as_deref().filter(|s| !s.trim().is_empty()) {
            if !prompt.is_empty() {
                prompt.push_str("\n\n");
            }
            prompt.push_str(sp);
        }
        let spawned = rt
            .spawn(SpawnConfig {
                agent_id: agent.id.clone(),
                cwd: PathBuf::from(&agent.cwd),
                model: agent.model.clone(),
                system_prompt: (!prompt.is_empty()).then_some(prompt),
                resume: agent.runtime_session_id.clone(),
                program: None,
                mcp: self.mcp.clone(),
                env: Vec::new(),
            })
            .await?;
        self.session = Some(spawned.session);
        self.output = Some(spawned.output);
        Ok(())
    }

    /// Start the next queued message if no turn is running.
    async fn pump(&mut self) -> Result<()> {
        if self.turn.is_some() {
            return Ok(());
        }
        let Some(msg) = self.queue.pop_front() else {
            return Ok(());
        };
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
                        usage,
                        cost_usd,
                    },
                );
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
        let verdict = policy::evaluate(agent.approval_mode, &req, &agent.cwd, &rules);
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::Event;
    use crate::runtime::{RuntimeStatus, Spawned};
    use crate::store::{ApprovalMode, ApprovalStatus, NewAgent, Store};
    use async_trait::async_trait;
    use std::time::Duration;
    use tokio::sync::broadcast;

    /// What the mock session was asked to do.
    type Log = Arc<Mutex<Vec<String>>>;

    struct MockRuntime {
        log: Log,
        /// The test pushes runtime output through this.
        out: Arc<Mutex<Option<mpsc::Sender<RuntimeOutput>>>>,
        spawns: Arc<Mutex<Vec<SpawnConfig>>>,
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
            *self.out.lock().unwrap() = Some(tx);
            self.spawns.lock().unwrap().push(cfg);
            Ok(Spawned {
                session: Box::new(MockSession { log: self.log.clone() }),
                output: rx,
            })
        }
    }

    struct World {
        sup: Arc<Supervisor>,
        store: Arc<Store>,
        log: Log,
        out: Arc<Mutex<Option<mpsc::Sender<RuntimeOutput>>>>,
        spawns: Arc<Mutex<Vec<SpawnConfig>>>,
        events: broadcast::Receiver<Event>,
        agent: String,
    }

    fn world(mode: ApprovalMode) -> World {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let hub = Hub::new(store.clone());
        let events = hub.subscribe();
        let log: Log = Arc::default();
        let out = Arc::new(Mutex::new(None));
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
        async fn push(&self, o: RuntimeOutput) {
            let tx = self.out.lock().unwrap().clone().expect("session spawned");
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
            })
            .unwrap();
        let err = w.sup.send(&codex.id, Inbound::user("x")).await.unwrap_err();
        assert!(err.to_string().contains("runtime codex is not available"));
    }
}
