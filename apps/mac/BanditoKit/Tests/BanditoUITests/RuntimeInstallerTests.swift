import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

/// A server that has no `claude` yet and installs it where the test says: a job that ends the way `jobs` lists.
@MainActor
private final class FakeInstallServer: SetupServer {
    var jobs: [String]
    var installed = false
    private(set) var installRequests: [[String]] = []

    init(jobs: [String]) {
        self.jobs = jobs
    }

    func setupStatus() async throws -> SetupStatus {
        let claude =
            #"{"id":"claude","feature":"agents","installed":\#(installed),"installable":true,"needs_sudo":false}"#
        let grok = #"{"id":"grok","feature":"agents","installed":false,"installable":false,"needs_sudo":false}"#
        let json =
            #"{"os":"linux","arch":"x86_64","sudo":"none","components":[\#(claude),\#(grok)],"features":{"screen":"ready","browser":"ready","containers":"ready","agents":{"claude":"missing","codex":"missing","grok":"missing"}}}"#
        return try Self.decoder.decode(SetupStatus.self, from: Data(json.utf8))
    }

    func setupInstall(components: [String]) async throws -> String {
        installRequests.append(components)
        return "job-1"
    }

    func setupJob(_ id: String, from offset: UInt64) async throws -> SetupJob {
        let json = jobs.isEmpty ? #"{"state":"done","step":"Done","log":"","offset":0}"# : jobs.removeFirst()
        return try Self.decoder.decode(SetupJob.self, from: Data(json.utf8))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

@MainActor
@Suite struct RuntimeInstallerTests {
    private let running = #"{"state":"running","step":"Installing claude","log":"npm: added 1 package\n","offset":22}"#
    private let done = #"{"state":"done","step":"Done","log":"","offset":22}"#
    private let failedJob = #"{"state":"failed","step":"Installing claude","log":"npm ERR! network\n","offset":18,"failed_component":"claude"}"#
    private let password = #"{"state":"needs_password","step":"Installing claude","log":"","offset":0,"command":"sudo apt install nodejs"}"#

    private func ready(_ server: FakeInstallServer) async -> RuntimeInstaller {
        let installer = RuntimeInstaller()
        installer.setup.pollInterval = .milliseconds(1)
        await installer.load(server)
        return installer
    }

    @Test func onlyAMissingCliThatBanditoCanInstallIsOffered() async {
        let installer = await ready(FakeInstallServer(jobs: []))
        #expect(installer.canInstall(.claude))
        // Grok has no installer on the server: its card keeps only the link to the guide.
        #expect(!installer.canInstall(.grok))
        // Codex is not in the status at all.
        #expect(!installer.canInstall(.codex))
    }

    @Test func nothingIsOfferedBeforeTheStatusIsKnown() {
        #expect(!RuntimeInstaller().canInstall(.claude))
    }

    @Test func aFinishedInstallClearsTheStateAndReadsTheRuntimesAgain() async {
        let server = FakeInstallServer(jobs: [running, done])
        let installer = await ready(server)
        var refreshed = 0
        server.installed = true
        await installer.install(.claude, server: server) { refreshed += 1 }
        #expect(server.installRequests == [["claude"]])
        #expect(installer.installing == nil)
        #expect(installer.failed == nil)
        #expect(refreshed == 1)
        // The status was read again: claude is installed now, so nothing is offered for it.
        #expect(!installer.canInstall(.claude))
    }

    @Test func aFailedInstallIsRemembered() async {
        let server = FakeInstallServer(jobs: [failedJob])
        let installer = await ready(server)
        await installer.install(.claude, server: server) {}
        #expect(installer.failed == .claude)
        #expect(installer.installing == nil)
        #expect(installer.canInstall(.claude))
    }

    @Test func aJobThatNeedsThePasswordCountsAsFailedSoTheGuideIsShown() async {
        let server = FakeInstallServer(jobs: [password])
        let installer = await ready(server)
        await installer.install(.claude, server: server) {}
        #expect(installer.failed == .claude)
    }

    @Test func aRetryClearsTheOldFailure() async {
        let server = FakeInstallServer(jobs: [failedJob, done])
        let installer = await ready(server)
        await installer.install(.claude, server: server) {}
        #expect(installer.failed == .claude)
        await installer.install(.claude, server: server) {}
        #expect(installer.failed == nil)
    }
}
