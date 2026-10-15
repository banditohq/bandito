import BanditoKit
import Foundation
import Testing

@testable import Bandito

@Suite struct AgentListCacheTests {
    private func cache() -> AgentListCache {
        AgentListCache(directory: FileManager.default.temporaryDirectory.appending(path: "agent-cache-\(UUID().uuidString)"))
    }

    private func agent(_ id: String) -> Agent {
        Agent(id: id, name: "Forge \(id)", runtime: .claude, cwd: "/work")
    }

    @Test func savedListComesBack() {
        let cache = cache()
        let id = UUID()
        cache.save([agent("a"), agent("b")], serverID: id)
        #expect(cache.load(serverID: id)?.map(\.id) == ["a", "b"])
        #expect(cache.load(serverID: UUID()) == nil)
    }

    @Test func missingFileIsNil() {
        #expect(cache().load(serverID: UUID()) == nil)
    }

    @Test func brokenFileIsNilAndRemoved() throws {
        let cache = cache()
        let id = UUID()
        cache.save([agent("a")], serverID: id)
        let url = cache.directory.appending(path: "\(id.uuidString).json")
        try Data("[{\"old\":1}]".utf8).write(to: url)
        #expect(cache.load(serverID: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func removeDeletesTheFile() {
        let cache = cache()
        let id = UUID()
        cache.save([agent("a")], serverID: id)
        cache.remove(serverID: id)
        #expect(cache.load(serverID: id) == nil)
    }
}

@Suite struct CrewConnectionNoticeTests {
    private func notice(_ state: ConnectionState, cache: Bool = false, disabled: Bool = false) -> CrewConnectionNotice {
        CrewFacts.notice(state: state, fromCache: cache, disabled: disabled)
    }

    @Test func connectedSaysNothing() {
        #expect(notice(.connected) == .none)
        #expect(notice(.connected, cache: true) == .none)
    }

    @Test func connectingWithNothingToShowIsConnecting() {
        #expect(notice(.connecting) == .connecting)
        // The state before `connect()` runs, at every launch.
        #expect(notice(.disconnected) == .connecting)
    }

    @Test func aLaunchWithASavedListShowsItQuietly() {
        // No "Offline" flash for the half second every launch takes to connect.
        #expect(notice(.connecting, cache: true) == .none)
        #expect(notice(.disconnected, cache: true) == .none)
    }

    @Test func aRetryOfAnEmptyTeamSaysConnectingNotCreateAnAgent() {
        // The list was read once (empty) and the link dropped: "Try again" connects, the screen says so.
        #expect(notice(.connecting) == .connecting)
    }

    @Test func aServerSwitchedOffIsOfflineNotConnectingForEver() {
        #expect(notice(.disconnected, disabled: true) == .offline)
        #expect(notice(.disconnected, cache: true, disabled: true) == .offlineWithCache)
    }

    @Test func aLostLinkWithASavedListIsOfflineWithCache() {
        #expect(notice(.reconnecting(attempt: 1), cache: true) == .offlineWithCache)
        #expect(notice(.failed(.noAnswer), cache: true) == .offlineWithCache)
    }

    @Test func otherwiseNotConnectedIsOffline() {
        #expect(notice(.reconnecting(attempt: 2)) == .offline)
        #expect(notice(.failed(.noAnswer)) == .offline)
    }
}

@MainActor
@Suite struct ServerSessionCacheTests {
    private func session(cache: AgentListCache) -> ServerSession {
        let store = ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: UserDefaults(suiteName: "ios-offline-\(UUID().uuidString)")!)
        let session = ServerSession(store: store, secrets: MemorySecrets(), connect: { _ in }, cache: cache)
        session.forgetCursor = { _ in }
        return session
    }

    private func config() -> ServerConfig {
        ServerConfig(name: "Mac", endpoint: .direct(hosts: ["10.0.0.2:7879"], fingerprint: ConnectTests.fp), token: "tok")
    }

    private func tempCache() -> AgentListCache {
        AgentListCache(directory: FileManager.default.temporaryDirectory.appending(path: "agent-cache-\(UUID().uuidString)"))
    }

    @Test func aStartTakesTheSavedAgentsAndForgettingRemovesThem() throws {
        let cache = tempCache()
        let first = session(cache: cache)
        let added = config()
        try first.add(added)
        let id = try #require(first.servers.first?.id)
        cache.save([Agent(id: "a", name: "Forge", runtime: .claude, cwd: "/work")], serverID: id)

        // A new session over the same cache: the model starts with the saved team, still unread.
        let second = session(cache: cache)
        var again = added
        again.id = id
        try second.add(again)
        let model = try #require(second.servers.first)
        #expect(model.agents.map(\.id) == ["a"])
        #expect(model.agentsFromCache)
        #expect(model.agentsReadAt == nil)

        second.remove(id)
        #expect(cache.load(serverID: id) == nil)
    }
}
