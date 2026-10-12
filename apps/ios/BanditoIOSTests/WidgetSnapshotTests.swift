import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The snapshot the widgets read: its file format, the rule "write only when it changed", the four agents, the links.
@Suite struct WidgetSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func agent(_ id: String, _ status: WidgetStatus, server: String = "S1") -> WidgetSnapshot.Agent {
        WidgetSnapshot.Agent(server: server, id: id, name: id.capitalized, status: status, mood: .idle)
    }

    @Test func encodesTheFieldsTheWidgetsReadAndNothingElse() throws {
        let snapshot = WidgetSnapshot(
            generatedAt: now, pending: 2,
            agents: [WidgetSnapshot.Agent(server: "S1", id: "forge", name: "Forge", status: .needsYou, mood: .needsYou)])
        let json = try #require(String(data: snapshot.encoded(), encoding: .utf8))
        for key in ["\"generatedAt\"", "\"pending\"", "\"agents\"", "\"server\"", "\"id\"", "\"name\"", "\"status\"", "\"mood\""] {
            #expect(json.contains(key), "the file has \(key)")
        }
        // No address and no token can be in it: the file holds only ids, names and states.
        for word in ["http", "token", "address", "host", "port", "secret"] {
            #expect(!json.lowercased().contains(word), "the file never holds \(word)")
        }
    }

    @Test func roundTripsThroughTheFile() throws {
        let snapshot = WidgetSnapshot(
            generatedAt: now, pending: 3,
            agents: [agent("forge", .working), agent("watch", .needsYou), agent("quill", .error)])
        let decoded = try WidgetSnapshot.decoded(from: snapshot.encoded())
        #expect(decoded == snapshot)
        #expect(decoded.generatedAt == now)
    }

    @Test func decodingRejectsAnotherFormat() {
        #expect(throws: (any Error).self) {
            _ = try WidgetSnapshot.decoded(from: Data("{\"pending\":\"many\"}".utf8))
        }
    }

    @Test func aSnapshotHoldsAtMostFourAgentsAndNoNegativeCount() {
        let six = (1...6).map { agent("a\($0)", .idle) }
        let snapshot = WidgetSnapshot(generatedAt: now, pending: -4, agents: six)
        #expect(snapshot.agents.count == WidgetSnapshot.agentLimit)
        #expect(snapshot.agents.map(\.id) == ["a1", "a2", "a3", "a4"])
        #expect(snapshot.pending == 0)
    }

    @Test func theSameContentIsNotWrittenAgainWhateverTheTime() {
        let first = WidgetSnapshot(generatedAt: now, pending: 1, agents: [agent("forge", .working)])
        let later = WidgetSnapshot(generatedAt: now.addingTimeInterval(600), pending: 1, agents: [agent("forge", .working)])
        #expect(first.hasSameContent(as: later))
        #expect(first != later, "the time is part of the file, only not of the content")
    }

    @Test func aChangedCountOrStatusIsANewContent() {
        let base = WidgetSnapshot(generatedAt: now, pending: 1, agents: [agent("forge", .working)])
        let moreWaiting = WidgetSnapshot(generatedAt: now, pending: 2, agents: [agent("forge", .working)])
        let stateChanged = WidgetSnapshot(generatedAt: now, pending: 1, agents: [agent("forge", .idle)])
        #expect(!base.hasSameContent(as: moreWaiting))
        #expect(!base.hasSameContent(as: stateChanged))
    }

    @Test func theCrewShowsWaitingFirstThenWorkingThenTheRest() {
        let team = [
            agent("quill", .idle), agent("forge", .working), agent("watch", .needsYou),
            agent("scout", .error), agent("pilot", .needsYou), agent("bolt", .working),
        ]
        let picked = WidgetAgentPicker.pick(team)
        #expect(picked.map(\.id) == ["watch", "pilot", "forge", "bolt"])
    }

    @Test func insideAGroupTheTeamsOrderStays() {
        let team = [agent("b", .idle), agent("a", .idle), agent("c", .offline), agent("d", .idle)]
        #expect(WidgetAgentPicker.pick(team, limit: 3).map(\.id) == ["b", "a", "c"])
    }

    @Test func aSmallTeamIsShownWhole() {
        let team = [agent("forge", .working)]
        #expect(WidgetAgentPicker.pick(team) == team)
        #expect(WidgetAgentPicker.pick([]).isEmpty)
    }

    @Test func theLinksOpenTheInboxTheCrewAndAnAgent() throws {
        #expect(BanditoLink(url: try #require(URL(string: "bandito://inbox"))) == .inbox)
        #expect(BanditoLink(url: try #require(URL(string: "bandito://crew"))) == .crew)
        let agentURL = try #require(URL(string: "bandito://agent/6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B/forge"))
        #expect(BanditoLink(url: agentURL) == .agent(server: "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B", id: "forge"))
    }

    @Test func aLinkBuiltByTheWidgetIsReadBack() {
        let link = BanditoLink.agent(server: "6F0B2C1E-8D7A-4C3B-9A51-0B1D2E3F4A5B", id: "scout one")
        #expect(BanditoLink(url: link.url) == link)
        #expect(BanditoLink(url: BanditoLink.inbox.url) == .inbox)
        #expect(BanditoLink(url: BanditoLink.crew.url) == .crew)
    }

    @Test func otherURLsAreNotOurLinks() throws {
        for text in [
            "https://bandito.dev/inbox", "bandito://pair?code=1", "bandito://settings", "bandito://agent",
            "bandito://agent/only-server", "bandito://agent/a/b/c", "bandito://agent//forge",
        ] {
            #expect(BanditoLink(url: try #require(URL(string: text))) == nil, "\(text) is not a widget link")
        }
    }
}

/// The file the app writes for the widgets: read back, written only when it changed, reloads the widgets once per write.
@MainActor
@Suite struct WidgetSnapshotWriterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A store in a folder of its own, under the test's temporary folder.
    private func makeStore() throws -> WidgetSnapshotStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return WidgetSnapshotStore(fileURL: folder.appendingPathComponent(WidgetAppGroup.snapshotFileName))
    }

    private func snapshot(pending: Int, at time: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: time, pending: pending,
            agents: [WidgetSnapshot.Agent(server: "S1", id: "forge", name: "Forge", status: .working, mood: .working)])
    }

    @Test func aMissingFileReadsAsNoSnapshot() throws {
        #expect(try makeStore().read() == nil)
    }

    @Test func theFirstSnapshotIsWrittenAndReadBack() throws {
        let store = try makeStore()
        var reloads = 0
        let writer = WidgetSnapshotWriter(store: store, reload: { reloads += 1 })
        let first = snapshot(pending: 2, at: now)
        #expect(writer.commitIfChanged(first))
        #expect(store.read() == first)
        #expect(reloads == 1)
    }

    @Test func anUnchangedPictureIsNotWrittenAgain() throws {
        let store = try makeStore()
        var reloads = 0
        let writer = WidgetSnapshotWriter(store: store, reload: { reloads += 1 })
        #expect(writer.commitIfChanged(snapshot(pending: 2, at: now)))
        #expect(!writer.commitIfChanged(snapshot(pending: 2, at: now.addingTimeInterval(60))))
        #expect(reloads == 1, "the widgets reload once, for the change")
    }

    @Test func aChangeIsWrittenAndTheWidgetsReload() throws {
        let store = try makeStore()
        var reloads = 0
        let writer = WidgetSnapshotWriter(store: store, reload: { reloads += 1 })
        _ = writer.commitIfChanged(snapshot(pending: 2, at: now))
        #expect(writer.commitIfChanged(snapshot(pending: 3, at: now.addingTimeInterval(5))))
        #expect(store.read()?.pending == 3)
        #expect(reloads == 2)
    }

    @Test func aStartedWriterKnowsWhatTheFileAlreadyHolds() throws {
        let store = try makeStore()
        _ = WidgetSnapshotWriter(store: store, reload: {}).commitIfChanged(snapshot(pending: 2, at: now))
        var reloads = 0
        let restarted = WidgetSnapshotWriter(store: store, reload: { reloads += 1 })
        #expect(!restarted.commitIfChanged(snapshot(pending: 2, at: now.addingTimeInterval(9))))
        #expect(reloads == 0, "the same picture after a restart is not written, so the widgets are not reloaded")
    }

    @Test func withoutAppGroupNothingIsWrittenOrReloaded() {
        var reloads = 0
        let writer = WidgetSnapshotWriter(store: nil, reload: { reloads += 1 })
        #expect(!writer.commitIfChanged(snapshot(pending: 1, at: now)))
        #expect(reloads == 0)
    }
}
