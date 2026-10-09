import Foundation

// Wire models for `host.*`. The daemon's contract for these is not yet in docs/ARCHITECTURE.md;
// the fields follow the host branch's request list (stats, history, processes, ports, kill).

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
    /// 0...100 across all CPUs.
    public var cpuPercent: Double
    /// 1, 5 and 15 minute load averages.
    public var load: [Double]
    public var memTotal: Int64
    public var memUsed: Int64
    public var swapTotal: Int64
    public var swapUsed: Int64
    public var disks: [HostDisk]
    public var netRxBps: Int64
    public var netTxBps: Int64
    public var uptimeS: Int64
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

/// Wire wrapper of `host.history`.
public struct HostHistory: Codable, Sendable, Hashable {
    public var points: [HostPoint]
}

/// Who owns processes or ports: an agent, a terminal, and so on. `kind` and `id` are opaque to the app.
public struct ProcessOwnerRef: Codable, Sendable, Hashable {
    public var kind: String
    public var id: String
}

public struct HostProcess: Codable, Sendable, Hashable {
    public var pid: Int
    public var name: String
    public var cmd: String
}

/// Processes of one owner, with their total load (`host.processes`).
public struct ProcessOwner: Codable, Sendable, Hashable {
    public var owner: ProcessOwnerRef
    public var cpuPercent: Double
    public var rssBytes: Int64
    public var processes: [HostProcess]
}

/// Wire reply of `host.processes`. `supported` is false where the platform cannot list processes.
public struct HostProcesses: Codable, Sendable, Hashable {
    public var supported: Bool
    public var owners: [ProcessOwner]
}

/// A TCP port that something listens on (`host.ports`).
public struct ListeningPort: Codable, Sendable, Hashable {
    public var port: Int
    public var addr: String
    /// `nil` when the owning process is not visible to the daemon.
    public var pid: Int?
    public var process: String?
    public var owner: ProcessOwnerRef?
}

/// Wire reply of `host.ports`.
public struct HostPorts: Codable, Sendable, Hashable {
    public var supported: Bool
    public var ports: [ListeningPort]
}
