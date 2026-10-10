import Foundation

// Wire models for `host.*` (docs/ARCHITECTURE.md#host). Source: daemon/src/host.rs (structs) and
// daemon/src/rpc/host.rs (method replies). Decoded with `.convertFromSnakeCase`.

public struct HostDisk: Codable, Sendable, Hashable {
    public var mount: String
    public var total: Int64
    public var used: Int64
}

/// A snapshot of the server (`host.stats`).
public struct HostStats: Codable, Sendable, Hashable {
    public var os: String
    public var kernel: String
    public var arch: String
    public var hostname: String
    public var cpus: Int
    /// Busy share of all CPUs, 0...100.
    public var cpuPercent: Double
    /// 1, 5 and 15 minute load averages.
    public var load: [Double]
    public var memTotal: Int64
    public var memUsed: Int64
    public var swapTotal: Int64
    public var swapUsed: Int64
    /// `/` and the daemon user's home, one entry per device.
    public var disks: [HostDisk]
    public var netRxBps: Int64
    public var netTxBps: Int64
    /// False where the daemon cannot read network counters; then the network fields are 0.
    public var netSupported: Bool
    public var uptimeS: Int64
    /// The biggest processes of the server by memory. `nil` from a daemon that predates the list.
    public var topProcesses: [HostTopProcess]?
    /// Every process of the server summed by app, the biggest 25 by memory (`app_groups`). `nil` from a daemon that
    /// predates the field; an empty list where the daemon cannot read the process table.
    public var appGroups: [HostAppGroup]?
}

/// One app in `host.stats` → `app_groups`: all of its processes, helpers included, with exact sums.
public struct HostAppGroup: Codable, Sendable, Hashable {
    /// The app's name (the `.app` bundle without `.app` on macOS, else the program's file name).
    public var name: String
    /// Share of one CPU, summed over the app's processes; can exceed 100.
    public var cpuPercent: Double
    public var memoryBytes: Int64
    public var processCount: Int
    /// Up to three of the app's processes, the biggest by memory first.
    public var topPids: [Int]
}

/// One of the busiest or biggest processes of the server (`host.stats` → `top_processes`).
public struct HostTopProcess: Codable, Sendable, Hashable {
    public var pid: Int
    /// The program's file name.
    public var name: String
    public var rssBytes: Int64
    /// Share of one CPU; 0 on the first reading after the daemon starts.
    public var cpuPercent: Double
    /// Runs as the daemon's user.
    public var own: Bool
    /// The daemon says the app may stop it: its user's, with no agent, terminal or daemon owner, and its tree is known.
    /// A daemon that does not send the flag gives `false`, so nothing is stopped by mistake.
    public var ownSafe: Bool

    public init(pid: Int, name: String, rssBytes: Int64, cpuPercent: Double, own: Bool, ownSafe: Bool) {
        self.pid = pid
        self.name = name
        self.rssBytes = rssBytes
        self.cpuPercent = cpuPercent
        self.own = own
        self.ownSafe = ownSafe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int.self, forKey: .pid)
        name = try c.decode(String.self, forKey: .name)
        rssBytes = try c.decode(Int64.self, forKey: .rssBytes)
        cpuPercent = try c.decode(Double.self, forKey: .cpuPercent)
        own = try c.decode(Bool.self, forKey: .own)
        ownSafe = try c.decodeIfPresent(Bool.self, forKey: .ownSafe) ?? false
    }
}

/// The reply of `host.kill_process`: `killed` is true when the process was gone within a second; the daemon
/// sends SIGKILL after five seconds if it is still the same process.
public struct HostKillReply: Codable, Sendable, Hashable {
    public var ok: Bool
    public var killed: Bool
}

/// The rows of the Memory and CPU detail lists, and whether each one can be stopped from the app.
public enum HostProcessList {
    public enum Sort: Sendable {
        case memory, cpu
    }

    /// Most rows a detail list shows.
    public static let limit = 15

    /// The processes the daemon sends (the union of its biggest and busiest), matched with the owners from
    /// `host.processes` and sorted for one list: biggest memory first, or busiest CPU first, ties by pid. The list
    /// is cut to `limit`, so each list shows the true top for its metric. A process of an agent or a terminal keeps
    /// its owner and is never stopped here: its agent or terminal stops it, and the daemon refuses those pids too.
    public static func rows(top: [HostTopProcess], owners: [ProcessOwner], sort: Sort, limit: Int = limit) -> [HostProcessEntry] {
        var ownerOf: [Int: ProcessOwnerRef] = [:]
        for group in owners {
            for process in group.processes {
                ownerOf[process.pid] = group.owner
            }
        }
        let entries = top.map { process in
            let owner = ownerOf[process.pid]
            return HostProcessEntry(
                pid: process.pid,
                name: process.name,
                rssBytes: process.rssBytes,
                cpuPercent: process.cpuPercent,
                owner: owner,
                canStop: canStop(pid: process.pid, ownSafe: process.ownSafe, owner: owner))
        }
        let sorted = entries.sorted { a, b in
            switch sort {
            case .memory: a.rssBytes != b.rssBytes ? a.rssBytes > b.rssBytes : a.pid < b.pid
            case .cpu: a.cpuPercent != b.cpuPercent ? a.cpuPercent > b.cpuPercent : a.pid < b.pid
            }
        }
        return Array(sorted.prefix(limit))
    }

    /// The app a process belongs to, for grouping: the helper suffixes of a browser or an Electron app are cut, so
    /// "Google Chrome Helper (Renderer)" and "Google Chrome Helper" are both "Google Chrome". A name that is nothing but
    /// a suffix stays as it is.
    public static func appName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for tag in ["Renderer", "GPU", "Plugin", "Alerts"] {
            let suffix = " (\(tag))"
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces) }
        }
        if name.hasSuffix(" Helper") { name = String(name.dropLast(" Helper".count)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? raw : name
    }

    /// Merges the rows of one app into a group with the summed load, biggest first for `sort`. A process of an agent,
    /// a terminal or the daemon is grouped only with the processes of the same owner and app, never with others'.
    /// Members of a group keep the order of `sort`.
    public static func groups(_ rows: [HostProcessEntry], sort: Sort) -> [HostProcessGroup] {
        var order: [String] = []
        var members: [String: [HostProcessEntry]] = [:]
        for row in rows {
            let app = appName(row.name)
            let key = row.owner.map { "\($0.kind.rawValue):\($0.id ?? "")|\(app)" } ?? "|\(app)"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(row)
        }
        let groups = order.map { key -> HostProcessGroup in
            let list = members[key, default: []].sorted(by: { precedes($0, $1, sort) })
            return HostProcessGroup(
                id: key, appName: appName(list[0].name), owner: list[0].owner, members: list,
                rssBytes: list.reduce(0) { $0 + $1.rssBytes }, cpuPercent: list.reduce(0) { $0 + $1.cpuPercent },
                processCount: list.count)
        }
        return groups.sorted { a, b in
            let pa: Double, pb: Double
            switch sort {
            case .memory: (pa, pb) = (Double(a.rssBytes), Double(b.rssBytes))
            case .cpu: (pa, pb) = (a.cpuPercent, b.cpuPercent)
            }
            return pa != pb ? pa > pb : a.members[0].pid < b.members[0].pid
        }
    }

    /// The groups of `host.stats` → `app_groups`: one per app, with the daemon's exact sums over all of its processes.
    /// Members are the app's processes the daemon named (`top_pids`) that `rows` also carries, sorted for `sort`; the
    /// group expands only when it has such members. Its owner is nil: the daemon's app groups do not split owners.
    public static func appGroups(_ apps: [HostAppGroup], rows: [HostProcessEntry], sort: Sort) -> [HostProcessGroup] {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = apps.map { app in
            HostProcessGroup(
                id: "app|\(app.name)", appName: app.name, owner: nil,
                members: app.topPids.compactMap { byPid[$0] }.sorted(by: { precedes($0, $1, sort) }),
                rssBytes: app.memoryBytes, cpuPercent: app.cpuPercent, processCount: app.processCount)
        }
        return groups.sorted { a, b in
            switch sort {
            case .memory: a.rssBytes != b.rssBytes ? a.rssBytes > b.rssBytes : a.appName < b.appName
            case .cpu: a.cpuPercent != b.cpuPercent ? a.cpuPercent > b.cpuPercent : a.appName < b.appName
            }
        }
    }

    /// Whether `a` is listed before `b`: by memory or by CPU for `sort`, ties by pid.
    private static func precedes(_ a: HostProcessEntry, _ b: HostProcessEntry, _ sort: Sort) -> Bool {
        switch sort {
        case .memory: a.rssBytes != b.rssBytes ? a.rssBytes > b.rssBytes : a.pid < b.pid
        case .cpu: a.cpuPercent != b.cpuPercent ? a.cpuPercent > b.cpuPercent : a.pid < b.pid
        }
    }

    /// Whether the app offers to stop a process: the daemon says it is safe to stop, it has no agent, terminal or
    /// daemon owner, and it is not pid 1.
    public static func canStop(pid: Int, ownSafe: Bool, owner: ProcessOwnerRef?) -> Bool {
        ownSafe && owner == nil && pid > 1
    }
}

/// A process in a detail list (see `HostProcessList`).
public struct HostProcessEntry: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var name: String
    public var rssBytes: Int64
    public var cpuPercent: Double
    /// The agent, terminal or daemon the process belongs to; nil for an ordinary process.
    public var owner: ProcessOwnerRef?
    public var canStop: Bool

    public var id: Int { pid }

    /// A process of a Bandito agent: it gets the agent's mark.
    public var isAgent: Bool { owner?.kind == .agent }
}

/// The processes of one app in a detail list, with their summed load.
public struct HostProcessGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var appName: String
    /// The agent, terminal or daemon the processes belong to; nil for ordinary ones.
    public var owner: ProcessOwnerRef?
    /// The processes of the app that the list knows by name; for a daemon group, possibly fewer than `processCount`.
    public var members: [HostProcessEntry]
    public var rssBytes: Int64
    public var cpuPercent: Double
    /// How many processes the app has in all.
    public var processCount: Int

    /// More than one process: the row has no stop action of its own, and it expands when it has members to show.
    public var isGroup: Bool { processCount > 1 }
}

extension HostStats {
    /// The disk the app shows as the server's disk: `/`, or the first entry when `/` is not listed. The overview,
    /// the disk detail and the Files sidebar all read this one, so they show the same free space.
    public var primaryDisk: HostDisk? {
        disks.first { $0.mount == "/" } ?? disks.first
    }
}

/// Range of `host.history`. The daemon keeps 24 hours of samples.
public enum HostHistoryRange: String, Sendable, CaseIterable {
    case hour = "1h"
    case day = "24h"
}

/// One sample of the server's history (`host.history`).
public struct HostPoint: Codable, Sendable, Hashable {
    /// Unix milliseconds.
    public var t: Int64
    public var cpu: Double
    public var memUsed: Int64
    public var netRxBps: Int64
    public var netTxBps: Int64
}

/// Wire reply of `host.history`.
public struct HostHistory: Codable, Sendable, Hashable {
    public var points: [HostPoint]
}

/// What a process or port belongs to. `daemon` is the daemon's own process, with no `id`.
public enum ProcessOwnerKind: String, ForwardCompatibleEnum, CaseIterable {
    case agent, terminal, daemon

    /// An owner kind this app doesn't know is shown as the daemon's: it never gets agent or terminal actions.
    public static var fallback: ProcessOwnerKind { .daemon }
}

/// An owner of processes or ports. `id` is the agent or terminal id; nil for the daemon.
public struct ProcessOwnerRef: Codable, Sendable, Hashable {
    public var kind: ProcessOwnerKind
    public var id: String?

    public init(kind: ProcessOwnerKind, id: String?) {
        self.kind = kind
        self.id = id
    }
}

public struct HostProcess: Codable, Sendable, Hashable {
    public var pid: Int
    public var name: String
    public var cmd: String
}

/// Processes of one owner, with their total load (one entry of `host.processes`).
public struct ProcessOwner: Codable, Sendable, Hashable {
    public var owner: ProcessOwnerRef
    /// Summed over the owner's processes, so it can exceed 100.
    public var cpuPercent: Double
    public var rssBytes: Int64
    public var processes: [HostProcess]
}

/// Wire reply of `host.processes`. `supported` is false where the platform has no reader.
public struct HostProcesses: Codable, Sendable, Hashable {
    public var supported: Bool
    public var owners: [ProcessOwner]
}

/// A listening TCP port (`host.ports`).
public struct ListeningPort: Codable, Sendable, Hashable {
    public var port: Int
    /// `*` means all interfaces.
    public var addr: String
    /// nil when the owning process is not visible to the daemon.
    public var pid: Int?
    public var process: String?
    /// Absent (nil) when the port's process has no agent or terminal owner.
    public var owner: ProcessOwnerRef?
}

/// Wire reply of `host.ports`.
public struct HostPorts: Codable, Sendable, Hashable {
    public var supported: Bool
    public var ports: [ListeningPort]
}
