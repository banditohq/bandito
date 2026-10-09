import Foundation

// The server's own health: load, processes, ports (`host.*`).

extension ServerModel {
    public func hostStats() async throws -> HostStats {
        try await rpc().call("host.stats", NoParams(), as: HostStats.self)
    }

    /// Samples over a time range such as `"1h"` (the range names are the daemon's).
    public func hostHistory(range: String) async throws -> [HostPoint] {
        struct P: Encodable { var range: String }
        return try await rpc().call("host.history", P(range: range), as: HostHistory.self).points
    }

    public func hostProcesses() async throws -> HostProcesses {
        try await rpc().call("host.processes", NoParams(), as: HostProcesses.self)
    }

    public func hostPorts() async throws -> HostPorts {
        try await rpc().call("host.ports", NoParams(), as: HostPorts.self)
    }

    /// Kills a process the daemon lists (`host.processes`).
    public func kill(pid: Int) async throws {
        struct P: Encodable { var pid: Int }
        try await rpc().call("host.kill", P(pid: pid))
    }
}
