import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// A server that answers from fields the test sets: connection, busy agents, and the daemon version it reports.
@MainActor
final class FakeUpgradeServer: LocalUpgradeServer {
    let serverID = UUID()
    var isThisMacServer = true
    var isConnectedNow = true
    var hasBusyAgents = false
    var runningVersion: String? = "0.1.1"
}

/// An installer that counts the upgrades. A successful upgrade makes the fake server report the bundled version.
@MainActor
final class FakeReplacer: DaemonReplacing {
    var bundled: String? = "0.1.2"
    var upgrades = 0
    var bundledReads = 0
    var failNextUpgrade = false
    var reportsNewVersion = true
    weak var server: FakeUpgradeServer?

    func bundledVersion() async -> String? {
        bundledReads += 1
        return bundled
    }

    func upgrade() async throws {
        upgrades += 1
        if failNextUpgrade {
            failNextUpgrade = false
            throw InstallError.serviceFailed("launchctl refused")
        }
        if reportsNewVersion { server?.runningVersion = bundled }
    }
}

@MainActor
@Suite struct LocalDaemonUpgradeModelTests {
    private func setUp(
        returnTimeout: Duration = .seconds(5), isQA: Bool = false
    ) -> (LocalDaemonUpgradeModel, FakeUpgradeServer, FakeReplacer) {
        let server = FakeUpgradeServer()
        let replacer = FakeReplacer()
        replacer.server = server
        let model = LocalDaemonUpgradeModel(
            installer: replacer, pollInterval: .milliseconds(1), returnTimeout: returnTimeout, isQA: isQA)
        return (model, server, replacer)
    }

    /// Waits until `condition` holds, for up to two seconds. Returns whether it did.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aFreeServerIsUpgradedOnce() async {
        let (model, server, replacer) = setUp()
        await model.upgradeIfNeeded(server)
        #expect(replacer.upgrades == 1)
        #expect(model.phase == .idle)
        #expect(server.runningVersion == "0.1.2")
    }

    @Test func busyAgentsDeferTheUpgradeWithoutUsingUpTheAttempt() async {
        let (model, server, replacer) = setUp()
        server.hasBusyAgents = true

        await model.upgradeIfNeeded(server)
        #expect(model.phase == .waitingForAgents(serverID: server.serverID, version: "0.1.2"))
        #expect(replacer.upgrades == 0)

        server.hasBusyAgents = false
        #expect(await eventually { replacer.upgrades == 1 })
        #expect(await eventually { model.phase == .idle })
        #expect(replacer.upgrades == 1)
    }

    @Test func theUpgradeAfterTheWaitIsStillOneAttempt() async {
        let (model, server, replacer) = setUp()
        server.hasBusyAgents = true
        await model.upgradeIfNeeded(server)
        server.hasBusyAgents = false
        #expect(await eventually { replacer.upgrades == 1 })

        // The daemon did not take the new version: a later connect does not start a second attempt in this launch.
        server.runningVersion = "0.1.1"
        await model.upgradeIfNeeded(server)
        #expect(replacer.upgrades == 1)
    }

    @Test func aServerThatIsNotConnectedIsNotUpgradedYet() async {
        let (model, server, replacer) = setUp()
        server.isConnectedNow = false
        await model.upgradeIfNeeded(server)
        #expect(replacer.upgrades == 0)
        #expect(model.phase == .idle)
    }

    @Test func anotherDaemonOrAnUpToDateOneIsLeftAlone() async {
        let (model, server, replacer) = setUp()
        server.isThisMacServer = false
        await model.upgradeIfNeeded(server)
        server.isThisMacServer = true
        server.runningVersion = "0.1.2"
        await model.upgradeIfNeeded(server)
        #expect(replacer.upgrades == 0)
        #expect(model.phase == .idle)
    }

    @Test func aFailedUpgradeShowsItsErrorAndRetryRunsIt() async {
        let (model, server, replacer) = setUp()
        replacer.failNextUpgrade = true
        await model.upgradeIfNeeded(server)
        guard case .failed = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
        await model.retry(server)
        #expect(replacer.upgrades == 2)
        #expect(model.phase == .idle)
    }

    @Test func aRetryWhileDisconnectedKeepsTheFailureAndRunsOnConnect() async {
        let (model, server, replacer) = setUp()
        replacer.failNextUpgrade = true
        await model.upgradeIfNeeded(server)
        #expect(replacer.upgrades == 1)

        server.isConnectedNow = false
        await model.retry(server)
        #expect(model.phase == .failed(serverID: server.serverID, UserFacingMessage(text: L10n.Server.LocalUpgrade.notConnected, canRetry: true)))
        #expect(replacer.upgrades == 1)

        server.isConnectedNow = true
        #expect(await eventually { replacer.upgrades == 2 })
        #expect(await eventually { model.phase == .idle })
    }

    @Test func updateNowRunsWhileAgentsWork() async {
        let (model, server, replacer) = setUp()
        server.hasBusyAgents = true
        await model.upgradeIfNeeded(server)
        #expect(model.phase == .waitingForAgents(serverID: server.serverID, version: "0.1.2"))

        await model.updateNow(server)
        #expect(replacer.upgrades == 1)
        #expect(model.phase == .idle)
    }

    @Test func updateNowWhileDisconnectedWaitsForTheConnection() async {
        let (model, server, replacer) = setUp()
        server.hasBusyAgents = true
        await model.upgradeIfNeeded(server)

        server.isConnectedNow = false
        await model.updateNow(server)
        #expect(model.phase == .failed(serverID: server.serverID, UserFacingMessage(text: L10n.Server.LocalUpgrade.notConnected, canRetry: true)))
        #expect(replacer.upgrades == 0)

        server.isConnectedNow = true
        #expect(await eventually { replacer.upgrades == 1 })
    }

    @Test func aDaemonThatNeverComesBackOnTheNewVersionTimesOut() async {
        let (model, server, replacer) = setUp(returnTimeout: .milliseconds(30))
        replacer.reportsNewVersion = false
        await model.upgradeIfNeeded(server)
        #expect(model.phase == .failed(serverID: server.serverID, UserFacingMessage(
            text: L10n.Server.LocalUpgrade.timedOut(version: "0.1.2"), canRetry: true)))
    }

    @Test func aQACopyNeverReadsTheBundleOrUpgrades() async {
        let (model, server, replacer) = setUp(isQA: true)
        await model.upgradeIfNeeded(server)
        #expect(replacer.bundledReads == 0)
        #expect(replacer.upgrades == 0)
        #expect(model.phase == .idle)
    }

    @Test func aServerThatIsNotThisMacIsNotReadAtAll() async {
        let (model, server, replacer) = setUp()
        server.isThisMacServer = false
        await model.upgradeIfNeeded(server)
        #expect(replacer.bundledReads == 0)
    }

    @Test func thePhaseNamesTheServerItIsAbout() async {
        let (model, server, _) = setUp()
        server.hasBusyAgents = true
        await model.upgradeIfNeeded(server)
        #expect(model.phase.serverID == server.serverID)
        #expect(LocalDaemonUpgradeModel.Phase.idle.serverID == nil)
    }

    @Test func forgettingTheServerEndsItsWaitingUpgrade() async {
        let (model, server, replacer) = setUp()
        server.hasBusyAgents = true
        await model.upgradeIfNeeded(server)
        model.forget(serverID: server.serverID)
        #expect(model.phase == .idle)

        server.hasBusyAgents = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(replacer.upgrades == 0)
    }
}
