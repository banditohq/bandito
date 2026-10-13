import BanditoKit
import Foundation
import Testing

@testable import Bandito

@Suite struct AccountAccessSinkTests {
    private let serverID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private let phone = SyncedPhone(sid: "S1", relayHost: "relay.bandito.dev", nk: "NK")

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "access-\(UUID().uuidString)/account-access.v1.json")
    }

    private func access(token: String = "bdt_one") -> ServerAccess {
        ServerAccess(serverID: serverID, name: "vps", phone: phone, deviceToken: token)
    }

    @Test func aReceivedAccessKeepsTheTokenInTheSecretStoreAndTheRecordInAFile() async throws {
        let secrets = MemorySecretStore()
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let sink = AccountAccessSink(secrets: secrets, file: file)
        #expect(await sink.hasAccess(serverID: serverID) == false)

        try await sink.receive(access())

        #expect(await sink.hasAccess(serverID: serverID))
        #expect(await sink.token(for: serverID) == "bdt_one")
        // The file never holds the token.
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains("bdt_one") && text.contains("relay.bandito.dev"))
        // A new sink over the same files sees it (a relaunch).
        let again = AccountAccessSink(secrets: secrets, file: file)
        #expect(await again.hasAccess(serverID: serverID))
        #expect(await again.all().map(\.name) == ["vps"])
    }

    @Test func aSecondAccessForTheSameServerReplacesTheFirst() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let sink = AccountAccessSink(secrets: MemorySecretStore(), file: file)
        try await sink.receive(access(token: "bdt_one"))
        try await sink.receive(access(token: "bdt_two"))
        #expect(await sink.all().count == 1)
        #expect(await sink.token(for: serverID) == "bdt_two")
    }

    @Test func aRecordThatCannotBeWrittenLeavesNoTokenBehind() async throws {
        let secrets = MemorySecretStore()
        // The folder of the file is a regular file: nothing can be written under it.
        let blocker = FileManager.default.temporaryDirectory.appending(path: "blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let sink = AccountAccessSink(secrets: secrets, file: blocker.appending(path: "access.json"))

        await #expect(throws: (any Error).self) { try await sink.receive(access()) }

        #expect(await sink.hasAccess(serverID: serverID) == false)
        #expect(try secrets.load(account: AccountAccessSink.tokenAccount(serverID)) == nil)
    }

    @Test func removingAServerForgetsItsTokenAndRecord() async throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let sink = AccountAccessSink(secrets: MemorySecretStore(), file: file)
        try await sink.receive(access())
        try await sink.remove(serverID: serverID)
        #expect(await sink.hasAccess(serverID: serverID) == false)
        #expect(await sink.all().isEmpty)
    }

    @Test func aRecordWithoutItsTokenIsNotAccess() async throws {
        let secrets = MemorySecretStore()
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let sink = AccountAccessSink(secrets: secrets, file: file)
        try await sink.receive(access())
        try secrets.save(nil, account: AccountAccessSink.tokenAccount(serverID))
        #expect(await sink.hasAccess(serverID: serverID) == false)
    }
}
