import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@Suite struct InstallChecklistTests {
    private func pairInfo() -> PairInfo {
        let server = ServerConfig(name: "prod-1", endpoint: .local(socketPath: "/tmp/bandito.sock"))
        return PairInfo(server: server, alreadyInstalled: false, warnings: [])
    }

    @Test func aFullRunMarksEveryItemDone() {
        var list = InstallChecklist()
        list.apply(.step("Checking the server"))
        list.apply(.step("Installing Bandito"))
        list.apply(.step("Starting the service"))
        list.apply(.step("Creating a pairing code"))
        list.apply(.step("Connecting"))
        list.apply(.done(pairInfo()))
        #expect(ChecklistItem.allCases.allSatisfy { list.mark(of: $0) == .done })
        #expect(list.failure == nil)
    }

    @Test func aStepRunsAndTheStepsBeforeItAreDone() {
        var list = InstallChecklist()
        list.apply(.step("Installing Bandito"))
        #expect(list.mark(of: .connect) == .done)
        #expect(list.mark(of: .check) == .done)
        #expect(list.mark(of: .install) == .running)
        #expect(list.mark(of: .service) == .pending)
    }

    @Test func aFailureStopsTheRunningItemAndLeavesTheRestPending() {
        var list = InstallChecklist()
        list.apply(.step("Checking the server"))
        list.apply(.step("Installing Bandito"))
        list.apply(.failed(.sshFailed(.hostKeyUnknown)))
        #expect(list.mark(of: .install) == .failed)
        #expect(list.mark(of: .check) == .done)
        #expect(list.mark(of: .service) == .pending)
        #expect(list.failure == .sshFailed(.hostKeyUnknown))
    }

    @Test func retryAfterAFailureStartsOverCleanly() {
        var list = InstallChecklist()
        list.apply(.step("Installing Bandito"))
        list.apply(.failed(.sshFailed(.keyNotAccepted)))
        list.reset()
        #expect(ChecklistItem.allCases.allSatisfy { list.mark(of: $0) == .pending })
        #expect(list.failure == nil)
        #expect(list.log.isEmpty)
        list.apply(.step("Checking the server"))
        list.apply(.step("Installing Bandito"))
        list.apply(.step("Starting the service"))
        list.apply(.done(pairInfo()))
        #expect(ChecklistItem.allCases.allSatisfy { list.mark(of: $0) == .done })
    }

    @Test func logLinesAreKeptInOrderAndCapped() {
        var list = InstallChecklist()
        for k in 0..<500 {
            list.apply(.log("line \(k)"))
        }
        #expect(list.log.count == InstallChecklist.logLimit)
        #expect(list.log.last == "line 499")
    }

    @Test func stepTextsMapToTheirItem() {
        #expect(InstallChecklist.item(forStep: "Checking the server") == .check)
        #expect(InstallChecklist.item(forStep: "Installing Bandito on this Mac") == .install)
        #expect(InstallChecklist.item(forStep: "Starting the service") == .service)
        #expect(InstallChecklist.item(forStep: "Creating a pairing code") == .app)
        #expect(InstallChecklist.item(forStep: "Connecting") == .app)
        #expect(InstallChecklist.item(forStep: "Something new") == nil)
    }

    @Test func theDownloadAndTheSignatureCheckCountAsInstalling() {
        #expect(InstallChecklist.item(forStep: "Downloading Bandito") == .install)
        #expect(InstallChecklist.item(forStep: "Verifying the Bandito release") == .install)
        var list = InstallChecklist()
        list.apply(.step("Checking the server"))
        list.apply(.step("Downloading Bandito"))
        list.apply(.step("Verifying the Bandito release"))
        #expect(list.mark(of: .check) == .done)
        #expect(list.mark(of: .install) == .running)
    }

    @Test func anUnknownStepChangesNothing() {
        var list = InstallChecklist()
        list.apply(.step("Something new"))
        #expect(ChecklistItem.allCases.allSatisfy { list.mark(of: $0) == .pending })
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
