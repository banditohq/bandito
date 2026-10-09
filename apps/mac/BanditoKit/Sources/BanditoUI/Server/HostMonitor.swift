import BanditoKit
import Foundation
import Observation

/// Processes of one owner (an agent, a terminal or the daemon), summed up for the "who uses the most" list.
struct ProcessRow: Identifiable, Hashable {
    var owner: ProcessOwnerRef
    var pids: [Int]
    /// Distinct process names, joined with " · ".
    var commandNames: String
    var cpuPercent: Double
    var rssBytes: Int64

    var id: String {
        "\(owner.kind.rawValue):\(owner.id ?? "")"
    }

    /// The daemon's own processes are never stopped from the app; the daemon refuses them too.
    var canStop: Bool {
        owner.kind != .daemon && owner.id != nil && !pids.isEmpty
    }

    static func rows(from owners: [ProcessOwner]) -> [ProcessRow] {
        owners.map { owner in
            var names: [String] = []
            for process in owner.processes where !names.contains(process.name) {
                names.append(process.name)
            }
            return ProcessRow(
                owner: owner.owner,
                pids: owner.processes.map(\.pid),
                commandNames: names.joined(separator: " · "),
                cpuPercent: owner.cpuPercent,
                rssBytes: owner.rssBytes)
        }
        .sorted { $0.cpuPercent > $1.cpuPercent }
    }
}

/// Keeps the Server overview's numbers fresh: host stats, history, processes and ports, every ten seconds.
@MainActor
@Observable
final class HostMonitor {
    static let interval: Duration = .seconds(10)

    private(set) var stats: HostStats?
    private(set) var history: [HostPoint] = []
    private(set) var processes: [ProcessRow] = []
    private(set) var processesSupported = true
    private(set) var ports: [ListeningPort] = []
    private(set) var portsSupported = true
    /// The last failure of a refresh, for the user.
    private(set) var error: String?

    var range: HostHistoryRange = .hour

    /// Refreshes until the task is cancelled. Run it from `.task(id:)` so it stops when the view goes away.
    func run(_ server: ServerModel) async {
        while !Task.isCancelled {
            // Before the server reports the feature (or while not connected) there is nothing to ask for.
            if server.supports("host") {
                await refresh(server)
            }
            try? await Task.sleep(for: Self.interval)
        }
    }

    func refresh(_ server: ServerModel) async {
        var failures: [String] = []
        do { stats = try await server.hostStats() } catch { failures.append(error.localizedDescription) }
        do { history = try await server.hostHistory(range: range) } catch { failures.append(error.localizedDescription) }
        do {
            let reply = try await server.hostProcesses()
            processesSupported = reply.supported
            processes = ProcessRow.rows(from: reply.owners)
        } catch {
            failures.append(error.localizedDescription)
        }
        do {
            let reply = try await server.hostPorts()
            portsSupported = reply.supported
            ports = reply.ports.sorted { $0.port < $1.port }
        } catch {
            failures.append(error.localizedDescription)
        }
        error = failures.first
    }

    /// Switches the history range and loads its points.
    func setRange(_ range: HostHistoryRange, server: ServerModel) async {
        self.range = range
        do { history = try await server.hostHistory(range: range) } catch { self.error = error.localizedDescription }
    }
}
