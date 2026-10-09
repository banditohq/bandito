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
