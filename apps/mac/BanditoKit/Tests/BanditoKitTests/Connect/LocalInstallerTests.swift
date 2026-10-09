import Foundation
import Testing

@testable import BanditoKit

// This Mac's install: the bandito binary is a scripted runner, and the daemon "starts" when the script says so. The redeem
// is a stub, so nothing here opens a socket. What the install asks the daemon, and in which order, is the contract.

private let serviceOK = CommandResult(
    status: 0,
    stdout: #"{"ok":true,"mode":"launchd","listen":"127.0.0.1:17779","socket":"/h/bandito.sock","warnings":[]}"#,
    stderr: "")
private let stoppedInfo = CommandResult(
    status: 0,
    stdout: #"{"version":"0.1.1","home":"/h","socket":"/h/bandito.sock","listen":"127.0.0.1:17779","running":false,"features":[]}"#,
    stderr: "")
private let runningInfo = CommandResult(
    status: 0,
    stdout: #"{"version":"0.1.1","home":"/h","socket":"/h/bandito.sock","listen":"127.0.0.1:17779","running":true,"features":["host"]}"#,
    stderr: "")
private let pairOK = CommandResult(
    status: 0, stdout: #"{"code":"sunset-orbit","expires_in_ms":600000}"#, stderr: "")

/// A daemon that starts after `asksBeforeRunning` asks of `info`: each ask before that says `running: false`.
private func daemon(startsAfter asksBeforeRunning: Int, counter: ScriptCounter = ScriptCounter()) -> ScriptedRunner {
    ScriptedRunner { _, arguments in
        if arguments.contains("service") { return serviceOK }
        if arguments.contains("info") {
            counter.bump()
            return counter.count > asksBeforeRunning ? runningInfo : stoppedInfo
        }
        if arguments.contains("pair") { return pairOK }
        return CommandResult(status: 1, stdout: "", stderr: "unexpected \(arguments)")
    }
}

/// Redeems only the expected code at the daemon's loopback WebSocket, and gives a token.
private let redeemExpected: LocalDaemonPairing.Redeem = { url, code, _ in
    guard url.absoluteString == "ws://127.0.0.1:17779/v1/rpc", code == "sunset-orbit" else {
        throw RPCError(code: RPCError.disconnected, message: "unexpected \(url) \(code)")
    }
    let json = #"{"token":"bdt_mac","device":{"id":"d1","name":"Ann's Mac","created_at":1,"last_seen_at":null}}"#
    return try RPCClient.decoder.decode(PairResult.self, from: Data(json.utf8))
}

private func failure(_ events: [InstallEvent]) -> InstallError? {
    for event in events {
        if case .failed(let error) = event { return error }
    }
    return nil
}

private func done(_ events: [InstallEvent]) -> PairInfo? {
    for event in events {
        if case .done(let info) = event { return info }
    }
    return nil
}

private func logs(_ events: [InstallEvent]) -> [String] {
    events.compactMap { event in
        if case .log(let line) = event { return line }
        return nil
    }
}

private func stepIDs(_ events: [InstallEvent]) -> [InstallStep] {
    events.compactMap { event in
        if case .step(let step, _) = event { return step }
        return nil
    }
}

@Suite struct LocalInstallerTests {
    /// A home, with `~/.local/bin/bandito` holding `installed` when it is given. Removed by the caller.
    private func makeHome(installed: String? = "BIN") throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "local-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        if let installed {
            try writeFile(home.appending(path: ".local/bin/bandito"), installed, modified: Date())
        }
        return home
    }

    private func writeFile(_ url: URL, _ text: String, modified: Date) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Changes when a file is replaced by a rename, and stays when its content is only rewritten in place.
    private func inodeNumber(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? UInt64)
    }

    private func installer(
        _ runner: CommandRunner, home: URL, bundled: URL? = nil, hostName: String? = "Ann's Mac",
        timeout: Duration = .seconds(5)
    ) -> LocalInstaller {
        LocalInstaller(
            runner: runner, bundledBinary: bundled, home: home, hostName: hostName, fallbackName: "This Mac",
            redeem: redeemExpected, pollInterval: .milliseconds(1), pollTimeout: timeout)
    }

    @Test func theDaemonStartsLateAndTheAppIsPairedOverItsWebSocket() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = daemon(startsAfter: 2)

        let events = await collect(installer(runner, home: home).install())

        #expect(failure(events) == nil)
        #expect(stepIDs(events) == [.install, .service, .pair])
        let info = try #require(done(events))
        #expect(info.server.endpoint == .webSocket(url: URL(string: "ws://127.0.0.1:17779/v1/rpc")!))
        #expect(info.server.token == "bdt_mac")
        #expect(info.server.name == "Ann's Mac")
        #expect(info.alreadyInstalled == true)
        // Two asks say the daemon is not up yet, the third says it is. The pairing asks once more, then pairs.
        #expect(
            runner.calls.map(\.arguments) == [
                ["service", "install", "--json"],
                ["info", "--json"],
                ["info", "--json"],
                ["info", "--json"],
                ["info", "--json"],
                ["pair", "--json"],
            ])
    }

    @Test func noLocalServerIsCreated() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let events = await collect(installer(daemon(startsAfter: 0), home: home).install())

        let info = try #require(done(events))
        if case .local = info.server.endpoint {
            Issue.record("the install created a local (unix socket) server")
        }
    }

    @Test func aDaemonThatNeverRunsFailsWithTheLastLinesOfItsLog() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appending(path: ".bandito/logs/daemon.log")
        try writeFile(log, (1...25).map { "line \($0)" }.joined(separator: "\n"), modified: Date())
        let runner = daemon(startsAfter: .max)

        let events = await collect(
            installer(runner, home: home, timeout: .milliseconds(40)).install())

        #expect(failure(events) == .localDaemonNotStarted)
        #expect(done(events) == nil)
        #expect(stepIDs(events) == [.install, .service])
        // The last 20 lines of the log, after the line that names the file.
        let lines = logs(events)
        #expect(Array(lines.suffix(20)) == (6...25).map { "line \($0)" })
        #expect(lines.contains("line 5") == false)
        #expect(runner.calls.contains { $0.arguments == ["pair", "--json"] } == false)
    }

    @Test func aDaemonThatNeverRunsWithoutALogFailsWithoutLogLines() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let events = await collect(
            installer(daemon(startsAfter: .max), home: home, timeout: .milliseconds(20)).install())

        #expect(failure(events) == .localDaemonNotStarted)
        #expect(logs(events).isEmpty)
    }

    @Test func theServerIsNamedAfterThisMacOrTheFallback() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "unused-home", directoryHint: .isDirectory)
        let named = LocalInstaller(
            runner: daemon(startsAfter: 0), bundledBinary: nil, home: home, hostName: "  Ann's Mac ",
            fallbackName: "Этот Mac")
        let unnamed = LocalInstaller(
            runner: daemon(startsAfter: 0), bundledBinary: nil, home: home, hostName: nil, fallbackName: "Этот Mac")
        let blank = LocalInstaller(
            runner: daemon(startsAfter: 0), bundledBinary: nil, home: home, hostName: "   ", fallbackName: "Этот Mac")

        #expect(named.serverName == "Ann's Mac")
        #expect(unnamed.serverName == "Этот Mac")
        #expect(blank.serverName == "Этот Mac")
    }

    @Test func copiesTheBundledBinaryStartsTheServiceAndPairsThisMac() async throws {
        let home = try makeHome(installed: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "NEW", modified: Date())
        let runner = daemon(startsAfter: 0)

        let events = await collect(installer(runner, home: home, bundled: bundled).install())

        let installed = home.appending(path: ".local/bin/bandito")
        #expect(try read(installed) == "NEW")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        let first = try #require(runner.calls.first)
        #expect(first.executable == installed.path)
        #expect(first.arguments == ["service", "install", "--json"])
        #expect(stepIDs(events) == [.install, .service, .pair])
        #expect(try #require(done(events)).alreadyInstalled == false)
    }

    @Test func anInstalledBinaryWithTheSameContentIsKeptAsItIs() async throws {
        let home = try makeHome(installed: "SAME")
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        let installed = home.appending(path: ".local/bin/bandito")
        try writeFile(bundled, "SAME", modified: Date())
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: installed.path)
        let inode = try inodeNumber(installed)

        let events = await collect(installer(daemon(startsAfter: 0), home: home, bundled: bundled).install())

        #expect(try inodeNumber(installed) == inode)
        #expect(try read(installed) == "SAME")
        #expect(try #require(done(events)).alreadyInstalled == true)
    }

    @Test func aReplacementLeavesNoTemporaryFileBehind() async throws {
        let home = try makeHome(installed: "OLD")
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "NEW", modified: Date())

        _ = await collect(installer(daemon(startsAfter: 0), home: home, bundled: bundled).install())

        let names = try FileManager.default.contentsOfDirectory(
            atPath: home.appending(path: ".local/bin").path)
        #expect(names == ["bandito"])
    }

    @Test func withoutABundledBinaryAndNothingInstalledItFails() async throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "local-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = daemon(startsAfter: 0)

        let events = await collect(installer(runner, home: home).install())

        #expect(failure(events) == .localBinaryMissing)
        #expect(runner.calls.isEmpty)
    }

    @Test func aFailedServiceInstallIsReported() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let refused = CommandResult(
            status: 1,
            stdout: #"{"ok":false,"mode":"launchd","listen":"127.0.0.1:7878","socket":"/s","warnings":["launchctl refused"]}"#,
            stderr: "")
        let runner = ScriptedRunner { _, _ in refused }

        let events = await collect(installer(runner, home: home).install())

        #expect(failure(events) == .serviceFailed("launchctl refused"))
        #expect(runner.calls.count == 1)
    }
}
