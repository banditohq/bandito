import Foundation
import Testing

@testable import BanditoKit

// A QA copy of the app never installs Bandito on this Mac: no copy into ~/.local/bin, no service, no command at all.

@Suite struct LocalInstallerQATests {
    @Test func aQACopyRefusesToInstallBeforeRunningAnything() async throws {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "local-installer-qa-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ScriptedRunner { _, _ in
            CommandResult(status: 0, stdout: "", stderr: "")
        }
        let installer = LocalInstaller(
            runner: runner, bundledBinary: nil, home: home, hostName: "Ann's Mac", fallbackName: "This Mac",
            qaBuild: true)

        var events: [InstallEvent] = []
        for await event in installer.install() {
            events.append(event)
        }

        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".local/bin/bandito").path))
        guard case .failed = events.last else {
            Issue.record("the install should end with a failure, got \(events)")
            return
        }
    }
}
