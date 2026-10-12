import BanditoKit
import Foundation
import Observation

/// What the agent card changes on a server: `ServerModel` in the app, a fake in the tests. The methods are the RPCs the
/// Mac's agent inspector uses: `agents.update` (and `agents.update {paused}`), `agents.delete`, `schedules.*`.
@MainActor
protocol AgentEditingServer: AnyObject {
    func updateAgent(_ id: String, patch: AgentPatch) async throws -> AgentUpdate
    func setPaused(agentID: String, _ paused: Bool) async throws -> Agent
    func deleteAgent(_ id: String) async throws
    func schedules(agentId: String?) async throws -> [Schedule]
    func setScheduleEnabled(_ id: String, _ enabled: Bool) async throws -> Schedule
    func runScheduleNow(_ id: String) async throws
}

extension ServerModel: AgentEditingServer {
    func setScheduleEnabled(_ id: String, _ enabled: Bool) async throws -> Schedule {
        try await updateSchedule(id, enabled: enabled)
    }
}

/// The state and the edits of the agent card. Every change is one RPC on the server, and the server model takes the
/// agent the daemon answers with. A failure is kept as text for the screen to show; the agent stays as it was.
@MainActor
@Observable
final class AgentDetailModel {
    let agentID: String
    private let server: AgentEditingServer

    /// The agent's schedules, as the daemon lists them. Empty until `loadSchedules` answers.
    private(set) var schedules: [Schedule] = []
    /// The last failure, as the message to show; nil when the last change went through.
    private(set) var failure: String?
    /// Counts the saves that went through (a haptic on each).
    private(set) var savedCount = 0
    /// Counts the schedules that were started by hand (a haptic on each).
    private(set) var ranCount = 0

    init(server: AgentEditingServer, agentID: String) {
        self.server = server
        self.agentID = agentID
    }

    /// Reads the agent's schedules. A failure is kept; the list stays empty.
    func loadSchedules() async {
        do {
            schedules = try await server.schedules(agentId: agentID)
        } catch {
            failure = AgentForms.errorText(error)
        }
    }

    /// Applies one patch to the agent (`agents.update`). Returns whether it went through.
    @discardableResult
    func save(_ patch: AgentPatch) async -> Bool {
        do {
            _ = try await server.updateAgent(agentID, patch: patch)
            failure = nil
            savedCount += 1
            return true
        } catch {
            failure = AgentForms.errorText(error)
            return false
        }
    }

    /// Pauses or resumes the agent (`agents.update {paused}`).
    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        do {
            _ = try await server.setPaused(agentID: agentID, paused)
            failure = nil
            savedCount += 1
            return true
        } catch {
            failure = AgentForms.errorText(error)
            return false
        }
    }

    /// Switches one schedule on or off (`schedules.update {enabled}`), and keeps the list in step with the answer.
    func setScheduleEnabled(_ id: String, _ enabled: Bool) async {
        do {
            let updated = try await server.setScheduleEnabled(id, enabled)
            replaceSchedule(updated)
            failure = nil
        } catch {
            failure = AgentForms.errorText(error)
            await loadSchedules()
        }
    }

    /// Starts a schedule now (`schedules.run_now`).
    func runScheduleNow(_ id: String) async {
        do {
            try await server.runScheduleNow(id)
            failure = nil
            ranCount += 1
        } catch {
            failure = AgentForms.errorText(error)
        }
    }

    /// Deletes the agent (`agents.delete`). Returns whether it went through; the server model drops the agent then.
    func delete() async -> Bool {
        do {
            try await server.deleteAgent(agentID)
            failure = nil
            return true
        } catch {
            failure = AgentForms.errorText(error)
            return false
        }
    }

    private func replaceSchedule(_ updated: Schedule) {
        if let index = schedules.firstIndex(where: { $0.id == updated.id }) {
            schedules[index] = updated
        }
    }

}

/// The patch that changes the agent's name and role. A field that did not change is left out, so the daemon keeps it.
enum AgentEdit {
    static func identity(name: String, role: String, current: Agent) -> AgentPatch? {
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !newName.isEmpty && newName != current.name
        let roleChanged = newRole != current.role
        guard nameChanged || roleChanged else { return nil }
        return AgentPatch(name: nameChanged ? newName : nil, role: roleChanged ? newRole : nil)
    }

    /// The model choice as a patch: `nil` goes back to the runtime's default (`agents.update {model: null}`).
    static func model(_ model: String?) -> AgentPatch {
        let change: FieldChange<String> = model.map { FieldChange<String>.set($0) } ?? .clear
        return AgentPatch(model: change)
    }
}
