import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

// A server that refuses this Mac's key: the words and button the notice shows, and the repair of this Mac's own
// server. The bandito runner and the redeem are stubs; the Keychain is replaced by a recorder.

private struct HealthyDaemon: CommandRunner {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        if arguments.contains("info") {
            return CommandResult(status: 0, stdout: #"{"listen":"127.0.0.1:17781","running":true}"#, stderr: "")
        }
        if arguments.contains("pair") {
            return CommandResult(status: 0, stdout: #"{"code":"sunset-orbit","expires_in_ms":600000}"#, stderr: "")
        }
        return CommandResult(status: 1, stdout: "", stderr: "unknown")
    }
}

private struct StoppedDaemon: CommandRunner {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: "daemon is not running")
    }
}

private final class Tokens: @unchecked Sendable {
    // @unchecked: the repair calls it on the main actor only.
    var stored: [UUID: String] = [:]
    var revoked: [String] = []
}

private let storeKey = "servers.v1"

@MainActor
@Suite(.serialized) struct KeyRepairFlowTests {
    private let id = UUID()
    private let oldURL = URL(string: "ws://127.0.0.1:17777/v1/rpc")!

    private func thisMac() -> ServerConfig {
        ServerConfig(id: id, name: "This Mac", endpoint: .webSocket(url: oldURL), token: "old", isThisMac: true)
    }

    private func pairing(_ runner: CommandRunner, token: String = "bdt_new") -> LocalDaemonPairing {
        LocalDaemonPairing(
            runner: runner, binary: URL(fileURLWithPath: "/bin/bandito"),
            redeem: { _, _, _ in
                try RPCClient.decoder.decode(
                    PairResult.self,
                    from: Data(#"{"token":"\#(token)","device":{"id":"dev-9","name":"n","created_at":1}}"#.utf8))
            })
    }

    /// An AppModel that holds `config`, with the saved list restored afterwards.
    private func withApp(_ config: ServerConfig, _ body: (AppModel) async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: storeKey)
        defaults.set(try! JSONEncoder().encode([config]), forKey: storeKey)
        defer {
            if let previous { defaults.set(previous, forKey: storeKey) } else { defaults.removeObject(forKey: storeKey) }
        }
        try await body(AppModel())
    }

    // MARK: words and button

    @Test func thisMacOffersPairingAgain() {
        let content = KeyRejectedContent.make(for: thisMac(), repair: nil, isQA: false)
        #expect(content.message.text == L10n.Failure.keyRejectedThisMac)
        #expect(content.button == .repairThisMac)
        #expect(!content.busy)
    }

    @Test func aRepairInProgressShowsNoButton() {
        let content = KeyRejectedContent.make(for: thisMac(), repair: .repairing, isQA: false)
        #expect(content.busy)
        #expect(content.button == nil)
        #expect(content.message.text == L10n.Failure.keyRepairing)
    }

    @Test func aFailedRepairKeepsItsMessageAndTheButton() {
        let failure = UserFacingMessage(text: L10n.Failure.keyRepairFailed, technical: "daemon is not running")
        let content = KeyRejectedContent.make(for: thisMac(), repair: .failed(failure), isQA: false)
        #expect(content.message == failure)
        #expect(content.button == .repairThisMac)
    }

    @Test func aRemoteServerSaysTheServerDidNotAcceptTheKey() {
        let remote = ServerConfig(
            name: "srv", endpoint: .webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!), token: "t")
        let content = KeyRejectedContent.make(for: remote, repair: nil, isQA: false)
        #expect(content.message.text == L10n.Failure.keyRejected)
        #expect(content.button == .addServer(address: "srv.example.ts.net"))
        // Not the "server does not respond" text, and no retry: retrying cannot help.
        #expect(content.message.text != L10n.Failure.noAnswer)
        #expect(!content.message.canRetry)
    }

    @Test func theGenericMessageForARejectedKeyIsNotNoAnswer() {
        let message = UserFacingError.message(for: .keyRejected)
        #expect(message.text == L10n.Failure.keyRejected)
        #expect(message.text != UserFacingError.message(for: .noAnswer).text)
    }

    // MARK: the repair

    @Test func repairingThisMacReplacesTheTokenAndKeepsTheServer() async throws {
        let tokens = Tokens()
        await withApp(thisMac()) { app in
            await app.repairThisMac(
                id: id, pairing: pairing(HealthyDaemon()),
                storeToken: { tokens.stored[$1] = $0; return true },
                revoke: { _, token, _ in tokens.revoked.append(token) })

            let server = app.servers.first
            #expect(app.servers.count == 1)
            #expect(server?.id == id)
            #expect(server?.config.token == "bdt_new")
            #expect(server?.config.isThisMac == true)
            #expect(server?.config.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:17781/v1/rpc")!))
            #expect(tokens.stored[id] == "bdt_new")
            #expect(app.keyRepair[id] == nil)
            await server?.disconnect()
        }
    }

    @Test func aRepairThatCannotPairKeepsTheOldServerAndSaysWhy() async throws {
        let tokens = Tokens()
        await withApp(thisMac()) { app in
            let before = app.servers.first
            await app.repairThisMac(
                id: id, pairing: pairing(StoppedDaemon()),
                storeToken: { tokens.stored[$1] = $0; return true },
                revoke: { _, token, _ in tokens.revoked.append(token) })

            #expect(app.servers.first === before)
            #expect(tokens.stored.isEmpty)
            guard case .failed(let message)? = app.keyRepair[id] else {
                Issue.record("expected a failed repair, got \(String(describing: app.keyRepair[id]))")
                return
            }
            #expect(message.text == L10n.Failure.keyRepairFailed)
            #expect(message.technical != nil)
        }
    }

    @Test func aTokenThatCannotBeKeptIsRevokedAndTheServerStays() async throws {
        let tokens = Tokens()
        await withApp(thisMac()) { app in
            let before = app.servers.first
            await app.repairThisMac(
                id: id, pairing: pairing(HealthyDaemon(), token: "bdt_lost"),
                storeToken: { _, _ in false },
                revoke: { _, token, _ in tokens.revoked.append(token) })

            #expect(tokens.revoked == ["bdt_lost"])
            #expect(app.servers.first === before)
            guard case .failed? = app.keyRepair[id] else {
                Issue.record("expected a failed repair")
                return
            }
        }
    }

    @Test func aRemoteServerIsNotRepairedByPairing() async throws {
        let remote = ServerConfig(
            id: id, name: "srv", endpoint: .webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!), token: "t")
        let tokens = Tokens()
        await withApp(remote) { app in
            let before = app.servers.first
            await app.repairThisMac(
                id: id, pairing: pairing(HealthyDaemon()),
                storeToken: { tokens.stored[$1] = $0; return true },
                revoke: { _, token, _ in tokens.revoked.append(token) })

            #expect(tokens.stored.isEmpty)
            #expect(app.servers.first === before)
            #expect(app.keyRepair[id] == nil)
        }
    }

    // MARK: a server removed while the pairing runs

    /// The pairing runs `onPair` (the person removes the server there), then goes on as a healthy daemon.
    private struct RemovingDaemon: CommandRunner {
        let onPair: @Sendable () async -> Void
        let succeed: Bool
        func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
            if arguments.contains("info") {
                return CommandResult(status: 0, stdout: #"{"listen":"127.0.0.1:17781","running":true}"#, stderr: "")
            }
            await onPair()
            guard succeed else { return CommandResult(status: 1, stdout: "", stderr: "gone") }
            return CommandResult(status: 0, stdout: #"{"code":"sunset-orbit","expires_in_ms":600000}"#, stderr: "")
        }
    }

    @Test func aServerRemovedDuringPairingGetsNoKeychainEntryAndItsDeviceIsRevoked() async throws {
        let tokens = Tokens()
        await withApp(thisMac()) { app in
            let id = self.id
            let runner = RemovingDaemon(onPair: { await MainActor.run { app.remove(id) } }, succeed: true)
            await app.repairThisMac(
                id: id, pairing: pairing(runner),
                storeToken: { tokens.stored[$1] = $0; return true },
                eraseToken: { tokens.stored[$0] = nil },
                revoke: { _, token, _ in tokens.revoked.append(token) })

            #expect(app.servers.isEmpty)
            #expect(tokens.stored.isEmpty)
            #expect(tokens.revoked == ["bdt_new"])
            #expect(app.keyRepair[id] == nil)
        }
    }

    @Test func aPairingThatFailsAfterTheServerWasRemovedLeavesNoFailureBehind() async throws {
        await withApp(thisMac()) { app in
            let id = self.id
            let runner = RemovingDaemon(onPair: { await MainActor.run { app.remove(id) } }, succeed: false)
            await app.repairThisMac(id: id, pairing: pairing(runner), storeToken: { _, _ in true })

            #expect(app.keyRepair[id] == nil)
        }
    }
}
