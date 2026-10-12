import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The agent card: each change goes to the RPC of its field, with only that field in the patch. A fake server records
/// the calls, so the test holds what the card sends without a daemon.
@MainActor
@Suite struct AgentCardTests {
    @Test func saveSendsOnlyTheChangedField() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Forge", role: "Builder")])
        let card = AgentDetailModel(server: fake, agentID: "a1")
        let saved = await card.save(AgentPatch(role: "Reviewer"))
        #expect(saved)
        #expect(fake.calls == ["update a1"])
        let body = try wire(fake.patches[0])
        #expect(body.keys.sorted() == ["role"])
        #expect(body["role"] as? String == "Reviewer")
        #expect(card.savedCount == 1)
        #expect(card.failure == nil)
    }

    @Test func pauseAndResumeUseThePausedField() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Forge", role: "Builder")])
        let card = AgentDetailModel(server: fake, agentID: "a1")
        await card.setPaused(true)
        await card.setPaused(false)
        #expect(fake.calls == ["pause a1 true", "pause a1 false"])
    }

    @Test func aChangedRuntimeGoesAsTheRuntimeField() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Forge", role: "Builder")])
        let card = AgentDetailModel(server: fake, agentID: "a1")
        await card.save(AgentPatch(runtime: .codex))
        let body = try wire(fake.patches[0])
        #expect(body["runtime"] as? String == "codex")
        #expect(body.keys.sorted() == ["runtime"])
    }

    @Test func aFailureIsKeptAndTheSaveIsNotCounted() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Forge", role: "Builder")])
        fake.error = RPCError(code: -32000, message: "the daemon refused")
        let card = AgentDetailModel(server: fake, agentID: "a1")
        let saved = await card.save(AgentPatch(approvalMode: .never))
        #expect(!saved)
        #expect(card.failure == "the daemon refused")
        #expect(card.savedCount == 0)
    }

    @Test func aScheduleSwitchUpdatesOnlyThatSchedule() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Watch", role: "On call")])
        fake.schedules = [try schedule(id: "s1", enabled: true), try schedule(id: "s2", enabled: false)]
        let card = AgentDetailModel(server: fake, agentID: "a1")
        await card.loadSchedules()
        await card.setScheduleEnabled("s1", false)
        #expect(fake.calls.last == "schedule s1 false")
        #expect(card.schedules.map(\.enabled) == [false, false])
        #expect(card.schedules.map(\.id) == ["s1", "s2"])
    }

    @Test func runNowStartsTheScheduleByItsID() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Watch", role: "On call")])
        let card = AgentDetailModel(server: fake, agentID: "a1")
        await card.runScheduleNow("s2")
        #expect(fake.calls == ["run s2"])
        #expect(card.ranCount == 1)
    }

    @Test func deleteCallsTheServerOnce() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Quill", role: "Docs")])
        let card = AgentDetailModel(server: fake, agentID: "a1")
        let deleted = await card.delete()
        #expect(deleted)
        #expect(fake.calls == ["delete a1"])
    }

    @Test func aFailedDeleteKeepsTheAgent() async throws {
        let fake = FakeAgentServer(agents: [agent(name: "Quill", role: "Docs")])
        fake.error = RPCError(code: -32000, message: "busy")
        let card = AgentDetailModel(server: fake, agentID: "a1")
        let deleted = await card.delete()
        #expect(!deleted)
        #expect(card.failure == "busy")
    }

    @Test func identityPatchHoldsOnlyTheFieldsThatChanged() throws {
        let current = agent(name: "Forge", role: "Builder")
        #expect(AgentEdit.identity(name: "Forge", role: "Builder", current: current) == nil)
        #expect(AgentEdit.identity(name: " ", role: "Builder", current: current) == nil)
        let renamed = try #require(AgentEdit.identity(name: "Forge 2", role: "Builder", current: current))
        let body = try wire(renamed)
        #expect(body.keys.sorted() == ["name"])
        let roleOnly = try #require(AgentEdit.identity(name: "Forge", role: "", current: current))
        #expect(try wire(roleOnly).keys.sorted() == ["role"])
    }

    @Test func clearingTheModelSendsNull() throws {
        let body = try wire(AgentEdit.model(nil))
        #expect(body.keys.sorted() == ["model"])
        #expect(body["model"] is NSNull)
        let picked = try wire(AgentEdit.model("haiku"))
        #expect(picked["model"] as? String == "haiku")
    }

    // MARK: fixtures

    private func agent(name: String, role: String) -> Agent {
        Agent(id: "a1", name: name, role: role, runtime: .claude, cwd: "/Users/demo/Projects/site")
    }

    private func schedule(id: String, enabled: Bool) throws -> Schedule {
        let json = """
            {"id":"\(id)","agent_id":"a1","cron":"0 9 * * *","tz":"UTC","prompt":"Check it.",
             "enabled":\(enabled),"created_at":1}
            """
        return try JSONDecoder.wire.decode(Schedule.self, from: Data(json.utf8))
    }

    /// The request body as the RPC client sends it.
    private func wire<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder.wire.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// A server that records the card's calls. It answers with the agent it holds, as the daemon does.
@MainActor
final class FakeAgentServer: AgentEditingServer {
    var agents: [Agent]
    var schedules: [Schedule] = []
    /// Set to make the next call fail.
    var error: Error?
    private(set) var calls: [String] = []
    private(set) var patches: [AgentPatch] = []

    init(agents: [Agent]) {
        self.agents = agents
    }

    func updateAgent(_ id: String, patch: AgentPatch) async throws -> AgentUpdate {
        calls.append("update \(id)")
        patches.append(patch)
        if let error { throw error }
        var agent = agents[0]
        if let role = patch.role { agent.role = role }
        if let name = patch.name { agent.name = name }
        if let runtime = patch.runtime { agent.runtime = runtime }
        return try agentUpdate(agent)
    }

    func setPaused(agentID: String, _ paused: Bool) async throws -> Agent {
        calls.append("pause \(agentID) \(paused)")
        if let error { throw error }
        var agent = agents[0]
        agent.paused = paused
        return agent
    }

    func deleteAgent(_ id: String) async throws {
        calls.append("delete \(id)")
        if let error { throw error }
    }

    func schedules(agentId: String?) async throws -> [Schedule] {
        schedules
    }

    func setScheduleEnabled(_ id: String, _ enabled: Bool) async throws -> Schedule {
        calls.append("schedule \(id) \(enabled)")
        if let error { throw error }
        guard let index = schedules.firstIndex(where: { $0.id == id }) else {
            throw RPCError(code: -32004, message: "no schedule")
        }
        schedules[index].enabled = enabled
        return schedules[index]
    }

    func runScheduleNow(_ id: String) async throws {
        calls.append("run \(id)")
        if let error { throw error }
    }

    /// The daemon's answer to `agents.update`: the agent's fields, with the warnings beside them (not nested).
    private func agentUpdate(_ agent: Agent) throws -> AgentUpdate {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.wire.encode(agent)) as? [String: Any])
        object["warnings"] = [String]()
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.wire.decode(AgentUpdate.self, from: data)
    }
}
