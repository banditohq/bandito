import BanditoKit
import Foundation
import Observation

/// The path the connect wizard opens on: the join code when the account can sign a phone in, else the pairing code
/// (the server is chosen first).
enum PhoneWizardPath: Equatable {
    case joinFirst
    case pairCode

    static func path(accountReady: Bool) -> PhoneWizardPath {
        accountReady ? .joinFirst : .pairCode
    }
}

/// Turns the phone access on for every connected server that can take it, while the join code is on screen. It asks
/// nobody: it does what the pairing path does once a server is chosen. A server that is on already answers at once. A
/// server that fails is kept, and "Try again" asks it again.
@MainActor
@Observable
final class PhoneAccessWarmup {
    enum Status: Equatable {
        case enabling
        case ready
        case failed
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        var status: Status
    }

    /// What the line under the join code says.
    enum Summary: Equatable {
        /// No server can take the access.
        case noServers
        /// At least one server is still being asked.
        case enabling
        /// The names of the servers the iPhone will see.
        case ready([String])
        /// The names of the servers whose access did not turn on.
        case failed([String])
    }

    private(set) var rows: [Row] = []
    @ObservationIgnored private var targets: [any PhoneWizardServer] = []
    @ObservationIgnored private let enable: @MainActor (any PhoneWizardServer) async -> Bool
    @ObservationIgnored private var run: Task<Void, Never>?
    /// The enable under way for each server. It is not cancelled with the wizard: a registration is never left
    /// half-way, and the pairing path waits for it (`settle`).
    @ObservationIgnored private var inFlight: [UUID: Task<Bool, Never>] = [:]

    init(enable: @escaping @MainActor (any PhoneWizardServer) async -> Bool) {
        self.enable = enable
    }

    var summary: Summary {
        if rows.isEmpty { return .noServers }
        if rows.contains(where: { $0.status == .enabling }) { return .enabling }
        let failed = rows.filter { $0.status == .failed }.map(\.name)
        if !failed.isEmpty { return .failed(failed) }
        return .ready(rows.map(\.name))
    }

    /// Starts on the servers that can take the access (connected, with the cloud and pairing). Starting again is safe:
    /// the servers that are on answer at once.
    func start(_ candidates: [any PhoneWizardServer]) {
        targets = ConnectPhoneModel.eligible(candidates)
        rows = targets.map { Row(id: $0.wizardID, name: $0.wizardName, status: .enabling) }
        go(targets)
    }

    /// Asks again for the servers that failed; the others keep their state.
    func retry() {
        // A run still asking would be cut off, and its servers left "turning on".
        guard !rows.contains(where: { $0.status == .enabling }) else { return }
        let failedIDs = Set(rows.filter { $0.status == .failed }.map(\.id))
        let failed = targets.filter { failedIDs.contains($0.wizardID) }
        guard !failed.isEmpty else { return }
        for index in rows.indices where failedIDs.contains(rows[index].id) {
            rows[index].status = .enabling
        }
        go(failed)
    }

    /// Stops asking further servers and forgets the lines. An enable already sent finishes on its own (`settle`).
    func cancel() {
        run?.cancel()
        run = nil
        rows = []
    }

    /// Whether an enable was sent and has not answered yet.
    var hasEnableUnderWay: Bool { !inFlight.isEmpty }

    /// Waits until no enable is under way.
    func settle() async {
        for task in Array(inFlight.values) {
            _ = await task.value
        }
    }

    /// Asks the servers one after another: each answer shows as it comes.
    private func go(_ servers: [any PhoneWizardServer]) {
        run?.cancel()
        run = Task { [weak self] in
            for server in servers {
                guard let self, !Task.isCancelled else { return }
                let ok = await self.enableOnce(server)
                guard !Task.isCancelled else { return }
                self.set(server.wizardID, ok ? .ready : .failed)
            }
        }
    }

    /// One enable per server at a time: a second ask waits for the first and takes its answer.
    private func enableOnce(_ server: any PhoneWizardServer) async -> Bool {
        let id = server.wizardID
        if let running = inFlight[id] { return await running.value }
        let enable = enable
        // The task clears its own entry, so whoever awaits it (`settle`) finds nothing under way afterwards.
        let task = Task { @MainActor [weak self] in
            let ok = await enable(server)
            self?.inFlight[id] = nil
            return ok
        }
        inFlight[id] = task
        return await task.value
    }

    private func set(_ id: UUID, _ status: Status) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].status = status
    }
}
