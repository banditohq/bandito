import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

// A saved `.local` server (this Mac, over its unix socket) becomes a WebSocket server with a device token at launch,
// once. The bandito runner and the redeem are stubs; the Keychain is replaced by a recorder.

/// Answers the bandito commands of a healthy daemon: `info` with its listen address, `pair` with a code.
private struct HealthyDaemon: CommandRunner {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        if arguments.contains("info") {
            return CommandResult(status: 0, stdout: #"{"listen":"127.0.0.1:17779","running":true}"#, stderr: "")
        }
        if arguments.contains("pair") {
            return CommandResult(status: 0, stdout: #"{"code":"sunset-orbit","expires_in_ms":600000}"#, stderr: "")
        }
        return CommandResult(status: 1, stdout: "", stderr: "unknown")
    }
}

/// A daemon that is not running: `info` reports it, `pair` fails.
private struct StoppedDaemon: CommandRunner {
    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        CommandResult(status: 1, stdout: "", stderr: "daemon is not running")
    }
}

private let storeKey = "servers.v1"

/// Saves `servers` where AppModel loads them. Returns what was there before, for `restoreSaved`.
private func saveServers(_ servers: [ServerConfig]) -> Data? {
    let defaults = UserDefaults.standard
    let previous = defaults.data(forKey: storeKey)
    defaults.set(try! JSONEncoder().encode(servers), forKey: storeKey)
    return previous
}

private func restoreSaved(_ previous: Data?) {
    if let previous {
        UserDefaults.standard.set(previous, forKey: storeKey)
    } else {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}

@MainActor
@Suite(.serialized) struct LocalServerMigrationTests {
    private let id = UUID()
    private let local = ServerConfig(
        name: "This Mac", endpoint: .local(socketPath: "/Users/u/.bandito/bandito.sock"))

    @Test func aLocalServerBecomesAWebSocketServerWithItsToken() async throws {
        let stored = Recorder()
        let previous = saveServers([ServerConfig(id: id, name: "This Mac", endpoint: local.endpoint)])
        defer { restoreSaved(previous) }
        do {
            let app = AppModel()
            let pairing = LocalDaemonPairing(runner: HealthyDaemon(), binary: URL(fileURLWithPath: "/bin/bandito"),
                redeem: { url, code, _ in
                    guard url.absoluteString == "ws://127.0.0.1:17779/v1/rpc", code == "sunset-orbit" else {
                        throw RPCError(code: RPCError.disconnected, message: "unexpected \(url)")
                    }
                    return try RPCClient.decoder.decode(
                        PairResult.self,
                        from: Data(#"{"token":"bdt_mac","device":{"id":"d","name":"n","created_at":1}}"#.utf8))
                })

            await app.migrateLocalServers(pairing: pairing, storeToken: { token, owner in
                stored.set(token, for: owner)
                return true
            })

            let server = try #require(app.servers.first)
            #expect(server.id == id)
            #expect(server.config.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:17779/v1/rpc")!))
            #expect(stored.token(for: id) == "bdt_mac")
            // Saved as a WebSocket server; the token is never in the saved list.
            let saved = try JSONDecoder().decode(
                [ServerConfig].self, from: try #require(UserDefaults.standard.data(forKey: storeKey)))
            #expect(saved.first?.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:17779/v1/rpc")!))
            #expect(saved.first?.token == nil)
        }
    }

    @Test func aServerThatCannotBePairedStaysLocalForTheNextLaunch() async throws {
        let stored = Recorder()
        let previous = saveServers([ServerConfig(id: id, name: "This Mac", endpoint: local.endpoint)])
        defer { restoreSaved(previous) }
        do {
            let app = AppModel()
            let pairing = LocalDaemonPairing(runner: StoppedDaemon(), binary: URL(fileURLWithPath: "/bin/bandito"))

            await app.migrateLocalServers(pairing: pairing, storeToken: { token, owner in
                stored.set(token, for: owner)
                return true
            })

            #expect(app.servers.first?.config.endpoint == local.endpoint)
            #expect(stored.token(for: id) == nil)
        }
    }

    @Test func aWebSocketServerIsLeftAlone() async throws {
        let webSocket = ServerConfig(
            id: id, name: "srv", endpoint: .webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!))
        let previous = saveServers([webSocket])
        defer { restoreSaved(previous) }
        do {
            let app = AppModel()
            await app.migrateLocalServers(
                pairing: LocalDaemonPairing(runner: StoppedDaemon(), binary: URL(fileURLWithPath: "/bin/bandito")),
                storeToken: { _, _ in
                    Issue.record("a token was stored for a server that is not local")
                    return true
                })
            #expect(app.servers.first?.config.endpoint == webSocket.endpoint)
        }
    }
}

/// Records the tokens the migration hands to the Keychain.
private final class Recorder: @unchecked Sendable {
    // @unchecked: the migration calls it on the main actor only.
    private var tokens: [UUID: String] = [:]

    func set(_ token: String?, for owner: UUID) {
        tokens[owner] = token
    }

    func token(for owner: UUID) -> String? {
        tokens[owner]
    }
}
