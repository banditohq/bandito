import BanditoDesign
import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

@Suite struct CrewOrderTests {
    @Test func leadComesFirstThenPinnedThenTheRest() {
        let ordered = CrewOrder.ordered(["a", "b", "c", "d", "e"], id: { $0 }, lead: "d", pinned: ["c", "a"])
        #expect(ordered == ["d", "a", "c", "b", "e"])
    }

    @Test func withoutALeadOrPinsTheOrderStays() {
        #expect(CrewOrder.ordered(["x", "y", "z"], id: { $0 }, lead: nil, pinned: []) == ["x", "y", "z"])
    }
}

@Suite struct CrewPinsTests {
    @Test func toggleAddsAndRemoves() {
        #expect(CrewPins.toggled("a", in: []) == ["a"])
        #expect(CrewPins.toggled("a", in: ["a", "b"]) == ["b"])
    }

    @Test func pinsAreKeptPerServer() {
        let defaults = UserDefaults(suiteName: "crew.tests.\(UUID().uuidString)")!
        let server = UUID()
        let other = UUID()
        CrewPins.save(["a"], serverID: server, defaults: defaults)
        #expect(CrewPins.load(server, defaults: defaults) == ["a"])
        #expect(CrewPins.load(other, defaults: defaults).isEmpty)
    }
}

@Suite struct CrewPreviewTests {
    @Test func collapsesWhitespaceAndDropsAnEmptyLine() {
        #expect(CrewPreview.line("  Hello\n\n  there \t you ") == "Hello there you")
        #expect(CrewPreview.line("  \n ") == nil)
        #expect(CrewPreview.line(nil) == nil)
    }
}

@Suite struct CrewMoodTests {
    @Test func aPausedAgentSleepsWhateverItDid() {
        #expect(AvatarMood.crew(status: .working, turnRunning: true, paused: true) == .sleeping)
    }

    @Test func waitingAndErrorsShowThrough() {
        #expect(AvatarMood.crew(status: .needsYou, turnRunning: false, paused: false) == .needsYou)
        #expect(AvatarMood.crew(status: .error, turnRunning: false, paused: false) == .error)
        #expect(AvatarMood.crew(status: .offline, turnRunning: false, paused: false) == .sleeping)
    }

    @Test func anIdleAgentWithATurnThinks() {
        #expect(AvatarMood.crew(status: .idle, turnRunning: true, paused: false) == .thinking)
        #expect(AvatarMood.crew(status: .idle, turnRunning: false, paused: false) == .idle)
        #expect(AvatarMood.crew(status: .working, turnRunning: false, paused: false) == .working)
    }
}

@Suite struct CrewLookTests {
    private func agent(avatar: AvatarSpec?) -> Agent {
        var agent = Agent(
            id: "look-1", name: "Forge", role: "Builder", runtime: .claude, cwd: "/tmp", createdAt: 0, updatedAt: 0,
            status: .idle)
        agent.avatar = avatar
        return agent
    }

    @Test func aSavedPaletteColorAndFaceAreUsed() {
        let look = CrewLook(agent: agent(avatar: AvatarSpec(color: "sky", face: "carets")))
        #expect(look.color == .sky)
        #expect(look.face == .carets)
        #expect(look.customHex == nil)
    }

    @Test func aCustomHexIsKeptAsTheTileColor() {
        let look = CrewLook(agent: agent(avatar: AvatarSpec(color: "#33aa66", face: "dots")))
        #expect(look.customHex == "#33AA66")
        #expect(AvatarHex.value("#33AA66") == 0x33AA66)
    }

    @Test func withNothingSavedTheNameDecides() {
        let look = CrewLook(agent: agent(avatar: nil))
        #expect(look.customHex == nil)
        #expect(look == CrewLook(agent: agent(avatar: nil)))
    }
}

@MainActor
@Suite struct CrewFactsTests {
    @Test func theDemoTeamShowsWhatEachAgentWaitsFor() async {
        let server = await IOSDemo.start()
        let rows = CrewFacts.build(server: server, pinned: [])
        #expect(rows.count == IOSDemo.team.count)
        #expect(rows.first { $0.name == "Forge" }?.waiting == .approval(title: "git push origin feat/ios-crew"))
        #expect(rows.first { $0.name == "Watch" }?.waiting == .answer)
        #expect(rows.first { $0.name == "Quill" }?.waiting == nil)
        #expect(rows.first { $0.name == "Scout" }?.waiting == nil)
        await server.disconnect()
    }

    @Test func aPinnedAgentIsMarkedAndMovedUp() async {
        let server = await IOSDemo.start()
        let scout = server.sortedAgents.first { $0.name == "Scout" }!.id
        let rows = CrewFacts.build(server: server, pinned: [scout])
        #expect(rows.first?.id == scout)
        #expect(rows.first?.isPinned == true)
        await server.disconnect()
    }

    @Test func aServerWithoutAgentsHasNoRows() async {
        let server = await IOSDemo.start(withTeam: false)
        #expect(CrewFacts.build(server: server, pinned: []).isEmpty)
        await server.disconnect()
    }

    @Test func theLaunchArgumentForAnEmptyDemoIsRecognised() {
        #expect(IOSDemo.isRequested(in: ["Bandito", "-demo-empty"]))
        #expect(IOSDemo.isEmptyRequested(in: ["Bandito", "-demo-empty"]))
        #expect(!IOSDemo.isEmptyRequested(in: ["Bandito", "-demo"]))
    }

    @Test func theDemoHasTwoServers() async {
        let servers = await IOSDemo.startServers()
        #expect(servers.count == 2)
        #expect(servers.first?.agents.count == IOSDemo.team.count)
        for server in servers { await server.disconnect() }
    }
}
