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

/// The parts of the card that can fail on their own. A failure is shown in its part, next to its control.
enum AgentArea: Hashable {
    case identity, status, work, approval, capabilities, schedules, delete
}

/// The state and the edits of the agent card. Every change is one RPC on the server, and the server model takes the agent
/// the daemon answers with. A failure is kept as text in its area; the agent stays as it was.
@MainActor
@Observable
final class AgentDetailModel {
    let agentID: String
    private let server: AgentEditingServer

    /// The agent's schedules, as the daemon lists them. Empty until `loadSchedules` answers.
    private(set) var schedules: [Schedule] = []
    /// The last failure of each area, as the message to show there. An area without one has no entry.
    private(set) var failures: [AgentArea: String] = [:]
    /// Counts the saves that went through (a haptic on each).
    private(set) var savedCount = 0
    /// Counts the schedules started by hand (a haptic on each).
    private(set) var ranCount = 0
    /// The "May do" chips as shown: a tap sets them at once, and they are taken from the agent again when no send is
    /// in flight (the Mac's `InspectorTabs` does the same).
    private(set) var chips: Set<AgentCapability> = []
    private var serverChips: Set<AgentCapability> = []
    private var chipsInFlight = 0
    private var chipChain: Task<Void, Never>?

    init(server: AgentEditingServer, agentID: String) {
        self.server = server
        self.agentID = agentID
    }

    /// Takes the agent's list of rights as the server has it. The chips follow it unless a send is still in flight.
    func syncChips(with agent: Agent) {
        serverChips = AgentCapability.set(from: agent.capabilities)
        if chipsInFlight == 0 {
            chips = serverChips
        }
    }

    /// Reads the agent's schedules. A failure is kept in the schedules area; the list stays empty.
    func loadSchedules() async {
        do {
            schedules = try await server.schedules(agentId: agentID)
            failures[.schedules] = nil
        } catch {
            failures[.schedules] = AgentForms.errorText(error)
        }
    }

    /// Applies one patch to the agent (`agents.update`). Returns whether it went through.
    @discardableResult
    func save(_ patch: AgentPatch, in area: AgentArea = .identity) async -> Bool {
        do {
            _ = try await server.updateAgent(agentID, patch: patch)
            failures[area] = nil
            savedCount += 1
            return true
        } catch {
            failures[area] = AgentForms.errorText(error)
            return false
        }
    }

    /// Pauses or resumes the agent (`agents.update {paused}`).
    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        do {
            _ = try await server.setPaused(agentID: agentID, paused)
            failures[.status] = nil
            savedCount += 1
            return true
        } catch {
            failures[.status] = AgentForms.errorText(error)
            return false
        }
    }

    /// Toggles one chip and sends the whole list. The sends go one after another, each with the list as it is then, so
    /// the last answer holds every tap (two quick taps both reach the server).
    func toggleChip(_ capability: AgentCapability) {
        var next = chips
        if next.contains(capability) {
            next.remove(capability)
        } else {
            next.insert(capability)
        }
        chips = next
        chipsInFlight += 1
        let previous = chipChain
        chipChain = Task {
            await previous?.value
            let saved = await save(AgentPatch(capabilities: AgentCapability.wire(next)), in: .capabilities)
            chipsInFlight -= 1
            if !saved, chipsInFlight == 0 {
                chips = serverChips
            }
        }
    }

    /// Moves the agent to another runtime in one patch (`AgentForms.runtimeSwitch`).
    @discardableResult
    func switchRuntime(_ patch: AgentPatch) async -> Bool {
        await save(patch, in: .work)
    }

    /// Switches one schedule on or off (`schedules.update {enabled}`), and keeps the list in step with the answer.
    func setScheduleEnabled(_ id: String, _ enabled: Bool) async {
        do {
            let updated = try await server.setScheduleEnabled(id, enabled)
            replaceSchedule(updated)
            failures[.schedules] = nil
        } catch {
            failures[.schedules] = AgentForms.errorText(error)
            await loadSchedules()
        }
    }

    /// Starts a schedule now (`schedules.run_now`).
    func runScheduleNow(_ id: String) async {
        do {
            try await server.runScheduleNow(id)
            failures[.schedules] = nil
            ranCount += 1
        } catch {
            failures[.schedules] = AgentForms.errorText(error)
        }
    }

    /// Deletes the agent (`agents.delete`). Returns whether it went through; the server model drops the agent then.
    func delete() async -> Bool {
        do {
            try await server.deleteAgent(agentID)
            failures[.delete] = nil
            return true
        } catch {
            failures[.delete] = AgentForms.errorText(error)
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
