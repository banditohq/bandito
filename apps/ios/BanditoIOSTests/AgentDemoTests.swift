import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The create, edit and delete flows in the `-demo` world: the demo daemon answers them as a server does, so the card
/// and the sheets work on the simulator without a server.
@MainActor
@Suite struct AgentDemoTests {
    @Test func theDemoServerOffersReadyTeams() async throws {
        let server = await IOSDemo.start()
        #expect(ReadyTeamsLogic.supported(server.supports))
        let bundles = try await server.agentBundles()
        for id in ReadyTeamsLogic.ids {
            #expect(bundles.contains { $0.id == id }, "missing ready team \(id)")
        }
        await server.disconnect()
    }

    @Test func aNewAgentJoinsTheCrewOfTheDemo() async throws {
        let server = await IOSDemo.start()
        let before = server.agents.count
        let made = try await server.createAgent(
            AgentForms.newAgent(
                name: "Ledger", role: "Bookkeeper", runtime: .claude, model: "haiku",
                folder: "/Users/demo/Projects/ledger", approval: .risky, effort: nil, permissions: [.terminal]))
        #expect(server.agents.count == before + 1)
        #expect(server.agents.contains { $0.id == made.id && $0.name == "Ledger" })
        #expect(made.model == "haiku")
        #expect(made.capabilities == ["terminal"])
        await server.disconnect()
    }

    @Test func pausingAndRenamingATeamAgentAreAnsweredByTheDemo() async throws {
        let server = await IOSDemo.start()
        let forge = try #require(server.agents.first { $0.name == "Forge" })
        try await server.setPaused(agentID: forge.id, true)
        #expect(server.agents.first { $0.id == forge.id }?.paused == true)
        let update = try await server.updateAgent(forge.id, patch: AgentPatch(role: "Lead builder"))
        #expect(update.agent.role == "Lead builder")
        #expect(update.agent.name == "Forge")
        await server.disconnect()
    }

    @Test func aDeletedAgentLeavesTheCrewOfTheDemo() async throws {
        let server = await IOSDemo.start()
        let quill = try #require(server.agents.first { $0.name == "Quill" })
        try await server.deleteAgent(quill.id)
        #expect(!server.agents.contains { $0.id == quill.id })
        await server.disconnect()
    }

    @Test func aReadyTeamMakesItsAgentsInOneRequest() async throws {
        let server = await IOSDemo.start()
        let bundles = try await server.agentBundles()
        let bundle = try #require(bundles.first { $0.id == "web-project" })
        let templates = try await server.botTemplates().filter { bundle.templates.contains($0.id) }
        let items = ReadyTeamsLogic.scheduleItems(members: templates, languageCode: "en")
        #expect(items.map(\.key).sorted() == ["code-reviewer:0", "qa-tester:0"])
        // The preview reads the schedules in words, not as cron.
        #expect(items.allSatisfy { !$0.isCron })
        let request = try #require(
            ReadyTeamsLogic.request(
                bundle: bundle, runtime: .claude, languageCode: "en", model: "haiku",
                folder: "/Users/demo/Projects/web", items: items, enabled: ["code-reviewer:0"]))
        let made = try await server.createBundle(request)
        #expect(made.agents.count == 3)
        #expect(made.agents.allSatisfy { $0.agent != nil && $0.error == nil })

        let reviewer = try #require(server.agents.first { $0.name == "Code reviewer" })
        let reviewerSchedules = try await server.schedules(agentId: reviewer.id)
        #expect(reviewerSchedules.map(\.enabled) == [true])
        #expect(reviewer.cwd == "/Users/demo/Projects/web")

        let tester = try #require(server.agents.first { $0.name == "QA tester" })
        let testerSchedules = try await server.schedules(agentId: tester.id)
        #expect(testerSchedules.map(\.enabled) == [false])
        await server.disconnect()
    }

    @Test func theScheduleOfTheDemoAgentCanBeSwitchedAndStarted() async throws {
        let server = await IOSDemo.start()
        let watch = try #require(server.agents.first { $0.name == "Watch" })
        let schedules = try await server.schedules(agentId: watch.id)
        #expect(schedules.count == 2)
        let nightly = try #require(schedules.first { $0.title == "Nightly disk check" })
        #expect(nightly.enabled)
        let switched = try await server.updateSchedule(nightly.id, enabled: false)
        #expect(!switched.enabled)
        try await server.runScheduleNow(nightly.id)
        await server.disconnect()
    }
}
