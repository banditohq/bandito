import BanditoKit
import Foundation
import Testing

@testable import Bandito

/// What the account hands this iPhone ends up in the list of servers, like a scanned QR code does.
@MainActor
@Suite struct AccountAccessSessionTests {
    static let sid = "abcdefghijklmnopqrstuvwxyz"
    static let nk = Base64URL.encode(Data((0..<32).map { UInt8($0 + 1) }))
    static let phone = SyncedPhone(sid: sid, relayHost: "relay.bandito.dev", nk: nk)

    func make() -> (ServerSession, MemorySecrets, ServerAccessSink, ServerNoiseKeyStore) {
        let store = ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: UserDefaults(suiteName: "ios-access-\(UUID().uuidString)")!)
        let secrets = MemorySecrets()
        let session = ServerSession(store: store, secrets: secrets, connect: { _ in })
        session.forgetCursor = { _ in }
        let noiseKeys = ServerNoiseKeyStore(secrets: MemorySecretStore())
        let access = AccessSession(
            add: { try session.add($0) }, holds: { session.holds(serverID: $0, phone: $1) })
        let sink = AccountAccessSink(
            secrets: MemorySecretStore(),
            file: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/access.json"),
            session: access, noiseKeys: noiseKeys)
        return (session, secrets, sink, noiseKeys)
    }

    @Test func anAccessBecomesAServerWithTheAccountsIdItsTokenAndTheKeyMadeForTheRequest() async throws {
        let (session, secrets, sink, noiseKeys) = make()
        let id = UUID()
        try await sink.receive(ServerAccess(serverID: id, name: "Studio", phone: Self.phone, deviceToken: "bdt_issued"))
        let server = try #require(session.servers.first)
        #expect(server.id == id && server.config.name == "Studio")
        #expect(server.config.token == "bdt_issued")
        #expect(server.config.endpoint.relayPart?.route.sid == Self.sid)
        // The key is the one the request carried (the daemon pinned its public half), kept in the Keychain beside the token.
        let key = try noiseKeys.privateKey(for: id)
        #expect(server.config.noiseSecret == Base64URL.encode(key))
        let saved = try #require(try secrets.load(account: ServerSession.noiseAccount(id)))
        #expect(String(decoding: saved, as: UTF8.self) == Base64URL.encode(key))
        #expect(try secrets.load(account: id.uuidString) != nil)
        #expect(await sink.hasAccess(serverID: id))
    }

    @Test func theSameDaemonUnderAnotherIdCountsAsHeldAndAnUnknownOneDoesNot() async throws {
        let (session, _, sink, _) = make()
        let own = ServerConfig(
            name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk),
            token: "t", noiseSecret: Base64URL.encode(Data(repeating: 1, count: 32)))
        try session.add(own)
        let other = UUID()
        #expect(await sink.hasAccess(serverID: other, phone: Self.phone), "paired by QR here before the account knew it")
        #expect(await sink.hasAccess(serverID: other, phone: SyncedPhone(sid: Self.sid, relayHost: "r", nk: Base64URL.encode(Data(repeating: 9, count: 32)))) == false)
        #expect(await sink.hasAccess(serverID: other) == false)
    }

    @Test func aServerThatCannotBeAddedKeepsNothingAndIsTriedAgain() async throws {
        let (session, secrets, sink, _) = make()
        let id = UUID()
        secrets.failingAccounts = [ServerSession.noiseAccount(id)]
        await #expect(throws: (any Error).self) {
            try await sink.receive(ServerAccess(serverID: id, name: "Studio", phone: Self.phone, deviceToken: "bdt_issued"))
        }
        #expect(session.servers.isEmpty && secrets.count == 0)
        secrets.failingAccounts = []
        try await sink.receive(ServerAccess(serverID: id, name: "Studio", phone: Self.phone, deviceToken: "bdt_issued"))
        #expect(session.servers.count == 1)
    }

    @Test func aRecordWithNoUsableWayInIsRefused() async throws {
        let (session, _, sink, _) = make()
        await #expect(throws: (any Error).self) {
            try await sink.receive(ServerAccess(serverID: UUID(), name: "x", phone: SyncedPhone(), deviceToken: "t"))
        }
        #expect(session.servers.isEmpty)
    }

    @Test func aServerThePersonDisconnectedIsToldToTheAccountAndAddingItAgainLiftsTheMark() async throws {
        let (session, _, sink, _) = make()
        let hidden = DismissedServers(defaults: UserDefaults(suiteName: "ios-hidden-\(UUID().uuidString)")!)
        let account = IOSAccount.preview(stage: .ready, dismissed: hidden)
        session.onForgotten = { account.dismiss($0) }
        session.onAdded = { account.lift($0) }
        let id = UUID()
        try await sink.receive(ServerAccess(serverID: id, name: "Studio", phone: Self.phone, deviceToken: "bdt_issued"))
        #expect(account.hiddenCount == 0, "adding a server hides nothing")
        session.revokeSelf = { _ in true }
        #expect(await session.disconnect(id) == .removed(revokedOnServer: true))
        #expect(session.servers.isEmpty)
        #expect(account.hiddenCount == 1)
        #expect(hidden.contains(accountID: "preview", serverID: id, phone: nil))
        #expect(hidden.contains(accountID: "preview", serverID: UUID(), phone: Self.phone), "the same daemon by another id")
        // The same daemon scanned later under another id lifts the mark (the id of the account's entry differs).
        let scanned = ServerConfig(
            name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk),
            token: "t2", noiseSecret: Base64URL.encode(Data(repeating: 1, count: 32)))
        try session.add(scanned)
        #expect(account.hiddenCount == 0)
    }

    @Test func showingHiddenServersClearsThemAndAnotherAccountStartsWithNone() throws {
        let hidden = DismissedServers(defaults: UserDefaults(suiteName: "ios-hidden-\(UUID().uuidString)")!)
        let account = IOSAccount.preview(stage: .ready, dismissed: hidden)
        let config = ServerConfig(
            name: "Studio", endpoint: .reachable(hosts: [], fingerprint: nil, relay: RelayRoute(host: "relay.bandito.dev", sid: Self.sid), noiseKey: Self.nk),
            token: "t")
        account.dismiss(config)
        #expect(account.hiddenCount == 1 && hidden.count(accountID: "other") == 0)
        account.showHiddenServers()
        #expect(account.hiddenCount == 0 && hidden.count(accountID: "preview") == 0)
    }
}
