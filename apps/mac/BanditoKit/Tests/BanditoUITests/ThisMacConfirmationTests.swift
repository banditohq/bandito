import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

// A saved server that is this Mac's daemon, saved before the flag existed, gets the flag at launch. The runner is a
// stub that answers `info` for the listen port; no daemon or service runs here.

/// Answers `info --json` for a daemon running on port 17779, after `delay`.
private struct RunningDaemon: CommandRunner {
    var delay: Duration = .zero

    func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
        if delay > .zero { try await Task.sleep(for: delay) }
        return CommandResult(status: 0, stdout: #"{"listen":"127.0.0.1:17779","running":true}"#, stderr: "")
    }
}

private let storeKey = "servers.v1"

/// A UserDefaults suite of its own for one test. The test removes it with `removePersistentDomain` when it ends.
private func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "test-\(UUID())"
    return (UserDefaults(suiteName: suite)!, suite)
}

/// Saves `servers` where AppModel loads them, in the test's own defaults.
private func saveServers(_ servers: [ServerConfig], in defaults: UserDefaults) {
    defaults.set(try! JSONEncoder().encode(servers), forKey: storeKey)
}

/// An installed binary, so the check gets as far as the runner.
private func installedBinary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "this-mac-app-\(UUID().uuidString)")
    try "BIN".write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func loopback(_ port: Int = 17779) -> URL {
    URL(string: "ws://127.0.0.1:\(port)/v1/rpc")!
}

// Each test has its own UserDefaults suite, so the saved server list never meets another test's.
@MainActor
extension LocalServerMigrationTests {
    @Test func aConfirmedServerIsMarkedKeptAndSaved() async throws {
        let id = UUID()
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        saveServers([ServerConfig(id: id, name: "Mac", endpoint: .webSocket(url: loopback()))], in: defaults)
        let binary = try installedBinary()
        defer { try? FileManager.default.removeItem(at: binary) }

        let app = AppModel(defaults: defaults)
        await app.confirmThisMacServers(binary: binary, runner: RunningDaemon(), timeout: .seconds(2))

        let server = try #require(app.servers.first)
        #expect(server.id == id)
        #expect(server.config.isThisMac)
        #expect(server.config.endpoint == .webSocket(url: loopback()))
        let saved = try JSONDecoder().decode(
            [ServerConfig].self, from: try #require(defaults.data(forKey: storeKey)))
        #expect(saved.first?.isThisMac == true)
    }

    @Test func theChecksOfSeveralServersRunTogether() async throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        saveServers([
            ServerConfig(name: "A", endpoint: .webSocket(url: loopback())),
            ServerConfig(name: "B", endpoint: .webSocket(url: loopback())),
        ], in: defaults)
        let binary = try installedBinary()
        defer { try? FileManager.default.removeItem(at: binary) }

        let app = AppModel(defaults: defaults)
        let start = ContinuousClock.now
        await app.confirmThisMacServers(
            binary: binary, runner: RunningDaemon(delay: .milliseconds(300)), timeout: .seconds(2))
        // Two checks of 300 ms each: one after the other they would take 600 ms.
        #expect(start.duration(to: .now) < .milliseconds(550))
        #expect(app.servers.allSatisfy { $0.config.isThisMac })
    }

    @Test func aServerRemovedDuringItsCheckIsNotBroughtBack() async throws {
        let id = UUID()
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        saveServers([ServerConfig(id: id, name: "Mac", endpoint: .webSocket(url: loopback()))], in: defaults)
        let binary = try installedBinary()
        defer { try? FileManager.default.removeItem(at: binary) }

        let app = AppModel(defaults: defaults)
        struct RemovingDaemon: CommandRunner {
            let app: AppModel
            let id: UUID

            func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
                await MainActor.run { app.remove(id) }
                return CommandResult(status: 0, stdout: #"{"listen":"127.0.0.1:17779","running":true}"#, stderr: "")
            }
        }
        await app.confirmThisMacServers(
            binary: binary, runner: RemovingDaemon(app: app, id: id), timeout: .seconds(2))

        #expect(app.servers.isEmpty)
        let saved = defaults.data(forKey: storeKey).flatMap {
            try? JSONDecoder().decode([ServerConfig].self, from: $0)
        } ?? []
        #expect(saved.allSatisfy { $0.id != id })
    }
}
