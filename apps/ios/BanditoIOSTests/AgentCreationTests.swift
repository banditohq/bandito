import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// A server that makes what the creation asks for and records it. A template in `bundleFailingTemplates` gets an error
/// and no agent; `createAgentFailures` makes the next single-agent requests fail first.
@MainActor
final class FakeAgentMaker: AgentMaking {
    private(set) var agents: [Agent] = []
    private(set) var folderCalls: [String] = []
    private(set) var bundleRequests: [NewBundle] = []
    private(set) var readCount = 0
    var bundleFailingTemplates: Set<String> = []
    var createAgentFailures = 0

    func makeFreeFolder(root: String, base: String) async throws -> String {
        folderCalls.append(base)
        return "\(root)/\(base)"
    }

    func createAgent(_ new: NewAgent) async throws -> Agent {
        if createAgentFailures > 0 {
            createAgentFailures -= 1
            throw RPCError(code: -32000, message: "the daemon refused")
        }
        let agent = Agent(id: "made-\(agents.count + 1)", name: new.name, role: new.role, runtime: new.runtime, cwd: new.cwd)
        agents.append(agent)
        return agent
    }

    func createBundle(_ new: NewBundle) async throws -> BundleCreation {
        bundleRequests.append(new)
        var entries: [BundleEntry] = []
        for templateID in new.templates ?? [] {
            if bundleFailingTemplates.contains(templateID) {
                entries.append(BundleEntry(templateId: templateID, agent: nil, error: "the agent could not be made"))
                continue
            }
            let agent = Agent(
                id: "bundle-\(agents.count + 1)", name: templateID, runtime: .claude, cwd: new.cwd ?? "/",
                templateId: templateID)
            agents.append(agent)
            entries.append(BundleEntry(templateId: templateID, agent: agent))
        }
        return BundleCreation(agents: entries)
    }

    func readAgentsNow() async throws {
        readCount += 1
    }
}

/// The retries of the creation sheets: a failed part is retried without making again what was made, and the folder is
/// made once and kept.
@MainActor
@Suite struct AgentCreationTests {
    @Test func aRetryOfATeamMakesOnlyTheMissingAgentsInOneFolder() async throws {
        let demo = await IOSDemo.start()
        defer { Task { await demo.disconnect() } }
        let bundle = try #require(try await demo.agentBundles().first { $0.id == "web-project" })
        let members = try await demo.botTemplates().filter { bundle.templates.contains($0.id) }
        #expect(members.count == 3)
        let second = members[1].id

        let fake = FakeAgentMaker()
        fake.bundleFailingTemplates = [second]
        let team = TeamCreationModel(
            server: fake, bundle: bundle, members: members, root: "/Users/demo", runtime: .claude, model: "haiku",
            languageCode: "en")

        let first = await team.create(items: [], enabled: [])
        #expect(!first)
        #expect(team.failure != nil)
        #expect(team.madeTemplateIDs == [members[0].id, members[2].id])

        fake.bundleFailingTemplates = []
        let retry = await team.create(items: [], enabled: [])
        #expect(retry)
        #expect(team.failure == nil)
        // One folder, made by the first attempt; the retry asks only for the agent still missing.
        #expect(fake.folderCalls == ["Web project"])
        #expect(fake.bundleRequests.count == 2)
        #expect(fake.bundleRequests[1].templates == [second])
        #expect(fake.agents.count == 3)
    }

    @Test func aRetryOfOneAgentKeepsItsFolder() async {
        let fake = FakeAgentMaker()
        fake.createAgentFailures = 1
        let creation = OneAgentCreation(server: fake, root: "/Users/demo", base: "Ledger")
        let build: (String) -> NewAgent = { folder in
            AgentForms.newAgent(
                name: "Ledger", role: "", runtime: .claude, model: nil, folder: folder, approval: .risky,
                effort: nil, permissions: [])
        }

        let first = await creation.create(build: build)
        #expect(!first)
        #expect(creation.failure != nil)
        #expect(fake.agents.isEmpty)

        let retry = await creation.create(build: build)
        #expect(retry)
        #expect(fake.folderCalls == ["Ledger"])
        #expect(fake.agents.count == 1)
        #expect(fake.agents.first?.cwd == "/Users/demo/Ledger")
    }
}
