import Foundation
import Testing

@testable import BanditoKit

// The upgrade of this Mac's daemon: the bundled binary replaces the installed one when the content differs, and the
// service is restarted with the installed binary. The runner is a script, so no service is started on this Mac.

private let upgradeServiceOK = CommandResult(
    status: 0,
    stdout: #"{"ok":true,"mode":"launchd","listen":"127.0.0.1:17779","socket":"/h/bandito.sock","warnings":[]}"#,
    stderr: "")
private let upgradeRunningInfo = CommandResult(
    status: 0,
    stdout: #"{"version":"0.1.2","home":"/h","socket":"/h/bandito.sock","listen":"127.0.0.1:17779","running":true,"features":["host"]}"#,
    stderr: "")

@Suite struct LocalInstallerUpgradeTests {
    private func makeHome(installed: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "local-upgrade-\(UUID().uuidString)", directoryHint: .isDirectory)
        if let installed {
            try writeFile(home.appending(path: ".local/bin/bandito"), installed)
        }
        return home
    }

    private func writeFile(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func inodeNumber(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? UInt64)
    }

    /// A service that answers `serviceReply` to `service install`, and a daemon that is running from the first `info`.
    private func runner(serviceReply: CommandResult = upgradeServiceOK) -> ScriptedRunner {
        ScriptedRunner { _, arguments in
            if arguments.contains("service") { return serviceReply }
            if arguments.contains("info") { return upgradeRunningInfo }
            return CommandResult(status: 1, stdout: "", stderr: "unexpected \(arguments)")
        }
    }

    private func installer(
        _ runner: CommandRunner, home: URL, bundled: URL?, qaBuild: Bool = false
    ) -> LocalInstaller {
        LocalInstaller(
            runner: runner, bundledBinary: bundled, home: home, hostName: nil, fallbackName: "This Mac",
            redeem: nil, pollInterval: .milliseconds(1), pollTimeout: .seconds(5), qaBuild: qaBuild)
    }

    @Test func aDifferentBundledBinaryReplacesTheInstalledOneAndRestartsTheService() async throws {
        let home = try makeHome(installed: "OLD")
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "NEW")
        let script = runner()

        try await installer(script, home: home, bundled: bundled).upgrade()

        let installed = home.appending(path: ".local/bin/bandito")
        #expect(try read(installed) == "NEW")
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        let service = try #require(script.calls.first)
        #expect(service.executable == installed.path)
        #expect(service.arguments == ["service", "install", "--json"])
    }

    @Test func aBinaryWithTheSameContentIsNotCopiedAgain() async throws {
        let home = try makeHome(installed: "SAME")
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "SAME")
        let installed = home.appending(path: ".local/bin/bandito")
        let inode = try inodeNumber(installed)

        try await installer(runner(), home: home, bundled: bundled).upgrade()

        #expect(try inodeNumber(installed) == inode)
        #expect(try read(installed) == "SAME")
    }

    @Test func aServiceThatRefusesTheRestartIsAnError() async throws {
        let home = try makeHome(installed: "OLD")
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "NEW")
        let refused = CommandResult(
            status: 1,
            stdout: #"{"ok":false,"mode":"launchd","listen":"127.0.0.1:7878","socket":"/s","warnings":["launchctl refused"]}"#,
            stderr: "")

        await #expect(throws: InstallError.serviceFailed("launchctl refused")) {
            try await self.installer(self.runner(serviceReply: refused), home: home, bundled: bundled).upgrade()
        }
    }

    @Test func aQACopyNeverUpgradesAndRunsNothing() async throws {
        let home = try makeHome(installed: "OLD")
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "NEW")
        let script = runner()

        await #expect(throws: InstallError.self) {
            try await self.installer(script, home: home, bundled: bundled, qaBuild: true).upgrade()
        }
        #expect(script.calls.isEmpty)
        #expect(try read(home.appending(path: ".local/bin/bandito")) == "OLD")
    }

    @Test func withoutABundledBinaryTheUpgradeFails() async throws {
        let home = try makeHome(installed: "OLD")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = runner()

        await #expect(throws: InstallError.localBinaryMissing) {
            try await self.installer(script, home: home, bundled: home.appending(path: "missing/bandito")).upgrade()
        }
        #expect(script.calls.isEmpty)
    }

    @Test func anUpgradeNeverInstallsADaemonThatIsNotThere() async throws {
        let home = try makeHome(installed: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/bandito")
        try writeFile(bundled, "NEW")
        let script = runner()

        await #expect(throws: InstallError.localBinaryMissing) {
            try await self.installer(script, home: home, bundled: bundled).upgrade()
        }
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".local/bin/bandito").path))
        #expect(script.calls.isEmpty)
    }

    @Test func theBundledVersionIsReadOnceWithVersion() async throws {
        let home = try makeHome(installed: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/\(UUID().uuidString)/bandito")
        let script = ScriptedRunner { _, _ in CommandResult(status: 0, stdout: "bandito 0.1.2\n", stderr: "") }
        let loader = installer(script, home: home, bundled: bundled)

        #expect(await loader.bundledVersion() == "0.1.2")
        #expect(await loader.bundledVersion() == "0.1.2")
        #expect(script.calls.count == 1)
        let call = try #require(script.calls.first)
        #expect(call.executable == bundled.path)
        #expect(call.arguments == ["--version"])
    }

    @Test func aFailedVersionReadIsNilAndAskedAgain() async throws {
        let home = try makeHome(installed: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appending(path: "bundle/\(UUID().uuidString)/bandito")
        let script = ScriptedRunner { _, _ in CommandResult(status: 1, stdout: "", stderr: "boom") }
        let loader = installer(script, home: home, bundled: bundled)

        #expect(await loader.bundledVersion() == nil)
        #expect(await loader.bundledVersion() == nil)
        #expect(script.calls.count == 2)
    }

    @Test func aBundleWithoutADaemonHasNoVersion() async {
        let home = FileManager.default.temporaryDirectory.appending(path: "local-upgrade-\(UUID().uuidString)")
        let script = ScriptedRunner { _, _ in CommandResult(status: 0, stdout: "bandito 0.1.2", stderr: "") }
        #expect(await installer(script, home: home, bundled: nil).bundledVersion() == nil)
        #expect(script.calls.isEmpty)
    }
}
