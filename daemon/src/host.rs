//! Host load, processes and listening ports of this server (see docs/ARCHITECTURE.md#host).
//!
//! Linux reads `/proc`. macOS runs `sysctl`, `vm_stat`, `netstat`, `ps` and `lsof`.
//! The parsers are pure functions over that text, so tests run them on fixtures
//! on every platform.

use crate::store::now_ms;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
#[cfg(any(target_os = "linux", test))]
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::os::unix::fs::MetadataExt;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// Time between two background samples.
pub const SAMPLE_INTERVAL: Duration = Duration::from_secs(10);
/// 24 h of samples at `SAMPLE_INTERVAL`.
pub const RING_CAPACITY: usize = 8640;
/// Most points one `host.history` reply carries.
pub const MAX_HISTORY_POINTS: usize = 360;
/// Gap between the two readings of the first sample, so CPU and network rates have a base.
const WARMUP: Duration = Duration::from_millis(250);
/// How long a process gets to exit after SIGTERM before SIGKILL.
const GRACE: Duration = Duration::from_secs(3);
/// Longest command line in a reply, in characters.
#[cfg(any(target_os = "linux", target_os = "macos", test))]
const CMD_CHARS: usize = 200;
/// Processes in `host.stats` → `top_processes`: the biggest by memory.
pub const TOP_PROCESSES: usize = 15;
/// Apps in `host.stats` → `app_groups`: the biggest by memory.
pub const APP_GROUPS: usize = 25;
/// Processes listed per app in `host.stats` → `app_groups[].top`: the biggest by memory.
pub const APP_TOP: usize = 3;
/// How long a process gets to exit after SIGTERM from `host.kill_process` before SIGKILL.
pub const OWN_GRACE: Duration = Duration::from_secs(5);
/// How long `host.kill_process` waits for the process to exit before it answers.
pub const OWN_WAIT: Duration = Duration::from_secs(1);

/// One sample of the server.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct HostStats {
    pub os: String,
    pub kernel: String,
    pub arch: String,
    pub hostname: String,
    pub cpus: u32,
    /// Busy share of all CPUs, 0 to 100.
    pub cpu_percent: f32,
    pub load: [f32; 3],
    pub mem_total: u64,
    pub mem_used: u64,
    pub swap_total: u64,
    pub swap_used: u64,
    pub disks: Vec<Disk>,
    pub net_rx_bps: u64,
    pub net_tx_bps: u64,
    /// False where the byte counters cannot be read (macOS without `netstat`).
    pub net_supported: bool,
    pub uptime_s: u64,
    /// The biggest processes of the whole server by memory. Read when `host.stats` answers, not sampled.
    pub top_processes: Vec<TopProcess>,
    /// Every process of the server grouped by app, the biggest `APP_GROUPS` by memory. Read when `host.stats`
    /// answers, not sampled. Empty where the process table cannot be read.
    pub app_groups: Vec<AppGroup>,
}

/// One app in `host.stats` → `app_groups`: all of its processes summed, helpers included.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct AppGroup {
    /// On macOS the outermost `*.app` bundle of the executable without `.app` (helpers belong to their app); else the
    /// executable's file name.
    pub name: String,
    /// Share of one CPU, summed over the app's processes (can exceed 100).
    pub cpu_percent: f32,
    pub memory_bytes: u64,
    pub process_count: u32,
    /// Up to `APP_TOP` of the app's processes, the biggest by memory first, so a group opens without `top_processes`.
    pub top: Vec<AppProcess>,
}

/// One of an app's processes (`host.stats` → `app_groups[].top`).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct AppProcess {
    pub pid: i32,
    /// Short name: the program's file name.
    pub name: String,
    /// Share of one CPU. The first reading after the daemon starts reports 0.
    pub cpu_percent: f32,
    pub memory_bytes: u64,
}

/// One of the biggest processes of the server (`host.stats` → `top_processes`).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct TopProcess {
    pub pid: i32,
    /// Short name: the program's file name.
    pub name: String,
    pub rss_bytes: u64,
    /// Share of one CPU. The first reading after the daemon starts reports 0 (as `processes` does).
    pub cpu_percent: f32,
    /// Runs as the daemon's user.
    pub own: bool,
    /// The app may stop it: it runs as the daemon's user, belongs to no agent, terminal or the daemon, and its
    /// process tree could be read. False when any of that is not known.
    pub own_safe: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Disk {
    pub mount: String,
    pub total: u64,
    pub used: u64,
}

/// One sample kept for the history charts.
#[derive(Debug, Clone, Copy, Serialize, PartialEq)]
pub struct Point {
    pub t: i64,
    pub cpu: f32,
    pub mem_used: u64,
    pub net_rx_bps: u64,
    pub net_tx_bps: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryRange {
    Hour,
    Day,
}

impl HistoryRange {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "1h" => Some(Self::Hour),
            "24h" => Some(Self::Day),
            _ => None,
        }
    }

    fn window_ms(self) -> i64 {
        match self {
            Self::Hour => 3_600_000,
            Self::Day => 86_400_000,
        }
    }
}

/// Who a process belongs to: an agent or a terminal (by its environment), or the daemon itself.
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum OwnerKind {
    Agent,
    Terminal,
    Daemon,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Hash)]
pub struct Owner {
    pub kind: OwnerKind,
    /// Agent or terminal id; `None` for the daemon.
    pub id: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ProcessReport {
    pub supported: bool,
    pub owners: Vec<OwnerGroup>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct OwnerGroup {
    pub owner: Owner,
    /// Share of one CPU, summed over the owner's processes (can exceed 100).
    pub cpu_percent: f32,
    pub rss_bytes: u64,
    pub processes: Vec<ProcessEntry>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ProcessEntry {
    pub pid: i32,
    pub name: String,
    pub cmd: String,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PortReport {
    pub supported: bool,
    pub ports: Vec<PortEntry>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct PortEntry {
    pub port: u16,
    pub addr: String,
    pub pid: Option<i32>,
    pub process: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<Owner>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostError {
    InvalidPid,
    Forbidden(String),
    NotFound,
    Io(String),
}

/// Busy and total CPU time since boot, in clock ticks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct CpuTicks {
    idle: u64,
    total: u64,
}

/// What one reading of the platform gives. Each field is `None` or zero where unavailable.
#[derive(Default)]
struct Raw {
    cpus: u32,
    /// Linux: cumulative CPU ticks, turned into a percentage between two readings.
    cpu_ticks: Option<CpuTicks>,
    /// macOS: busy percentage that `ps` already gives for this moment.
    cpu_direct: Option<f32>,
    load: [f32; 3],
    mem_total: u64,
    mem_used: u64,
    swap_total: u64,
    swap_used: u64,
    disks: Vec<Disk>,
    /// Cumulative bytes (received, sent) without loopback. `None` if unreadable.
    net: Option<(u64, u64)>,
    uptime_s: u64,
}

/// One process of the table the platform reads: what the trees, the lists and the kill checks need.
#[derive(Clone)]
struct ProcRow {
    /// Parent pid (0 for the kernel, 1 for launchd or init).
    ppid: i32,
    /// Short name: the program's file name.
    name: String,
    /// The app the process is grouped under in `app_groups`: see `AppGroup::name`.
    app: String,
    /// The command: its arguments on Linux, the executable's path on macOS. Truncated.
    cmd: String,
    rss_bytes: u64,
    /// Cumulative CPU time in ticks: clock ticks on Linux, hundredths of a second on macOS (see `clk_tck`).
    cpu_ticks: u64,
    /// Runs as the daemon's user.
    own: bool,
}

/// Every process of the server at one moment, by pid.
type Table = HashMap<i32, ProcRow>;

/// Readings from the previous sample, to turn counters into rates.
#[derive(Clone, Copy)]
struct Counters {
    cpu: Option<CpuTicks>,
    net: Option<(u64, u64)>,
    at: Instant,
}

impl Counters {
    fn of(raw: &Raw, at: Instant) -> Self {
        Self {
            cpu: raw.cpu_ticks,
            net: raw.net,
            at,
        }
    }
}

#[derive(Default)]
struct State {
    /// The last `RING_CAPACITY` points, oldest first.
    ring: VecDeque<Point>,
    latest: Option<HostStats>,
    prev: Option<Counters>,
    cpu: CpuState,
}

/// The CPU time of every process at the last reading, and the shares that reading gave.
#[derive(Default)]
struct CpuState {
    ticks: HashMap<i32, u64>,
    at: Option<Instant>,
    shares: HashMap<i32, f32>,
}

/// Readings closer together than this keep the last shares: a share over a few milliseconds is noise.
const MIN_CPU_WINDOW: Duration = Duration::from_secs(1);

/// One reading of the process table, with who owns each process and its CPU share.
struct Procs {
    table: Table,
    classes: HashMap<i32, TreeOwner>,
    /// Share of one CPU since the previous reading. A process seen for the first time has none.
    cpu: HashMap<i32, f32>,
}

/// Keeps the host's samples and answers the questions the app asks.
pub struct Sampler {
    state: Mutex<State>,
}

impl Sampler {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(State::default()),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Take a sample now, keep it in the history and return it. Blocking: call it on the blocking pool.
    pub fn sample_now(&self) -> HostStats {
        let mut prev = self.lock().prev;
        let mut at = Instant::now();
        let mut raw = plat::read_raw();
        if prev.is_none() {
            // Nothing to compare with yet: take a base, wait a moment, read again.
            prev = Some(Counters::of(&raw, at));
            std::thread::sleep(WARMUP);
            at = Instant::now();
            raw = plat::read_raw();
        }
        let dt = prev.map_or(0.0, |p| at.duration_since(p.at).as_secs_f64());
        let busy = match (raw.cpu_direct, prev.and_then(|p| p.cpu), raw.cpu_ticks) {
            (Some(direct), _, _) => direct,
            (None, Some(before), Some(now)) => cpu_percent(before, now),
            _ => 0.0,
        };
        let (net_rx_bps, net_tx_bps) = match (prev.and_then(|p| p.net), raw.net) {
            (Some((rx0, tx0)), Some((rx1, tx1))) => (rate(rx0, rx1, dt), rate(tx0, tx1, dt)),
            _ => (0, 0),
        };
        let ident = identity();
        let now_counters = Counters::of(&raw, at);
        let point = Point {
            t: now_ms(),
            cpu: busy,
            mem_used: raw.mem_used,
            net_rx_bps,
            net_tx_bps,
        };
        let stats = HostStats {
            os: ident.os.clone(),
            kernel: ident.kernel.clone(),
            arch: std::env::consts::ARCH.to_string(),
            hostname: ident.hostname.clone(),
            cpus: raw.cpus,
            cpu_percent: busy,
            load: raw.load,
            mem_total: raw.mem_total,
            mem_used: raw.mem_used,
            swap_total: raw.swap_total,
            swap_used: raw.swap_used,
            disks: raw.disks,
            net_rx_bps,
            net_tx_bps,
            net_supported: raw.net.is_some(),
            uptime_s: raw.uptime_s,
            top_processes: Vec::new(),
            app_groups: Vec::new(),
        };
        let mut st = self.lock();
        st.prev = Some(now_counters);
        if st.ring.len() == RING_CAPACITY {
            st.ring.pop_front();
        }
        st.ring.push_back(point);
        st.latest = Some(stats.clone());
        stats
    }

    /// The last sample, or a fresh one if the daemon has not sampled yet.
    pub fn latest_or_sample(&self) -> HostStats {
        let cached = self.lock().latest.clone();
        cached.unwrap_or_else(|| self.sample_now())
    }

    /// Points of the last hour or day, averaged down to at most `max_points`.
    pub fn history(&self, range: HistoryRange, max_points: usize) -> Vec<Point> {
        let points: Vec<Point> = self.lock().ring.iter().copied().collect();
        select_history(&points, now_ms(), range, max_points)
    }

    /// One reading of the process table: who owns each process, and its CPU share. `None` where the platform
    /// cannot read the table or its owner marks, so nothing is shown or stopped.
    fn procs(&self) -> Option<Procs> {
        let table = plat::read_table()?;
        let markers = plat::read_markers()?;
        let roots = roots();
        let mut classes: HashMap<i32, TreeOwner> = table
            .keys()
            .map(|&pid| (pid, tree_owner(&table, &roots, &markers, pid)))
            .collect();
        classes.insert(self_pid(), TreeOwner::Owned(daemon_owner()));
        let cpu = cpu_shares(&mut self.lock().cpu, &table, Instant::now(), plat::clk_tck());
        Some(Procs { table, classes, cpu })
    }

    /// Processes that belong to an agent, a terminal or the daemon, grouped by owner.
    pub fn processes(&self) -> ProcessReport {
        let Some(procs) = self.procs() else {
            return ProcessReport {
                supported: false,
                owners: Vec::new(),
            };
        };
        let mut groups: HashMap<Owner, OwnerGroup> = HashMap::new();
        for (&pid, row) in &procs.table {
            let Some(TreeOwner::Owned(owner)) = procs.classes.get(&pid) else {
                continue;
            };
            let group = groups.entry(owner.clone()).or_insert_with(|| OwnerGroup {
                owner: owner.clone(),
                cpu_percent: 0.0,
                rss_bytes: 0,
                processes: Vec::new(),
            });
            group.cpu_percent += procs.cpu.get(&pid).copied().unwrap_or(0.0);
            group.rss_bytes += row.rss_bytes;
            group.processes.push(ProcessEntry {
                pid,
                name: row.name.clone(),
                cmd: row.cmd.clone(),
            });
        }
        let mut owners: Vec<OwnerGroup> = groups.into_values().collect();
        for g in &mut owners {
            g.processes.sort_by_key(|p| p.pid);
        }
        owners.sort_by(|a, b| {
            b.cpu_percent
                .total_cmp(&a.cpu_percent)
                .then_with(|| a.owner.id.cmp(&b.owner.id))
        });
        ProcessReport {
            supported: true,
            owners,
        }
    }

    /// The two process lists of `host.stats`, from one reading of the table: `top_processes` (the biggest by memory
    /// and the busiest by CPU, `TOP_PROCESSES` of each, without repeats, biggest memory first) and `app_groups` (all
    /// processes by app). Both are empty where the table cannot be read.
    pub fn process_lists(&self) -> (Vec<TopProcess>, Vec<AppGroup>) {
        let Some(procs) = self.procs() else {
            return (Vec::new(), Vec::new());
        };
        let cpu_of = |pid: i32| procs.cpu.get(&pid).copied().unwrap_or(0.0);
        let rows: Vec<(i32, u64, f32)> = procs
            .table
            .iter()
            .map(|(&pid, row)| (pid, row.rss_bytes, cpu_of(pid)))
            .collect();
        let top = top_pids(&rows, TOP_PROCESSES)
            .into_iter()
            .map(|pid| {
                let row = &procs.table[&pid];
                TopProcess {
                    pid,
                    name: row.name.clone(),
                    rss_bytes: row.rss_bytes,
                    cpu_percent: cpu_of(pid),
                    own: row.own,
                    own_safe: row.own && procs.classes.get(&pid) == Some(&TreeOwner::Free),
                }
            })
            .collect();
        // Processes of an agent, a terminal or the daemon are left out: they are listed under their owner.
        let apps: Vec<AppRow> = procs
            .table
            .iter()
            .filter(|entry| !is_owned(procs.classes.get(entry.0)))
            .map(|(&pid, row)| AppRow {
                pid,
                app: row.app.clone(),
                name: row.name.clone(),
                rss_bytes: row.rss_bytes,
                cpu_percent: cpu_of(pid),
            })
            .collect();
        (top, group_apps(&apps, APP_GROUPS, APP_TOP))
    }

    /// Listening TCP ports, one entry per port and address.
    pub fn ports(&self) -> PortReport {
        let unsupported = PortReport {
            supported: false,
            ports: Vec::new(),
        };
        let Some(procs) = self.procs() else {
            return unsupported;
        };
        let owners: HashMap<i32, Owner> = procs
            .classes
            .iter()
            .filter_map(|(pid, class)| match class {
                TreeOwner::Owned(owner) => Some((*pid, owner.clone())),
                _ => None,
            })
            .collect();
        let Some(mut ports) = plat::listening(&procs.table, &owners) else {
            return unsupported;
        };
        let mut seen = HashSet::new();
        ports.retain(|p| seen.insert((p.port, p.addr.clone())));
        ports.sort_by(|a, b| a.port.cmp(&b.port).then_with(|| a.addr.cmp(&b.addr)));
        PortReport { supported: true, ports }
    }
}

/// Share of one CPU of every process since the last reading kept in `state`. Readings closer together than
/// `MIN_CPU_WINDOW` return the last shares, and the first reading gives none.
fn cpu_shares(state: &mut CpuState, table: &Table, now: Instant, clk_tck: f64) -> HashMap<i32, f32> {
    if let Some(at) = state.at
        && now.duration_since(at) < MIN_CPU_WINDOW
    {
        return state.shares.clone();
    }
    let elapsed = state.at.map(|at| now.duration_since(at));
    let shares: HashMap<i32, f32> = table
        .iter()
        .map(|(&pid, row)| {
            (
                pid,
                cpu_from_ticks(state.ticks.get(&pid).copied(), row.cpu_ticks, elapsed, clk_tck),
            )
        })
        .collect();
    state.ticks = table.iter().map(|(&pid, row)| (pid, row.cpu_ticks)).collect();
    state.at = Some(now);
    state.shares = shares.clone();
    shares
}

/// Who owns a process, from its tree (see `tree_owner`).
#[derive(Debug, Clone, PartialEq, Eq)]
enum TreeOwner {
    /// The nearest of the process and its ancestors that is a root or carries an owner's mark.
    Owned(Owner),
    /// The walk reached init without finding an owner: the process is the daemon user's and belongs to nobody.
    Free,
    /// The tree could not be read to the end: a parent is missing from the table. Such a process is not stopped.
    Unknown,
}

/// Deepest ancestor chain the walk follows. Real trees are far shallower; a longer one is not trusted.
const MAX_TREE_DEPTH: usize = 256;

/// Who owns `pid`. Walks up from the process: the first of itself and its ancestors that is a root (an agent's CLI or
/// a terminal's shell, see `register_root`) or carries an owner's environment mark decides. The environment mark is
/// only a second sign: a system binary such as `zsh` or `sleep` hides its environment from `ps` on macOS, and its
/// children are then owned through the tree.
fn tree_owner(table: &Table, roots: &HashMap<i32, Owner>, markers: &HashMap<i32, Owner>, pid: i32) -> TreeOwner {
    let mut cur = pid;
    for _ in 0..MAX_TREE_DEPTH {
        if let Some(owner) = roots.get(&cur).or_else(|| markers.get(&cur)) {
            return TreeOwner::Owned(owner.clone());
        }
        if cur <= 1 {
            return TreeOwner::Free;
        }
        let Some(row) = table.get(&cur) else {
            return TreeOwner::Unknown;
        };
        if row.ppid == cur {
            return TreeOwner::Unknown;
        }
        cur = row.ppid;
    }
    TreeOwner::Unknown
}

impl Owner {
    /// An agent's process: its CLI, and the children of it.
    pub fn agent(id: &str) -> Self {
        Self {
            kind: OwnerKind::Agent,
            id: Some(id.to_string()),
        }
    }

    /// A terminal's process: its shell, and the children of it.
    pub fn terminal(id: &str) -> Self {
        Self {
            kind: OwnerKind::Terminal,
            id: Some(id.to_string()),
        }
    }
}

/// Pids of agent CLIs and terminal shells, each with its owner: the roots of the process trees. Registered by their
/// owners (see `register_root`), so an owner's processes are told apart even where their environment is hidden.
static ROOTS: Mutex<BTreeMap<i32, Owner>> = Mutex::new(BTreeMap::new());

/// Keeps a root registered. Dropping it removes the root; the owner keeps it as long as its process is its own.
#[must_use = "dropping the guard at once unregisters the root"]
pub struct RootGuard {
    pid: i32,
}

/// Records `pid` as a root of `owner`'s processes. Keep the guard as long as the process belongs to the owner.
pub fn register_root(pid: i32, owner: Owner) -> RootGuard {
    ROOTS.lock().unwrap_or_else(|e| e.into_inner()).insert(pid, owner);
    RootGuard { pid }
}

impl Drop for RootGuard {
    fn drop(&mut self) {
        ROOTS.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.pid);
    }
}

/// The registered roots. The daemon's own process is classified directly (see `Sampler::procs`), and its children
/// belong to nobody here: a child is only the daemon's by being the daemon's process.
fn roots() -> HashMap<i32, Owner> {
    ROOTS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .map(|(pid, owner)| (*pid, owner.clone()))
        .collect()
}

/// The owner marks of the environment of every process, read where the platform gives them: `None` if the platform
/// cannot read them at all.
fn markers() -> Option<HashMap<i32, Owner>> {
    plat::read_markers()
}

/// The pids of the two top lists over `(pid, memory, cpu share)` rows: the `count` biggest by memory and the `count`
/// busiest by CPU, without repeats, biggest memory first. Ties keep the lower pid first.
fn top_pids(rows: &[(i32, u64, f32)], count: usize) -> Vec<i32> {
    let mut by_memory = rows.to_vec();
    by_memory.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let mut by_cpu = rows.to_vec();
    by_cpu.sort_by(|a, b| b.2.total_cmp(&a.2).then(a.0.cmp(&b.0)));
    let mut chosen: Vec<(i32, u64)> = by_memory.iter().take(count).map(|r| (r.0, r.1)).collect();
    for row in by_cpu.iter().take(count) {
        if !chosen.iter().any(|(pid, _)| *pid == row.0) {
            chosen.push((row.0, row.1));
        }
    }
    chosen.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    chosen.into_iter().map(|(pid, _)| pid).collect()
}

/// One process as `group_apps` sees it.
struct AppRow {
    pid: i32,
    app: String,
    name: String,
    rss_bytes: u64,
    cpu_percent: f32,
}

/// Whether a process belongs to an agent, a terminal or the daemon (see `ProcessOwnerRef`).
fn is_owned(class: Option<&TreeOwner>) -> bool {
    matches!(class, Some(TreeOwner::Owned(_)))
}

/// Sums every given process by its app: the `count` apps biggest by memory (ties by name), each with its `top` biggest
/// processes by memory (ties by pid). Every given process is counted, so the sums are exact.
fn group_apps(rows: &[AppRow], count: usize, top: usize) -> Vec<AppGroup> {
    let mut by_app: HashMap<&str, Vec<&AppRow>> = HashMap::new();
    for row in rows {
        by_app.entry(row.app.as_str()).or_default().push(row);
    }
    let mut groups: Vec<AppGroup> = by_app
        .into_iter()
        .map(|(app, mut members)| {
            members.sort_by(|a, b| b.rss_bytes.cmp(&a.rss_bytes).then(a.pid.cmp(&b.pid)));
            AppGroup {
                name: app.to_string(),
                cpu_percent: members.iter().map(|m| m.cpu_percent).sum::<f32>(),
                memory_bytes: members.iter().map(|m| m.rss_bytes).sum(),
                process_count: u32::try_from(members.len()).unwrap_or(u32::MAX),
                top: members
                    .iter()
                    .take(top)
                    .map(|m| AppProcess {
                        pid: m.pid,
                        name: m.name.clone(),
                        cpu_percent: m.cpu_percent,
                        memory_bytes: m.rss_bytes,
                    })
                    .collect(),
            }
        })
        .collect();
    groups.sort_by(|a, b| b.memory_bytes.cmp(&a.memory_bytes).then_with(|| a.name.cmp(&b.name)));
    groups.truncate(count);
    groups
}

/// The app of a macOS executable path: the outermost `*.app` bundle without `.app`, so a helper
/// (`Google Chrome.app/.../Google Chrome Helper (Renderer).app/...`) belongs to its app. `None` without a bundle.
#[cfg(any(target_os = "macos", test))]
fn bundle_app(path: &str) -> Option<String> {
    path.split('/')
        .find_map(|part| part.strip_suffix(".app").filter(|name| !name.is_empty()))
        .map(str::to_string)
}

/// Whether a process of the daemon's user may be stopped from the app, by who owns it. Fail-closed: a tree that
/// cannot be read to the end is refused like an agent's process.
fn stoppable(class: &TreeOwner) -> Result<(), HostError> {
    match class {
        TreeOwner::Free => Ok(()),
        TreeOwner::Owned(_) => Err(HostError::Forbidden(
            "an agent's or terminal's process: stop it from its agent or terminal".into(),
        )),
        TreeOwner::Unknown => Err(HostError::Forbidden("cannot read the process tree: not stopped".into())),
    }
}

/// Sends SIGTERM to a process of the daemon's user that belongs to no agent, terminal or the daemon, and whose tree
/// can be read to the end. Returns the process's start time, which `force_own_after` checks before SIGKILL.
///
/// The checks run in this order, and the start time is read first and again just before the signal:
/// a pid that another process takes meanwhile has another start time, and is refused. What stays open is the
/// time between the second reading and `kill(2)`: a few microseconds in which the process must exit and its pid
/// be reused. macOS has no pidfd to close that, and Linux is not given one here.
pub fn terminate_own(pid: i32) -> Result<String, HostError> {
    if pid <= 0 {
        return Err(HostError::InvalidPid);
    }
    if pid == 1 {
        return Err(HostError::Forbidden("pid 1 is the system's".into()));
    }
    if pid == self_pid() {
        return Err(HostError::Forbidden("the daemon itself".into()));
    }
    let start = plat::start_time(pid).ok_or(HostError::NotFound)?;
    let table = plat::read_table().ok_or_else(|| HostError::Forbidden("cannot read the process table".into()))?;
    let row = table.get(&pid).ok_or(HostError::NotFound)?;
    if !row.own {
        return Err(HostError::Forbidden("another user's process".into()));
    }
    let marks = markers().ok_or_else(|| HostError::Forbidden("cannot read the process owners".into()))?;
    stoppable(&tree_owner(&table, &roots(), &marks, pid))?;
    if plat::start_time(pid).as_deref() != Some(start.as_str()) {
        return Err(HostError::NotFound);
    }
    // SAFETY: pid is positive and was checked above; SIGTERM only asks the process to end.
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        let err = std::io::Error::last_os_error();
        return Err(if err.raw_os_error() == Some(libc::ESRCH) {
            HostError::NotFound
        } else {
            HostError::Io(err.to_string())
        });
    }
    Ok(start)
}

/// Whether `pid` is gone (exited or a zombie) within `wait`.
pub fn wait_gone(pid: i32, wait: Duration) -> bool {
    let deadline = Instant::now() + wait;
    while alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    true
}

/// After `grace`, SIGKILL the process if it is still there with the start time `terminate_own` read.
/// A pid that another process has taken since is left alone.
pub async fn force_own_after(pid: i32, start: String, grace: Duration) {
    tokio::time::sleep(grace).await;
    let _ = tokio::task::spawn_blocking(move || {
        if plat::start_time(pid).as_deref() == Some(start.as_str()) && alive(pid) {
            // SAFETY: pid is positive; its start time was just checked, so it is the same process.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    })
    .await;
}

/// Stats that do not change while the daemon runs.
struct Identity {
    os: String,
    kernel: String,
    hostname: String,
}

fn identity() -> &'static Identity {
    static IDENTITY: OnceLock<Identity> = OnceLock::new();
    IDENTITY.get_or_init(|| {
        let (os, kernel) = plat::os_and_kernel();
        Identity {
            os,
            kernel,
            hostname: hostname(),
        }
    })
}

fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: `buf` is valid for `buf.len()` bytes; on success gethostname writes a NUL-terminated name.
    if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } != 0 {
        return "server".into();
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).into_owned()
}

/// Busy share of all CPUs between two readings, 0 to 100.
fn cpu_percent(prev: CpuTicks, cur: CpuTicks) -> f32 {
    let total = cur.total.saturating_sub(prev.total);
    if total == 0 {
        return 0.0;
    }
    let idle = cur.idle.saturating_sub(prev.idle);
    (100.0 * (1.0 - idle as f64 / total as f64)).clamp(0.0, 100.0) as f32
}

/// Bytes per second between two cumulative counters. A counter that went back gives 0.
fn rate(prev: u64, cur: u64, secs: f64) -> u64 {
    if cur < prev || secs <= 0.0 {
        return 0;
    }
    ((cur - prev) as f64 / secs).round() as u64
}

/// A process's CPU share of one core between two readings of its ticks.
fn cpu_from_ticks(prev: Option<u64>, cur: u64, elapsed: Option<Duration>, clk_tck: f64) -> f32 {
    match (prev, elapsed) {
        (Some(prev), Some(elapsed)) if elapsed > Duration::ZERO && clk_tck > 0.0 => {
            let cpu_secs = cur.saturating_sub(prev) as f64 / clk_tck;
            (100.0 * cpu_secs / elapsed.as_secs_f64()) as f32
        }
        _ => 0.0,
    }
}

/// Points inside the window of `range` ending at `now`, averaged down to `max`.
fn select_history(points: &[Point], now: i64, range: HistoryRange, max: usize) -> Vec<Point> {
    let from = now - range.window_ms();
    let inside: Vec<Point> = points.iter().filter(|p| p.t >= from).copied().collect();
    downsample(&inside, max)
}

/// Averages runs of neighbouring points so that at most `max` remain.
fn downsample(points: &[Point], max: usize) -> Vec<Point> {
    if max == 0 {
        return Vec::new();
    }
    if points.len() <= max {
        return points.to_vec();
    }
    let size = points.len().div_ceil(max);
    points.chunks(size).map(average).collect()
}

fn average(chunk: &[Point]) -> Point {
    let n = chunk.len() as f64;
    let mut t = 0.0;
    let mut cpu = 0.0;
    let mut mem = 0.0;
    let mut rx = 0.0;
    let mut tx = 0.0;
    for p in chunk {
        t += p.t as f64;
        cpu += p.cpu as f64;
        mem += p.mem_used as f64;
        rx += p.net_rx_bps as f64;
        tx += p.net_tx_bps as f64;
    }
    Point {
        t: (t / n).round() as i64,
        cpu: (cpu / n) as f32,
        mem_used: (mem / n).round() as u64,
        net_rx_bps: (rx / n).round() as u64,
        net_tx_bps: (tx / n).round() as u64,
    }
}

/// The owner named by `BANDITO_AGENT_ID=` or `BANDITO_TERM_ID=` in `KEY=VALUE` items.
/// An agent wins when both are present.
#[cfg(any(target_os = "linux", target_os = "macos", test))]
fn owner_from_pairs<'a>(items: impl IntoIterator<Item = &'a str>) -> Option<Owner> {
    let mut agent: Option<&str> = None;
    let mut terminal: Option<&str> = None;
    for item in items {
        if let Some(id) = item.strip_prefix("BANDITO_AGENT_ID=").filter(|v| !v.is_empty()) {
            if agent.is_none() {
                agent = Some(id);
            }
        } else if let Some(id) = item.strip_prefix("BANDITO_TERM_ID=").filter(|v| !v.is_empty())
            && terminal.is_none()
        {
            terminal = Some(id);
        }
    }
    match (agent, terminal) {
        (Some(id), _) => Some(Owner {
            kind: OwnerKind::Agent,
            id: Some(id.to_string()),
        }),
        (None, Some(id)) => Some(Owner {
            kind: OwnerKind::Terminal,
            id: Some(id.to_string()),
        }),
        (None, None) => None,
    }
}

/// `/proc/<pid>/environ`: NUL-separated `KEY=VALUE` items.
#[cfg(any(target_os = "linux", test))]
fn owner_from_environ(environ: &[u8]) -> Option<Owner> {
    owner_from_pairs(environ.split(|b| *b == 0).filter_map(|v| std::str::from_utf8(v).ok()))
}

/// Cuts `s` to `max` characters, the last one being `…` when it is cut.
#[cfg(any(target_os = "linux", target_os = "macos", test))]
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    s.chars()
        .take(max.saturating_sub(1))
        .chain(std::iter::once('…'))
        .collect()
}

/// Load averages from the text `"0.52 0.58 0.59 …"`.
#[cfg(any(target_os = "linux", target_os = "macos", test))]
fn parse_loadavg(s: &str) -> [f32; 3] {
    let mut out = [0.0; 3];
    for (slot, field) in out.iter_mut().zip(s.split_whitespace()) {
        *slot = field.parse().unwrap_or(0.0);
    }
    out
}

/// Aggregate `cpu` line of /proc/stat, and how many per-CPU lines there are.
#[cfg(any(target_os = "linux", test))]
fn parse_proc_stat(s: &str) -> (Option<CpuTicks>, u32) {
    let mut ticks = None;
    let mut cpus = 0;
    for line in s.lines() {
        let mut parts = line.split_whitespace();
        let Some(name) = parts.next() else { continue };
        if name == "cpu" {
            // user nice system idle iowait irq softirq steal (guest is already in user).
            let f: Vec<u64> = parts.filter_map(|x| x.parse().ok()).take(8).collect();
            if f.len() >= 4 {
                ticks = Some(CpuTicks {
                    idle: f[3] + f.get(4).copied().unwrap_or(0),
                    total: f.iter().sum(),
                });
            }
        } else if name
            .strip_prefix("cpu")
            .is_some_and(|n| n.bytes().all(|b| b.is_ascii_digit()) && !n.is_empty())
        {
            cpus += 1;
        }
    }
    (ticks, cpus)
}

#[cfg(any(target_os = "linux", test))]
fn parse_uptime(s: &str) -> u64 {
    s.split_whitespace()
        .next()
        .and_then(|v| v.parse::<f64>().ok())
        .map_or(0, |v| v as u64)
}

#[cfg(any(target_os = "linux", test))]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct MemInfo {
    total: u64,
    used: u64,
    swap_total: u64,
    swap_used: u64,
}

/// /proc/meminfo in bytes. Used memory is total minus available, as `free` shows it.
#[cfg(any(target_os = "linux", test))]
fn parse_meminfo(s: &str) -> MemInfo {
    let mut kb: HashMap<&str, u64> = HashMap::new();
    for line in s.lines() {
        if let Some((key, value)) = line.split_once(':')
            && let Some(n) = value.split_whitespace().next().and_then(|n| n.parse::<u64>().ok())
        {
            kb.insert(key.trim(), n * 1024);
        }
    }
    let get = |key: &str| kb.get(key).copied().unwrap_or(0);
    let total = get("MemTotal");
    let available = get("MemAvailable");
    let swap_total = get("SwapTotal");
    let swap_free = get("SwapFree");
    MemInfo {
        total,
        used: total.saturating_sub(available),
        swap_total,
        swap_used: swap_total.saturating_sub(swap_free),
    }
}

/// Cumulative (received, sent) bytes over all interfaces except loopback, from /proc/net/dev.
#[cfg(any(target_os = "linux", test))]
fn parse_net_dev(s: &str) -> (u64, u64) {
    let (mut rx, mut tx) = (0u64, 0u64);
    for line in s.lines() {
        let Some((name, rest)) = line.split_once(':') else {
            continue;
        };
        if name.trim() == "lo" {
            continue;
        }
        let f: Vec<u64> = rest.split_whitespace().filter_map(|x| x.parse().ok()).collect();
        // Receive bytes is the first column, transmit bytes the ninth.
        if f.len() >= 9 {
            rx = rx.saturating_add(f[0]);
            tx = tx.saturating_add(f[8]);
        }
    }
    (rx, tx)
}

#[cfg(any(target_os = "linux", test))]
fn parse_os_release(s: &str) -> Option<String> {
    s.lines()
        .find_map(|l| l.strip_prefix("PRETTY_NAME="))
        .map(|v| v.trim().trim_matches('"').to_string())
        .filter(|v| !v.is_empty())
}

/// A socket in LISTEN state from /proc/net/tcp or tcp6.
#[cfg(any(target_os = "linux", test))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct Listen {
    addr: IpAddr,
    port: u16,
    inode: u64,
}

#[cfg(any(target_os = "linux", test))]
fn parse_proc_net_tcp(s: &str, v6: bool) -> Vec<Listen> {
    s.lines()
        .skip(1)
        .filter_map(|line| {
            // Columns: sl, local address, remote address, st (0A = LISTEN), …, inode (index 9).
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 10 || f[3] != "0A" {
                return None;
            }
            let (ip, port) = f[1].split_once(':')?;
            let addr = if v6 {
                IpAddr::V6(parse_ipv6_hex(ip)?)
            } else {
                IpAddr::V4(parse_ipv4_hex(ip)?)
            };
            Some(Listen {
                addr,
                port: u16::from_str_radix(port, 16).ok()?,
                inode: f[9].parse().ok()?,
            })
        })
        .collect()
}

/// /proc prints each address word as the raw 32 bits in native order.
#[cfg(any(target_os = "linux", test))]
fn parse_ipv4_hex(s: &str) -> Option<Ipv4Addr> {
    let word = u32::from_str_radix(s, 16).ok()?;
    Some(Ipv4Addr::from(word.to_ne_bytes()))
}

#[cfg(any(target_os = "linux", test))]
fn parse_ipv6_hex(s: &str) -> Option<Ipv6Addr> {
    if s.len() != 32 || !s.is_ascii() {
        return None;
    }
    let mut bytes = [0u8; 16];
    for (i, chunk) in bytes.chunks_mut(4).enumerate() {
        let word = u32::from_str_radix(&s[i * 8..i * 8 + 8], 16).ok()?;
        chunk.copy_from_slice(&word.to_ne_bytes());
    }
    Some(Ipv6Addr::from(bytes))
}

/// The fields of /proc/<pid>/stat that the daemon uses.
#[cfg(any(target_os = "linux", test))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct PidStat {
    name: String,
    state: char,
    /// Parent pid.
    ppid: i32,
    /// utime + stime, in clock ticks.
    ticks: u64,
    rss_pages: u64,
    /// Start time since boot, in clock ticks: with the pid it tells one process from a later one with the same pid.
    start: u64,
}

#[cfg(any(target_os = "linux", test))]
fn parse_pid_stat(s: &str) -> Option<PidStat> {
    // The name is in parentheses and may hold spaces or parentheses itself.
    let open = s.find('(')?;
    let close = s.rfind(')')?;
    let name = s.get(open + 1..close)?.to_string();
    let f: Vec<&str> = s.get(close + 1..)?.split_whitespace().collect();
    // f[0] is field 3 (state). utime is field 14, stime 15, starttime 22, rss 24 (proc(5)).
    let state = f.first()?.chars().next()?;
    let num = |i: usize| f.get(i).and_then(|v| v.parse::<u64>().ok());
    Some(PidStat {
        name,
        state,
        ppid: f.get(1)?.parse().ok()?,
        ticks: num(11)? + num(12)?,
        rss_pages: num(21)?,
        start: num(19)?,
    })
}

/// One line of `ps -axww -o pid=,ppid=,rss=,uid=,time=,comm=` (macOS).
#[cfg(any(target_os = "macos", test))]
#[derive(Debug, Clone, PartialEq)]
struct TableLine {
    pid: i32,
    ppid: i32,
    rss_bytes: u64,
    uid: u32,
    cpu_ticks: u64,
    name: String,
    app: String,
    cmd: String,
}

#[cfg(any(target_os = "macos", test))]
fn parse_table_line(line: &str) -> Option<TableLine> {
    let (pid, rest) = take_field(line)?;
    let (ppid, rest) = take_field(rest)?;
    let (rss, rest) = take_field(rest)?;
    let (uid, rest) = take_field(rest)?;
    let (time, rest) = take_field(rest)?;
    // The command is the executable's path, which may hold spaces: its file name is the short name.
    let cmd = rest.trim();
    if cmd.is_empty() {
        return None;
    }
    let name = cmd.rsplit('/').next().unwrap_or_default().to_string();
    Some(TableLine {
        pid: pid.parse().ok()?,
        ppid: ppid.parse().ok()?,
        rss_bytes: rss.parse::<u64>().ok()? * 1024,
        uid: uid.parse().ok()?,
        cpu_ticks: parse_cpu_time(time)?,
        // The app is read from the whole path: `cmd` is cut to CMD_CHARS below.
        app: bundle_app(cmd).unwrap_or_else(|| name.clone()),
        name,
        cmd: truncate_chars(cmd, CMD_CHARS),
    })
}

/// Cumulative CPU time as `ps` prints it, `[[dd-]hh:]mm:ss.ss`, in hundredths of a second.
#[cfg(any(target_os = "macos", test))]
fn parse_cpu_time(text: &str) -> Option<u64> {
    let (days, clock) = match text.split_once('-') {
        Some((d, rest)) => (d.parse::<u64>().ok()?, rest),
        None => (0, text),
    };
    let parts: Vec<&str> = clock.split(':').collect();
    let (hours, minutes, seconds) = match parts.as_slice() {
        [m, s] => (0, m.parse::<u64>().ok()?, s.parse::<f64>().ok()?),
        [h, m, s] => (h.parse::<u64>().ok()?, m.parse::<u64>().ok()?, s.parse::<f64>().ok()?),
        _ => return None,
    };
    let whole_minutes = (days * 24 + hours) * 60 + minutes;
    Some(whole_minutes * 6000 + (seconds * 100.0).round() as u64)
}

/// One line of `ps -axww -E -o pid=,command=` (macOS): the owner marks shown in the environment after the command.
#[cfg(any(target_os = "macos", test))]
fn parse_marker_line(line: &str) -> Option<(i32, Owner)> {
    let (pid, rest) = take_field(line)?;
    let owner = owner_from_pairs(rest.split_whitespace())?;
    Some((pid.parse().ok()?, owner))
}

/// The first whitespace-separated word and the text after it.
#[cfg(any(target_os = "macos", test))]
fn take_field(s: &str) -> Option<(&str, &str)> {
    let s = s.trim_start();
    let end = s.find(char::is_whitespace).unwrap_or(s.len());
    if end == 0 {
        return None;
    }
    Some((&s[..end], &s[end..]))
}

/// One listening socket from `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`.
#[cfg(any(target_os = "macos", test))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct LsofListen {
    pid: i32,
    process: String,
    addr: String,
    port: u16,
}

#[cfg(any(target_os = "macos", test))]
fn parse_lsof(out: &str) -> Vec<LsofListen> {
    let mut pid: Option<i32> = None;
    let mut process = String::new();
    let mut found = Vec::new();
    for line in out.lines() {
        let val = line.get(1..).unwrap_or_default();
        match line.as_bytes().first().copied() {
            Some(b'p') => pid = val.parse().ok(),
            Some(b'c') => process = val.to_string(),
            Some(b'n') => {
                // Drop anything after the address, such as " (LISTEN)".
                let name = val.split(' ').next().unwrap_or_default();
                if let (Some(pid), Some((addr, port))) = (pid, split_host_port(name)) {
                    found.push(LsofListen {
                        pid,
                        process: process.clone(),
                        addr,
                        port,
                    });
                }
            }
            _ => {}
        }
    }
    found
}

/// `1.2.3.4:80`, `*:5173` or `[::1]:8080`.
#[cfg(any(target_os = "macos", test))]
fn split_host_port(s: &str) -> Option<(String, u16)> {
    let (host, port) = s.rsplit_once(':')?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    Some((host.to_string(), port.parse().ok()?))
}

/// Bytes in use: active, wired and compressed pages, from `vm_stat`.
#[cfg(any(target_os = "macos", test))]
fn parse_vm_stat(s: &str) -> Option<u64> {
    let page = s.lines().find_map(|l| {
        let rest = l.split_once("page size of ")?.1;
        rest.split_whitespace().next()?.parse::<u64>().ok()
    })?;
    let pages = |label: &str| -> u64 {
        s.lines()
            .find_map(|l| l.strip_prefix(label))
            .and_then(|v| v.trim().trim_end_matches('.').parse().ok())
            .unwrap_or(0)
    };
    let used = pages("Pages active:") + pages("Pages wired down:") + pages("Pages occupied by compressor:");
    Some(used * page)
}

/// Cumulative (received, sent) bytes from `netstat -ib`, counting the link rows of non-loopback interfaces.
#[cfg(any(target_os = "macos", test))]
fn parse_netstat_ib(s: &str) -> Option<(u64, u64)> {
    let (mut rx, mut tx) = (0u64, 0u64);
    let mut seen = false;
    for line in s.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 5 || !f.iter().any(|w| w.starts_with("<Link#")) || f[0].starts_with("lo") {
            continue;
        }
        // The address column may be empty, so the byte columns are counted from the end.
        let (Ok(i), Ok(o)) = (f[f.len() - 5].parse::<u64>(), f[f.len() - 2].parse::<u64>()) else {
            continue;
        };
        rx = rx.saturating_add(i);
        tx = tx.saturating_add(o);
        seen = true;
    }
    seen.then_some((rx, tx))
}

/// `sysctl -n vm.loadavg` prints `{ 1.23 1.10 0.98 }`.
#[cfg(any(target_os = "macos", test))]
fn parse_sysctl_loadavg(s: &str) -> [f32; 3] {
    let inner = s.trim().trim_start_matches('{').trim_end_matches('}');
    parse_loadavg(inner)
}

/// Unix seconds from `sysctl -n kern.boottime`: `{ sec = 1728475200, usec = 0 } …`.
#[cfg(any(target_os = "macos", test))]
fn parse_boottime(s: &str) -> Option<i64> {
    let rest = s.split_once("sec = ")?.1;
    rest.split(|c: char| !c.is_ascii_digit()).next()?.parse().ok()
}

/// Platform readers. Each module provides the same functions: `read_raw`, `os_and_kernel`,
/// `clk_tck`, `is_zombie`, `scan_all`, `process_owner`, `listening`.
#[cfg(target_os = "linux")]
mod plat {
    use super::*;
    use std::fs;

    fn read(path: &str) -> String {
        fs::read_to_string(path).unwrap_or_default()
    }

    pub(super) fn read_raw() -> Raw {
        let (ticks, cpus) = parse_proc_stat(&read("/proc/stat"));
        let mem = parse_meminfo(&read("/proc/meminfo"));
        let dev = read("/proc/net/dev");
        Raw {
            cpus: if cpus == 0 {
                std::thread::available_parallelism().map_or(1, |n| n.get() as u32)
            } else {
                cpus
            },
            cpu_ticks: ticks,
            cpu_direct: None,
            load: parse_loadavg(&read("/proc/loadavg")),
            mem_total: mem.total,
            mem_used: mem.used,
            swap_total: mem.swap_total,
            swap_used: mem.swap_used,
            disks: disks(),
            net: (!dev.is_empty()).then(|| parse_net_dev(&dev)),
            uptime_s: parse_uptime(&read("/proc/uptime")),
        }
    }

    pub(super) fn os_and_kernel() -> (String, String) {
        let os = parse_os_release(&read("/etc/os-release")).unwrap_or_else(|| "Linux".into());
        (os, read("/proc/sys/kernel/osrelease").trim().to_string())
    }

    pub(super) fn clk_tck() -> f64 {
        // SAFETY: sysconf has no preconditions.
        let v = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        if v > 0 { v as f64 } else { 100.0 }
    }

    fn page_size() -> u64 {
        // SAFETY: sysconf has no preconditions.
        let v = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        if v > 0 { v as u64 } else { 4096 }
    }

    pub(super) fn is_zombie(pid: i32) -> bool {
        parse_pid_stat(&read(&format!("/proc/{pid}/stat"))).is_some_and(|s| s.state == 'Z')
    }

    fn pids() -> Option<Vec<i32>> {
        let dirs = fs::read_dir("/proc").ok()?;
        Some(
            dirs.flatten()
                .filter_map(|e| e.file_name().to_str().and_then(|s| s.parse().ok()))
                .collect(),
        )
    }

    fn my_uid() -> u32 {
        // SAFETY: getuid has no preconditions.
        unsafe { libc::getuid() }
    }

    /// Every process whose `/proc` entry can be read. A process that exits while the table is read is skipped.
    pub(super) fn read_table() -> Option<Table> {
        let me = my_uid();
        let mut table = Table::new();
        for pid in pids()? {
            let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
                continue;
            };
            let Some(st) = parse_pid_stat(&stat) else { continue };
            let cmdline = fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
            let args: Vec<String> = cmdline
                .split(|b| *b == 0)
                .filter(|a| !a.is_empty())
                .map(|a| String::from_utf8_lossy(a).into_owned())
                .collect();
            let cmd = if args.is_empty() {
                format!("[{}]", st.name)
            } else {
                truncate_chars(&args.join(" "), CMD_CHARS)
            };
            let own = fs::metadata(format!("/proc/{pid}")).is_ok_and(|m| m.uid() == me);
            table.insert(
                pid,
                ProcRow {
                    ppid: st.ppid,
                    app: st.name.clone(),
                    name: st.name,
                    cmd,
                    rss_bytes: st.rss_pages * page_size(),
                    cpu_ticks: st.ticks,
                    own,
                },
            );
        }
        Some(table)
    }

    /// The owner marks in the environment of every process whose environment can be read.
    pub(super) fn read_markers() -> Option<HashMap<i32, Owner>> {
        let mut marks = HashMap::new();
        for pid in pids()? {
            let owner = fs::read(format!("/proc/{pid}/environ"))
                .ok()
                .and_then(|env| owner_from_environ(&env));
            if let Some(owner) = owner {
                marks.insert(pid, owner);
            }
        }
        Some(marks)
    }

    /// The process's start time: the same pid with another start time is another process.
    pub(super) fn start_time(pid: i32) -> Option<String> {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        parse_pid_stat(&stat).map(|st| st.start.to_string())
    }

    /// The address as people write it: IPv4-mapped IPv6 shows as IPv4.
    fn display_addr(ip: IpAddr) -> String {
        match ip {
            IpAddr::V4(v4) => v4.to_string(),
            IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or_else(|| v6.to_string(), |v4| v4.to_string()),
        }
    }

    /// Socket inode → pid, for the inodes given. Only processes we can read show up.
    fn socket_owners(inodes: &HashSet<u64>) -> HashMap<u64, i32> {
        let mut found = HashMap::new();
        for pid in pids().unwrap_or_default() {
            let Ok(fds) = fs::read_dir(format!("/proc/{pid}/fd")) else {
                continue;
            };
            for fd in fds.flatten() {
                let Ok(target) = fs::read_link(fd.path()) else { continue };
                let inode = target
                    .to_str()
                    .and_then(|t| t.strip_prefix("socket:["))
                    .and_then(|t| t.strip_suffix(']'))
                    .and_then(|n| n.parse::<u64>().ok());
                if let Some(inode) = inode.filter(|i| inodes.contains(i)) {
                    found.entry(inode).or_insert(pid);
                }
            }
        }
        found
    }

    pub(super) fn listening(table: &Table, owners: &HashMap<i32, Owner>) -> Option<Vec<PortEntry>> {
        let mut listens = parse_proc_net_tcp(&read("/proc/net/tcp"), false);
        listens.extend(parse_proc_net_tcp(&read("/proc/net/tcp6"), true));
        let inodes: HashSet<u64> = listens.iter().map(|l| l.inode).collect();
        let by_inode = socket_owners(&inodes);
        Some(
            listens
                .into_iter()
                .map(|l| {
                    let pid = by_inode.get(&l.inode).copied();
                    PortEntry {
                        port: l.port,
                        addr: display_addr(l.addr),
                        pid,
                        process: pid.and_then(|p| table.get(&p)).map(|row| row.name.clone()),
                        owner: pid.and_then(|p| owners.get(&p).cloned()),
                    }
                })
                .collect(),
        )
    }
}

#[cfg(target_os = "macos")]
mod plat {
    use super::*;
    use std::process::Command;

    /// `LC_ALL=C` keeps numbers in the C form (`0.5`): ps prints `0,5` under a comma locale.
    fn command(program: &str, args: &[&str]) -> Command {
        let mut cmd = Command::new(program);
        cmd.args(args).env("LC_ALL", "C");
        cmd
    }

    /// Standard output of a command that succeeded.
    fn run(program: &str, args: &[&str]) -> Option<String> {
        let out = command(program, args).output().ok()?;
        out.status
            .success()
            .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
    }

    /// Standard output of a command, whatever its exit status (lsof exits 1 when nothing matches).
    fn run_any(program: &str, args: &[&str]) -> Option<String> {
        let out = command(program, args).output().ok()?;
        Some(String::from_utf8_lossy(&out.stdout).into_owned())
    }

    fn sysctl(name: &str) -> Option<String> {
        run("sysctl", &["-n", name]).map(|s| s.trim().to_string())
    }

    pub(super) fn read_raw() -> Raw {
        let cpus: u32 = sysctl("hw.ncpu").and_then(|v| v.parse().ok()).unwrap_or(1).max(1);
        // ps gives percent of one CPU per process: sum them and divide by the CPU count.
        let cpu_direct = run("ps", &["-A", "-o", "%cpu="]).map(|out| {
            let sum: f32 = out.lines().filter_map(|l| l.trim().parse::<f32>().ok()).sum();
            sum / cpus as f32
        });
        let mem_total: u64 = sysctl("hw.memsize").and_then(|v| v.parse().ok()).unwrap_or(0);
        let uptime_s = sysctl("kern.boottime")
            .and_then(|s| parse_boottime(&s))
            .map_or(0, |boot| (now_ms() / 1000 - boot).max(0) as u64);
        Raw {
            cpus,
            cpu_ticks: None,
            cpu_direct,
            load: sysctl("vm.loadavg")
                .map(|s| parse_sysctl_loadavg(&s))
                .unwrap_or_default(),
            mem_total,
            mem_used: run("vm_stat", &[]).and_then(|s| parse_vm_stat(&s)).unwrap_or(0),
            swap_total: 0,
            swap_used: 0,
            disks: disks(),
            net: run("netstat", &["-ib"]).and_then(|s| parse_netstat_ib(&s)),
            uptime_s,
        }
    }

    pub(super) fn os_and_kernel() -> (String, String) {
        let os = sysctl("kern.osproductversion").map_or_else(|| "macOS".into(), |v| format!("macOS {v}"));
        (os, sysctl("kern.osrelease").unwrap_or_default())
    }

    pub(super) fn clk_tck() -> f64 {
        // `ps` gives CPU time to the hundredth of a second, the ticks of `ProcRow::cpu_ticks`.
        100.0
    }

    /// Whether the process has exited and waits to be reaped: its state starts with `Z`.
    pub(super) fn is_zombie(pid: i32) -> bool {
        run("ps", &["-o", "stat=", "-p", &pid.to_string()]).is_some_and(|stat| stat.trim_start().starts_with('Z'))
    }

    fn my_uid() -> u32 {
        // SAFETY: getuid has no preconditions.
        unsafe { libc::getuid() }
    }

    /// Every process, from one `ps` call: parent, memory, owner, CPU time and the executable's path.
    pub(super) fn read_table() -> Option<Table> {
        let out = run("ps", &["-axww", "-o", "pid=,ppid=,rss=,uid=,time=,comm="])?;
        let me = my_uid();
        Some(
            out.lines()
                .filter_map(parse_table_line)
                .map(|line| {
                    let own = line.uid == me;
                    (
                        line.pid,
                        ProcRow {
                            ppid: line.ppid,
                            name: line.name,
                            app: line.app,
                            cmd: line.cmd,
                            rss_bytes: line.rss_bytes,
                            cpu_ticks: line.cpu_ticks,
                            own,
                        },
                    )
                })
                .collect(),
        )
    }

    /// The owner marks of the environments `ps` shows. Apple's own programs show none, which is why the tree counts.
    pub(super) fn read_markers() -> Option<HashMap<i32, Owner>> {
        let out = run("ps", &["-axww", "-E", "-o", "pid=,command="])?;
        Some(out.lines().filter_map(parse_marker_line).collect())
    }

    /// The process's start time as `ps` prints it. A pid reused by another process starts later.
    pub(super) fn start_time(pid: i32) -> Option<String> {
        let start = run("ps", &["-o", "lstart=", "-p", &pid.to_string()])?;
        let start = start.trim();
        (!start.is_empty()).then(|| start.to_string())
    }

    pub(super) fn listening(table: &Table, owners: &HashMap<i32, Owner>) -> Option<Vec<PortEntry>> {
        let out = run_any("lsof", &["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])?;
        Some(
            parse_lsof(&out)
                .into_iter()
                .map(|l| PortEntry {
                    port: l.port,
                    addr: l.addr,
                    pid: Some(l.pid),
                    process: table.get(&l.pid).map(|row| row.name.clone()).or(Some(l.process)),
                    owner: owners.get(&l.pid).cloned(),
                })
                .collect(),
        )
    }
}

/// Platforms without a reader: the sample has CPUs and disks only.
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod plat {
    use super::*;

    pub(super) fn read_table() -> Option<Table> {
        None
    }

    pub(super) fn read_markers() -> Option<HashMap<i32, Owner>> {
        None
    }

    pub(super) fn start_time(_pid: i32) -> Option<String> {
        None
    }

    pub(super) fn read_raw() -> Raw {
        Raw {
            cpus: std::thread::available_parallelism().map_or(1, |n| n.get() as u32),
            disks: disks(),
            ..Raw::default()
        }
    }

    pub(super) fn os_and_kernel() -> (String, String) {
        (std::env::consts::OS.to_string(), String::new())
    }

    pub(super) fn clk_tck() -> f64 {
        100.0
    }

    pub(super) fn is_zombie(_pid: i32) -> bool {
        false
    }

    pub(super) fn listening(_table: &Table, _owners: &HashMap<i32, Owner>) -> Option<Vec<PortEntry>> {
        None
    }
}

/// Mounts `/` and `$HOME`, one per device (`df` would list both when they are the same disk).
#[allow(clippy::unnecessary_cast)] // statvfs field widths differ per platform
fn disks() -> Vec<Disk> {
    let mut mounts = vec!["/".to_string()];
    if let Some(home) = dirs::home_dir() {
        mounts.push(home.display().to_string());
    }
    let mut devices = HashSet::new();
    let mut out = Vec::new();
    for mount in mounts {
        let Ok(meta) = std::fs::metadata(&mount) else { continue };
        if !devices.insert(meta.dev()) {
            continue;
        }
        let Some(s) = statvfs(&mount) else { continue };
        let frsize = s.f_frsize as u64;
        let blocks = s.f_blocks as u64;
        out.push(Disk {
            mount,
            total: blocks * frsize,
            used: blocks.saturating_sub(s.f_bfree as u64) * frsize,
        });
    }
    out
}

fn statvfs(path: &str) -> Option<libc::statvfs> {
    let c = std::ffi::CString::new(path).ok()?;
    // SAFETY: a zeroed statvfs is a valid out-parameter; statvfs fills it in on success.
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is NUL-terminated and `s` is valid for writing.
    (unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0).then_some(s)
}

fn self_pid() -> i32 {
    std::process::id() as i32
}

fn daemon_owner() -> Owner {
    Owner {
        kind: OwnerKind::Daemon,
        id: None,
    }
}

/// Every process, with the daemon's own marked as the daemon.
/// Whether `pid` exists and is not a zombie. EPERM means it exists but belongs to someone else.
fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 checks that the process exists and may be signalled; it sends nothing.
    let r = unsafe { libc::kill(pid, 0) };
    let exists = r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    exists && !plat::is_zombie(pid)
}

fn owner_of(pid: i32) -> Option<Owner> {
    if pid == self_pid() {
        return Some(daemon_owner());
    }
    let table = plat::read_table()?;
    let marks = markers()?;
    match tree_owner(&table, &roots(), &marks, pid) {
        TreeOwner::Owned(owner) => Some(owner),
        TreeOwner::Free | TreeOwner::Unknown => None,
    }
}

/// Sends SIGTERM to a process of an agent or a terminal. Returns its owner.
/// Other processes, the daemon itself and pids that are not positive are refused.
pub fn terminate(pid: i32) -> Result<Owner, HostError> {
    if pid <= 0 {
        return Err(HostError::InvalidPid);
    }
    if !alive(pid) {
        return Err(HostError::NotFound);
    }
    let owner = match owner_of(pid) {
        Some(o) if o.kind != OwnerKind::Daemon => o,
        _ => return Err(HostError::Forbidden("not an agent or terminal process".into())),
    };
    // SAFETY: pid is positive and its owner was just read as an agent or terminal.
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        return Err(HostError::Io(std::io::Error::last_os_error().to_string()));
    }
    Ok(owner)
}

/// After the grace period, SIGKILL the process if it is still there and still has the same owner.
pub async fn force_after_grace(pid: i32, owner: Owner) {
    tokio::time::sleep(GRACE).await;
    let _ = tokio::task::spawn_blocking(move || {
        // The owner is read again: a pid that was reused by another process is left alone.
        if owner_of(pid).as_ref() == Some(&owner) && alive(pid) {
            // SAFETY: pid is positive; its owner was just checked.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    })
    .await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
    use std::time::Duration;

    const PROC_STAT_A: &str = "cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0\nintr 12345\nctxt 1\n";
    const PROC_STAT_B: &str = "cpu  200 0 200 900 0 0 0 0 0 0\ncpu0 100 0 100 450 0 0 0 0 0 0\ncpu1 100 0 100 450 0 0 0 0 0 0\nintr 12999\nctxt 2\n";

    #[test]
    fn proc_stat_two_readings_give_cpu_percent() {
        let (a, cpus) = parse_proc_stat(PROC_STAT_A);
        let (b, _) = parse_proc_stat(PROC_STAT_B);
        assert_eq!(cpus, 2);
        // 300 ticks passed in total, 100 of them idle: 200/300 busy.
        let pct = cpu_percent(a.unwrap(), b.unwrap());
        assert!((pct - 66.67).abs() < 0.05, "{pct}");
        let same = a.unwrap();
        assert_eq!(cpu_percent(same, same), 0.0);
    }

    #[test]
    fn loadavg_and_uptime() {
        assert_eq!(parse_loadavg("0.52 0.58 0.59 1/345 6789\n"), [0.52, 0.58, 0.59]);
        assert_eq!(parse_uptime("12345.67 98765.43\n"), 12345);
    }

    const MEMINFO: &str = "MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    8000000 kB\nSwapTotal:       2000000 kB\nSwapFree:        1500000 kB\n";

    #[test]
    fn meminfo_used_is_total_minus_available() {
        let m = parse_meminfo(MEMINFO);
        assert_eq!(m.total, 16_000_000 * 1024);
        assert_eq!(m.used, 8_000_000 * 1024);
        assert_eq!(m.swap_total, 2_000_000 * 1024);
        assert_eq!(m.swap_used, 500_000 * 1024);
    }

    const NET_DEV: &str = "Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n    lo:  999999   100    0    0    0     0          0         0   999999   100    0    0    0     0       0          0\n  eth0: 5000 50 0 0 0 0 0 0 3000 30 0 0 0 0 0 0\n wlan0: 1000 10 0 0 0 0 0 0 500 5 0 0 0 0 0 0\n";

    #[test]
    fn net_dev_sums_interfaces_without_loopback() {
        assert_eq!(parse_net_dev(NET_DEV), (6000, 3500));
    }

    #[test]
    fn rates_are_deltas_per_second_and_never_negative() {
        assert_eq!(rate(6000, 16000, 10.0), 1000);
        // A counter that went back (reboot, driver reload) gives no rate.
        assert_eq!(rate(16000, 6000, 10.0), 0);
        assert_eq!(rate(6000, 16000, 0.0), 0);
    }

    #[test]
    fn os_release_pretty_name() {
        let s = "NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04.2 LTS\"\nID=ubuntu\n";
        assert_eq!(parse_os_release(s).as_deref(), Some("Ubuntu 24.04.2 LTS"));
        assert_eq!(parse_os_release("ID=x\n"), None);
    }

    const TCP: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0\n   1: 0100007F:0BB8 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 22222 1 0000000000000000 100 0 0 10 0\n";
    const TCP6: &str = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 777 1 0000000000000000 100 0 0 10 0\n";

    #[test]
    fn proc_net_tcp_keeps_only_listening_sockets() {
        let v4 = parse_proc_net_tcp(TCP, false);
        assert_eq!(
            v4,
            vec![Listen {
                addr: IpAddr::V4(Ipv4Addr::LOCALHOST),
                port: 3000,
                inode: 12345
            }]
        );
        let v6 = parse_proc_net_tcp(TCP6, true);
        assert_eq!(
            v6,
            vec![Listen {
                addr: IpAddr::V6(Ipv6Addr::LOCALHOST),
                port: 8080,
                inode: 777
            }]
        );
    }

    #[test]
    fn pid_stat_reads_name_with_spaces_ticks_and_rss() {
        let s = "4242 (my (weird) app) S 1 4242 4242 0 -1 4194560 100 0 0 0 150 50 0 0 20 0 1 0 1000 1000000 300 18446744073709551615";
        let p = parse_pid_stat(s).unwrap();
        assert_eq!(p.name, "my (weird) app");
        assert_eq!(p.state, 'S');
        assert_eq!(p.ticks, 200);
        assert_eq!(p.rss_pages, 300);
    }

    #[test]
    fn owner_comes_from_marker_variables() {
        let agent = Owner {
            kind: OwnerKind::Agent,
            id: Some("agent-7".into()),
        };
        assert_eq!(
            owner_from_pairs(["PATH=/bin", "BANDITO_AGENT_ID=agent-7"]),
            Some(agent.clone())
        );
        // An agent's child that also runs in a terminal belongs to the agent.
        assert_eq!(
            owner_from_pairs(["BANDITO_TERM_ID=t-1", "BANDITO_AGENT_ID=agent-7"]),
            Some(agent)
        );
        assert_eq!(
            owner_from_pairs(["BANDITO_TERM_ID=t-1", "BANDITO_TERM=1"]),
            Some(Owner {
                kind: OwnerKind::Terminal,
                id: Some("t-1".into())
            })
        );
        assert_eq!(owner_from_pairs(["PATH=/bin", "BANDITO_AGENT_ID="]), None);
    }

    #[test]
    fn environ_bytes_are_nul_separated() {
        let owner = owner_from_environ(b"HOME=/root\0BANDITO_AGENT_ID=test-agent\0\0");
        assert_eq!(owner.unwrap().id.as_deref(), Some("test-agent"));
    }

    #[test]
    fn marker_line_gives_the_owner_from_the_environment() {
        let line = "  4242 /usr/local/bin/node server.js --port 3000 BANDITO_AGENT_ID=agent-7 HOME=/Users/me";
        let (pid, owner) = parse_marker_line(line).unwrap();
        assert_eq!(pid, 4242);
        assert_eq!(owner, Owner::agent("agent-7"));
        assert!(parse_marker_line("  77 /bin/sleep 30 HOME=/Users/me").is_none());
    }

    #[test]
    fn lsof_fields_give_listening_ports() {
        let out = "p4242\ncnode\nn127.0.0.1:3000\np5000\ncPython\nn*:5173\nn[::1]:8080\n";
        let got = parse_lsof(out);
        assert_eq!(got.len(), 3);
        assert_eq!(
            (got[0].pid, got[0].process.as_str(), got[0].addr.as_str(), got[0].port),
            (4242, "node", "127.0.0.1", 3000)
        );
        assert_eq!((got[1].addr.as_str(), got[1].port), ("*", 5173));
        assert_eq!((got[2].pid, got[2].addr.as_str(), got[2].port), (5000, "::1", 8080));
    }

    const VM_STAT: &str = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                                4000.\nPages active:                            100000.\nPages inactive:                          30000.\nPages wired down:                         50000.\nPages occupied by compressor:             20000.\n";

    #[test]
    fn vm_stat_used_is_active_wired_and_compressed() {
        assert_eq!(parse_vm_stat(VM_STAT), Some(170_000 * 16_384));
        assert_eq!(parse_vm_stat("no header here\n"), None);
    }

    const NETSTAT_IB: &str = "Name  Mtu   Network       Address            Ipkts Ierrs    Ibytes    Opkts Oerrs     Obytes  Coll\nlo0   16384 <Link#1>                          1000     0    500000     1000     0     500000     0\nlo0   16384 127           localhost         1000     0    500000     1000     0     500000     0\nen0   1500  <Link#6>      aa:bb:cc:dd:ee:ff 1234     0      5678     4321     0       8765     0\nen0   1500  192.168.1     192.168.1.20      1234     0      5678     4321     0       8765     0\n";

    #[test]
    fn netstat_sums_link_rows_without_loopback() {
        assert_eq!(parse_netstat_ib(NETSTAT_IB), Some((5678, 8765)));
    }

    #[test]
    fn sysctl_outputs_load_and_boot_time() {
        assert_eq!(parse_sysctl_loadavg("{ 1.23 1.10 0.98 }\n"), [1.23, 1.10, 0.98]);
        assert_eq!(
            parse_boottime("{ sec = 1728475200, usec = 123456 } Thu Oct  9 10:00:00 2026\n"),
            Some(1728475200)
        );
    }

    fn pt(t: i64, cpu: f32) -> Point {
        Point {
            t,
            cpu,
            mem_used: 1000,
            net_rx_bps: 10,
            net_tx_bps: 20,
        }
    }

    #[test]
    fn day_history_is_downsampled_to_360_averages() {
        let points: Vec<Point> = (0..8640i64).map(|i| pt(i * 10_000, (i % 100) as f32)).collect();
        let out = downsample(&points, MAX_HISTORY_POINTS);
        assert_eq!(out.len(), 360);
        let mean_in = points.iter().map(|p| p.cpu as f64).sum::<f64>() / points.len() as f64;
        let mean_out = out.iter().map(|p| p.cpu as f64).sum::<f64>() / out.len() as f64;
        assert!((mean_in - mean_out).abs() < 1e-6, "{mean_in} {mean_out}");
        assert!(out.windows(2).all(|w| w[0].t < w[1].t));
        assert!(
            out.iter()
                .all(|p| p.mem_used == 1000 && p.net_rx_bps == 10 && p.net_tx_bps == 20)
        );
    }

    #[test]
    fn short_history_is_returned_as_is() {
        let points: Vec<Point> = (0..360i64).map(|i| pt(i, 1.0)).collect();
        assert_eq!(downsample(&points, MAX_HISTORY_POINTS), points);
    }

    #[test]
    fn history_range_selects_the_window_and_limits_points() {
        let now = 100_000_000i64;
        let points: Vec<Point> = (0..8640i64).map(|k| pt(now - k * 10_000, 1.0)).collect();
        let hour = select_history(&points, now, HistoryRange::Hour, MAX_HISTORY_POINTS);
        assert!(!hour.is_empty() && hour.len() <= 360, "{}", hour.len());
        assert!(hour.iter().all(|p| p.t >= now - 3_600_000));
        let day = select_history(&points, now, HistoryRange::Day, MAX_HISTORY_POINTS);
        assert_eq!(day.len(), 360);
        assert!(day.iter().all(|p| p.t >= now - 86_400_000));
        assert_eq!(HistoryRange::parse("1h"), Some(HistoryRange::Hour));
        assert_eq!(HistoryRange::parse("24h"), Some(HistoryRange::Day));
        assert_eq!(HistoryRange::parse("7d"), None);
    }

    #[test]
    fn new_sampler_has_no_history_yet() {
        assert!(
            Sampler::new()
                .history(HistoryRange::Hour, MAX_HISTORY_POINTS)
                .is_empty()
        );
    }

    #[test]
    fn process_cpu_is_tick_delta_over_wall_time() {
        let one_s = Some(Duration::from_secs(1));
        assert!((cpu_from_ticks(Some(1000), 1100, one_s, 100.0) - 100.0).abs() < 0.01);
        // 50 ticks at 100 Hz is 0.5 s of CPU in 2 s of wall time.
        let two_s = Some(Duration::from_secs(2));
        assert!((cpu_from_ticks(Some(1000), 1050, two_s, 100.0) - 25.0).abs() < 0.01);
        assert_eq!(cpu_from_ticks(None, 1100, one_s, 100.0), 0.0);
        assert_eq!(cpu_from_ticks(Some(1000), 1100, None, 100.0), 0.0);
    }

    #[test]
    fn pid_stat_reads_the_start_time_and_memory() {
        // Fields after the name: state, ppid, pgrp, session, tty, tpgid, flags, minflt, cminflt, majflt,
        // cmajflt, utime 12, stime 13, cutime, cstime, priority, nice, threads, itrealvalue, starttime 20, vsize, rss 22.
        let stat = "123 (sleep) S 1 123 123 0 -1 4194560 100 0 0 0 5 7 0 0 20 0 1 0 98765 1000000 300";
        let st = parse_pid_stat(stat).unwrap();
        assert_eq!(st.name, "sleep");
        assert_eq!(st.ticks, 12);
        assert_eq!(st.rss_pages, 300);
        assert_eq!(st.start, 98765);
    }

    #[test]
    fn a_macos_helper_belongs_to_the_outermost_app_bundle() {
        let main = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130/\
            Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)";
        assert_eq!(bundle_app(main).as_deref(), Some("Google Chrome"));
        assert_eq!(bundle_app(helper).as_deref(), Some("Google Chrome"));
        assert_eq!(
            bundle_app("/Applications/Visual Studio Code.app/Contents/MacOS/Electron").as_deref(),
            Some("Visual Studio Code")
        );
        // No bundle: the caller falls back to the file name. An empty `.app` name is no bundle.
        assert_eq!(bundle_app("/usr/sbin/cfprefsd"), None);
        assert_eq!(bundle_app("/usr/bin/.app/x"), None);
    }

    /// An app row for the tests: the name is the app's, the pid tells the processes apart.
    fn app_row(pid: i32, app: &str, rss: u64, cpu: f32) -> AppRow {
        AppRow {
            pid,
            app: app.into(),
            name: format!("p{pid}"),
            rss_bytes: rss,
            cpu_percent: cpu,
        }
    }

    fn pids(group: &AppGroup) -> Vec<i32> {
        group.top.iter().map(|p| p.pid).collect()
    }

    #[test]
    fn apps_are_summed_with_exact_totals_and_ordered_by_memory() {
        let rows = vec![
            app_row(10, "Google Chrome", 100, 1.5),
            app_row(11, "Google Chrome", 300, 2.0),
            app_row(12, "Google Chrome", 200, 0.5),
            app_row(13, "Google Chrome", 50, 0.0),
            app_row(20, "sshd", 400, 0.25),
            app_row(30, "cargo", 10, 3.0),
            app_row(31, "cargo", 10, 0.0),
        ];
        let groups = group_apps(&rows, 10, 3);
        let names: Vec<&str> = groups.iter().map(|g| g.name.as_str()).collect();
        // 650 for Chrome, 400 for sshd, 20 for cargo.
        assert_eq!(names, ["Google Chrome", "sshd", "cargo"]);
        let chrome = &groups[0];
        assert_eq!(chrome.memory_bytes, 650);
        assert_eq!(chrome.process_count, 4);
        assert!((chrome.cpu_percent - 4.0).abs() < 0.001);
        // The three biggest by memory, biggest first, each with its own name, CPU and memory; the fourth is counted only.
        assert_eq!(pids(chrome), [11, 12, 10]);
        assert_eq!(chrome.top[0].name, "p11");
        assert_eq!(chrome.top[0].memory_bytes, 300);
        assert!((chrome.top[0].cpu_percent - 2.0).abs() < 0.001);
        assert_eq!(groups[2].process_count, 2);
        assert_eq!(pids(&groups[2]), [30, 31]);
    }

    #[test]
    fn app_groups_are_cut_to_the_count_and_ties_break_by_name() {
        let rows: Vec<AppRow> = (0..5)
            .map(|i| app_row(i, &format!("app{i}"), if i < 2 { 1000 } else { 1 + i as u64 }, 0.0))
            .collect();
        let groups = group_apps(&rows, 3, 3);
        let names: Vec<&str> = groups.iter().map(|g| g.name.as_str()).collect();
        // app0 and app1 tie at 1000: by name. Then app4 (5) is third; app3 (4) and app2 (3) are cut by the count.
        assert_eq!(names, ["app0", "app1", "app4"]);
        assert!(group_apps(&[], 25, 3).is_empty());
    }

    #[test]
    fn linux_apps_are_grouped_by_the_file_name() {
        // Linux has no bundles: the app is the executable's file name, the same name for every instance.
        let rows = vec![
            app_row(1, "node", 5, 1.0),
            app_row(2, "node", 7, 1.0),
            app_row(3, "bash", 1, 0.0),
        ];
        let groups = group_apps(&rows, APP_GROUPS, APP_TOP);
        assert_eq!(groups.len(), 2);
        assert_eq!((groups[0].name.as_str(), groups[0].process_count), ("node", 2));
        assert_eq!(pids(&groups[0]), [2, 1]);
    }

    #[test]
    fn agent_terminal_and_daemon_processes_are_owned_and_stay_out_of_apps() {
        let owned = |kind| TreeOwner::Owned(Owner { kind, id: None });
        assert!(is_owned(Some(&owned(OwnerKind::Agent))));
        assert!(is_owned(Some(&owned(OwnerKind::Terminal))));
        assert!(is_owned(Some(&owned(OwnerKind::Daemon))));
        // A process with no owner, and one whose tree cannot be read, are ordinary: they group by app.
        assert!(!is_owned(Some(&TreeOwner::Free)));
        assert!(!is_owned(Some(&TreeOwner::Unknown)));
        assert!(!is_owned(None));
    }

    fn row(ppid: i32) -> ProcRow {
        ProcRow {
            ppid,
            name: String::new(),
            app: String::new(),
            cmd: String::new(),
            rss_bytes: 0,
            cpu_ticks: 0,
            own: true,
        }
    }

    #[test]
    fn the_process_tree_decides_the_owner() {
        // 100 is an agent's CLI, 101 and 102 its children (system binaries in the real tree), 200 a terminal's shell.
        let table: Table = [
            (1, row(0)),
            (100, row(1)),
            (101, row(100)),
            (102, row(101)),
            (200, row(1)),
            (201, row(200)),
            (300, row(1)),
            (103, row(1)),
            (400, row(999)),
            (500, row(500)),
        ]
        .into_iter()
        .collect();
        let roots: HashMap<i32, Owner> = [(100, Owner::agent("a1")), (200, Owner::terminal("t1"))]
            .into_iter()
            .collect();
        // 103 carries an agent's environment mark, and no root.
        let marks: HashMap<i32, Owner> = [(103, Owner::agent("a2"))].into_iter().collect();
        let walk = |pid| tree_owner(&table, &roots, &marks, pid);
        assert_eq!(walk(102), TreeOwner::Owned(Owner::agent("a1")));
        assert_eq!(walk(101), TreeOwner::Owned(Owner::agent("a1")));
        assert_eq!(walk(201), TreeOwner::Owned(Owner::terminal("t1")));
        assert_eq!(walk(103), TreeOwner::Owned(Owner::agent("a2")));
        assert_eq!(walk(300), TreeOwner::Free);
        assert_eq!(walk(1), TreeOwner::Free);
        // A parent missing from the table: the tree cannot be read to the end.
        assert_eq!(walk(400), TreeOwner::Unknown);
        // A process that is its own parent, and a pid that is not in the table at all.
        assert_eq!(walk(500), TreeOwner::Unknown);
        assert_eq!(walk(777), TreeOwner::Unknown);
    }

    #[test]
    fn a_zombie_counts_as_gone() {
        // Exited but not reaped by its parent: the process is still in the table, and it is gone for `wait_gone`.
        let mut child = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        let pid = child.id() as i32;
        // SAFETY: the child is this test's own and is signalled only here.
        unsafe {
            libc::kill(pid, libc::SIGKILL);
        }
        assert!(wait_gone(pid, Duration::from_secs(5)));
        child.wait().unwrap();
    }

    #[test]
    fn a_process_that_is_not_free_is_refused_as_stoppable() {
        assert!(stoppable(&TreeOwner::Free).is_ok());
        let agent = stoppable(&TreeOwner::Owned(Owner::agent("a1"))).unwrap_err();
        assert!(
            matches!(agent, HostError::Forbidden(ref why) if why.contains("agent")),
            "{agent:?}"
        );
        // The fail-closed case: the tree could not be read, so the process is not stopped.
        let unknown = stoppable(&TreeOwner::Unknown).unwrap_err();
        assert!(
            matches!(unknown, HostError::Forbidden(ref why) if why.contains("tree")),
            "{unknown:?}"
        );
    }

    #[test]
    fn the_nearest_owner_wins() {
        let table: Table = [(1, row(0)), (100, row(1)), (101, row(100)), (102, row(101))]
            .into_iter()
            .collect();
        let roots: HashMap<i32, Owner> = [(100, Owner::agent("outer")), (101, Owner::agent("inner"))]
            .into_iter()
            .collect();
        assert_eq!(
            tree_owner(&table, &roots, &HashMap::new(), 102),
            TreeOwner::Owned(Owner::agent("inner"))
        );
    }

    #[test]
    fn the_table_has_this_process_with_its_parent_and_its_user() {
        let table = plat::read_table().expect("the process table");
        let me = table.get(&(std::process::id() as i32)).expect("this process");
        // SAFETY: getppid has no preconditions.
        assert_eq!(me.ppid, unsafe { libc::getppid() });
        assert!(me.own);
        assert!(me.rss_bytes > 0);
    }

    #[test]
    fn a_child_of_a_registered_root_is_owned_by_it() {
        // `sh` waits for its background `sleep`: the child keeps its parent in the table.
        let mut shell = std::process::Command::new("sh")
            .args(["-c", "sleep 30 & echo $!; wait"])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(&mut std::io::BufReader::new(shell.stdout.take().unwrap()), &mut line).unwrap();
        let sleep_pid: i32 = line.trim().parse().unwrap();
        let _root = register_root(shell.id() as i32, Owner::agent("tree-test"));
        let table = plat::read_table().expect("the process table");
        let marks = markers().expect("the owner marks");
        assert_eq!(
            tree_owner(&table, &roots(), &marks, sleep_pid),
            TreeOwner::Owned(Owner::agent("tree-test"))
        );
        // SAFETY: both pids are children of this test and are signalled only here.
        unsafe {
            libc::kill(sleep_pid, libc::SIGKILL);
        }
        let _ = shell.kill();
        let _ = shell.wait();
    }

    #[test]
    fn cpu_shares_are_the_change_in_cpu_time_and_repeats_within_a_second_are_kept() {
        let mut state = CpuState::default();
        let t0 = Instant::now();
        let table = |ticks: u64| -> Table {
            [(
                7,
                ProcRow {
                    cpu_ticks: ticks,
                    ..row(1)
                },
            )]
            .into_iter()
            .collect()
        };
        // The first reading has nothing to compare with.
        assert_eq!(cpu_shares(&mut state, &table(100), t0, 100.0)[&7], 0.0);
        // 200 ticks at 100 per second is 2 s of CPU in 2 s of wall time: a whole CPU.
        let two_s = t0 + Duration::from_secs(2);
        assert!((cpu_shares(&mut state, &table(300), two_s, 100.0)[&7] - 100.0).abs() < 0.01);
        // A reading only half a second later keeps the last share.
        let later = two_s + Duration::from_millis(500);
        assert!((cpu_shares(&mut state, &table(900), later, 100.0)[&7] - 100.0).abs() < 0.01);
    }

    #[test]
    fn the_top_lists_are_the_biggest_by_memory_and_the_busiest_by_cpu() {
        // Pid 2 is the busiest, pid 3 the biggest: both are listed, biggest memory first.
        assert_eq!(top_pids(&[(1, 100, 0.0), (2, 50, 90.0), (3, 300, 0.0)], 1), vec![3, 2]);
        // Ties keep the lower pid first.
        assert_eq!(top_pids(&[(9, 5, 0.0), (3, 5, 0.0), (7, 5, 0.0)], 3), vec![3, 7, 9]);
    }

    #[test]
    fn the_top_lists_have_each_count_without_repeats() {
        // Memory grows with the pid, so the biggest 15 are 6..=20; CPU is equal, so the busiest 15 are 1..=15.
        let rows: Vec<(i32, u64, f32)> = (1..=20).map(|i| (i, i as u64 * 1_000, 0.0)).collect();
        let top = top_pids(&rows, 15);
        assert_eq!(top.len(), 20);
        assert_eq!(top[0], 20);
        let mut sorted = top.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), 20, "no process is listed twice");
    }

    #[test]
    fn cpu_time_reads_minutes_hours_and_days_in_hundredths() {
        assert_eq!(parse_cpu_time("107:33.19"), Some(645_319));
        assert_eq!(parse_cpu_time("1:02:03.45"), Some(372_345));
        assert_eq!(parse_cpu_time("2-01:02:03.45"), Some(17_652_345));
        assert_eq!(parse_cpu_time("0:01.50"), Some(150));
        assert_eq!(parse_cpu_time("soon"), None);
    }

    #[test]
    fn table_line_reads_pid_parent_memory_user_cpu_time_and_the_file_name() {
        let line = parse_table_line(
            "  4242     1 204800  501 0:01.50 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        .unwrap();
        assert_eq!(
            (line.pid, line.ppid, line.rss_bytes, line.uid, line.cpu_ticks),
            (4242, 1, 204_800 * 1024, 501, 150)
        );
        assert_eq!(line.name, "Google Chrome");
        assert_eq!(line.cmd, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
        let launchd = parse_table_line("1 0 18416 0 107:33.19 /sbin/launchd").unwrap();
        assert_eq!(
            (launchd.ppid, launchd.name.as_str(), launchd.cpu_ticks),
            (0, "launchd", 645_319)
        );
        assert!(parse_table_line("not a process line").is_none());
        assert!(parse_table_line("12 1 abc 501 0:00.00 /bin/x").is_none());
    }
}
