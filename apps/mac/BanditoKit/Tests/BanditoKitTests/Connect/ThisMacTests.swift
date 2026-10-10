import Foundation
import Testing

@testable import BanditoKit

// Which saved server is this Mac's daemon: the flag that pairing sets, its JSON form, and the check that gives the flag
// to a config saved before the flag existed. The runner is a script; no daemon or service runs here.

@Suite struct ThisMacTests {
    private let loopback = URL(string: "ws://127.0.0.1:17779/v1/rpc")!

    private func binary(_ home: URL) throws -> URL {
        let url = home.appending(path: ".local/bin/bandito")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "BIN".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func home() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "this-mac-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func info(running: Bool, listen: String = "127.0.0.1:17779") -> CommandResult {
        CommandResult(
            status: 0,
            stdout: #"{"version":"0.1.2","home":"/h","socket":"/h/bandito.sock","listen":"\#(listen)","running":\#(running),"features":[]}"#,
            stderr: "")
    }

    // MARK: JSON

    @Test func aConfigSavedBeforeTheFlagDecodesAsNotThisMac() throws {
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let data = try JSONEncoder().encode(config)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "isThisMac")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: old)
        #expect(decoded.isThisMac == false)
        #expect(decoded.id == config.id)
    }

    @Test func theFlagRoundTripsThroughJSON() throws {
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback), isThisMac: true)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(ServerConfig.self, from: data).isThisMac == true)
    }

    @Test func aPairedServerIsMarkedThisMac() {
        #expect(ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback), isThisMac: true).isThisMac)
        #expect(ServerConfig(name: "Other", endpoint: .webSocket(url: loopback)).isThisMac == false)
    }

    // MARK: confirmation

    @Test func aRunningDaemonOnTheConfiguredPortIsConfirmed() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = try binary(home)
        let runner = ScriptedRunner { _, _ in info(running: true) }
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))

        #expect(await LocalDaemonUpgrade.confirmsThisMac(config, binary: installed, runner: runner))
        let call = try #require(runner.calls.first)
        #expect(call.executable == installed.path)
        #expect(call.arguments == ["info", "--json"])
    }

    @Test func aStoppedDaemonIsNotConfirmed() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let runner = ScriptedRunner { _, _ in info(running: false) }
        #expect(await LocalDaemonUpgrade.confirmsThisMac(config, binary: try binary(home), runner: runner) == false)
    }

    @Test func aDaemonOnAnotherPortIsNotConfirmed() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let runner = ScriptedRunner { _, _ in info(running: true, listen: "127.0.0.1:7878") }
        #expect(await LocalDaemonUpgrade.confirmsThisMac(config, binary: try binary(home), runner: runner) == false)
    }

    @Test func aMissingBinaryIsNotConfirmedAndNothingRuns() async throws {
        let home = home()
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let runner = ScriptedRunner { _, _ in info(running: true) }
        let missing = home.appending(path: ".local/bin/bandito")
        #expect(await LocalDaemonUpgrade.confirmsThisMac(config, binary: missing, runner: runner) == false)
        #expect(runner.calls.isEmpty)
    }

    @Test func aRemoteOrSocketServerIsNotAskedAboutAtAll() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = try binary(home)
        let runner = ScriptedRunner { _, _ in info(running: true) }
        let remote = ServerConfig(
            name: "Remote", endpoint: .webSocket(url: URL(string: "wss://mac.example.ts.net/v1/rpc")!))
        let ssh = ServerConfig(name: "SSH", endpoint: .ssh(target: "localhost", remotePort: 7878))
        #expect(await LocalDaemonUpgrade.confirmsThisMac(remote, binary: installed, runner: runner) == false)
        #expect(await LocalDaemonUpgrade.confirmsThisMac(ssh, binary: installed, runner: runner) == false)
        #expect(runner.calls.isEmpty)
    }

    @Test func aFailedOrUnreadableAnswerIsNotConfirmed() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = try binary(home)
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let failed = ScriptedRunner { _, _ in CommandResult(status: 1, stdout: "", stderr: "boom") }
        let garbage = ScriptedRunner { _, _ in CommandResult(status: 0, stdout: "not json", stderr: "") }
        #expect(await LocalDaemonUpgrade.confirmsThisMac(config, binary: installed, runner: failed) == false)
        #expect(await LocalDaemonUpgrade.confirmsThisMac(config, binary: installed, runner: garbage) == false)
    }

    /// A CLI that never answers and ignores cancellation.
    private struct HungRunner: CommandRunner {
        func run(_ executable: String, _ arguments: [String], stdin: Data?) async throws -> CommandResult {
            await withCheckedContinuation { (_: CheckedContinuation<CommandResult, Never>) in }
        }
    }

    @Test func aRunnerThatNeverAnswersIsNotConfirmedWithinTheLimit() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let start = ContinuousClock.now
        let confirmed = await LocalDaemonUpgrade.confirmsThisMac(
            config, binary: try binary(home), runner: HungRunner(), timeout: .milliseconds(100))
        #expect(confirmed == false)
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func aHangingDaemonCLIProcessIsStoppedAtTheLimit() async throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let script = home.appending(path: ".local/bin/bandito")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let config = ServerConfig(name: "Mac", endpoint: .webSocket(url: loopback))
        let start = ContinuousClock.now
        let confirmed = await LocalDaemonUpgrade.confirmsThisMac(
            config, binary: script, runner: ProcessCommandRunner(), timeout: .milliseconds(300))
        #expect(confirmed == false)
        #expect(start.duration(to: .now) < .seconds(5))
    }
}
