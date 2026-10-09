import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct InstallChecklistTests {
    private func pairInfo() -> PairInfo {
        let server = ServerConfig(
            name: "This Mac", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:7878/v1/rpc")!), token: "bdt")
        return PairInfo(server: server, alreadyInstalled: false, warnings: [])
    }

    // MARK: this Mac

    @Test func thisMacHasThreeLinesInOrder() {
        #expect(ChecklistItem.thisMac.map(\.steps) == [[.install], [.service], [.pair]])
        #expect(InstallChecklist(items: ChecklistItem.thisMac).items.count == 3)
    }

    @Test func thisMacHasNoSSHLines() {
        #expect(ChecklistItem.thisMac.allSatisfy { !$0.title.contains("SSH") })
    }

    @Test func aFullThisMacRunMarksEveryLineDone() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.install, "Installing Bandito on this Mac"))
        list.apply(.step(.service, "Starting the service"))
        list.apply(.step(.pair, "Pairing the app"))
        list.apply(.done(pairInfo()))
        #expect((0..<3).allSatisfy { list.mark(at: $0) == .done })
        #expect(list.failure == nil)
    }

    @Test func aDaemonThatDoesNotStartFailsItsStartLine() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.install, "Installing Bandito on this Mac"))
        list.apply(.step(.service, "Starting the service"))
        list.apply(.failed(.localDaemonNotStarted))
        #expect(list.mark(at: 0) == .done)
        #expect(list.mark(at: 1) == .failed)
        #expect(list.mark(at: 2) == .pending)
        #expect(list.failure == .localDaemonNotStarted)
    }

    @Test func aFailedCopyFailsTheFirstLine() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.install, "Installing Bandito on this Mac"))
        list.apply(.failed(.localBinaryMissing))
        #expect(list.mark(at: 0) == .failed)
        #expect(list.mark(at: 1) == .pending)
        #expect(list.mark(at: 2) == .pending)
    }

    @Test func stepsOfAnSSHInstallDoNothingOnThisMac() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.connect, "Connecting over SSH"))
        list.apply(.step(.check, "Checking the server"))
        list.apply(.step(.download, "Downloading Bandito"))
        #expect((0..<3).allSatisfy { list.mark(at: $0) == .pending })
        #expect(list.index(of: .connect) == nil)
    }

    // MARK: your own server (SSH)

    @Test func sshHasFiveLinesInOrder() {
        #expect(
            ChecklistItem.ssh.map(\.steps)
                == [
                    Set([.connect]),
                    Set([.check]),
                    Set([.download, .verify, .install]),
                    Set([.service]),
                    Set([.pair]),
                ])
    }

    @Test func aFullSSHRunMarksEveryLineDone() {
        var list = InstallChecklist()
        let steps: [InstallStep] = [.connect, .check, .download, .verify, .install, .service, .pair, .pair]
        for step in steps {
            list.apply(.step(step, ""))
        }
        list.apply(.done(pairInfo()))
        #expect((0..<5).allSatisfy { list.mark(at: $0) == .done })
        #expect(list.failure == nil)
    }

    @Test func downloadVerifyAndInstallAreOneLine() {
        var list = InstallChecklist()
        list.apply(.step(.connect, ""))
        list.apply(.step(.check, ""))
        list.apply(.step(.download, ""))
        #expect(list.mark(at: 2) == .running)
        list.apply(.step(.verify, ""))
        #expect(list.mark(at: 1) == .done)
        #expect(list.mark(at: 2) == .running)
        list.apply(.step(.install, ""))
        #expect(list.mark(at: 2) == .running)
        #expect(list.mark(at: 3) == .pending)
    }

    @Test func aStepRunsAndTheLinesBeforeItAreDone() {
        var list = InstallChecklist()
        list.apply(.step(.install, ""))
        #expect(list.mark(at: 0) == .done)
        #expect(list.mark(at: 1) == .done)
        #expect(list.mark(at: 2) == .running)
        #expect(list.mark(at: 3) == .pending)
    }

    @Test func aFailureStopsTheRunningLineAndLeavesTheRestPending() {
        var list = InstallChecklist()
        list.apply(.step(.check, "Checking the server"))
        list.apply(.step(.install, "Installing Bandito"))
        list.apply(.failed(.sshFailed(.hostKeyUnknown)))
        #expect(list.mark(at: 0) == .done)
        #expect(list.mark(at: 1) == .done)
        #expect(list.mark(at: 2) == .failed)
        #expect(list.mark(at: 3) == .pending)
        #expect(list.failure == .sshFailed(.hostKeyUnknown))
    }

    @Test func aFailureBeforeAnyStepFailsTheFirstLine() {
        var list = InstallChecklist()
        list.apply(.failed(.sshFailed(.refused)))
        #expect(list.mark(at: 0) == .failed)
        #expect(list.mark(at: 1) == .pending)
    }

    // MARK: both

    @Test func retryAfterAFailureStartsOverCleanlyKeepingTheLines() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.install, ""))
        list.apply(.failed(.localDaemonNotStarted))
        list.reset()
        #expect(list.items == ChecklistItem.thisMac)
        #expect((0..<3).allSatisfy { list.mark(at: $0) == .pending })
        #expect(list.failure == nil)
        #expect(list.log.isEmpty)
        list.apply(.step(.install, ""))
        list.apply(.step(.service, ""))
        list.apply(.step(.pair, ""))
        list.apply(.done(pairInfo()))
        #expect((0..<3).allSatisfy { list.mark(at: $0) == .done })
    }

    @Test func aFailureAfterTheInstallerFinishedFailsTheLastLine() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.done(pairInfo()))
        list.failLast(.tokenNotSaved)
        #expect(list.mark(at: 0) == .done)
        #expect(list.mark(at: 1) == .done)
        #expect(list.mark(at: 2) == .failed)
        #expect(list.failure == .tokenNotSaved)
    }

    @Test func logLinesAreKeptInOrderAndCapped() {
        var list = InstallChecklist()
        for k in 0..<500 {
            list.apply(.log("line \(k)"))
        }
        #expect(list.log.count == InstallChecklist.logLimit)
        #expect(list.log.last == "line 499")
    }

    @Test func aStepOfNoLineChangesNothing() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.download, "Downloading Bandito"))
        #expect((0..<3).allSatisfy { list.mark(at: $0) == .pending })
    }

    @Test func onlySshServersAreSyncedWithTheirUserAndPort() {
        let ssh = ServerConfig(name: "prod", endpoint: .ssh(target: "deploy@prod.example:2222", remotePort: 7878))
        let local = ServerConfig(name: "This Mac", endpoint: .local(socketPath: "/tmp/bandito.sock"))
        let payload = ServerSyncPayload.payload(for: [ssh, local])
        #expect(payload.servers.count == 1)
        #expect(payload.servers.first?.name == "prod")
        #expect(payload.servers.first?.endpoint == .ssh(host: "prod.example", user: "deploy", port: 2222))
    }
}
