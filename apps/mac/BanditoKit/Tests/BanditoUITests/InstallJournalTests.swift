import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The install journal: every step and log line with its time, the full error at the end, and what the person can
/// do after a failure.
@Suite struct InstallJournalTests {
    private let stamp = try! Regex(#"^\d{2}:\d{2}:\d{2}  "#)

    @Test func stepsAndLogLinesAreStampedInOrder() {
        var list = InstallChecklist()
        let at = Date(timeIntervalSince1970: 1_000_000)
        list.apply(.step(.check, "Checking the system"), at: at)
        list.apply(.log("uname: Linux x86_64"), at: at)
        #expect(list.formattedLog.count == 2)
        #expect(list.formattedLog[0].firstMatch(of: stamp) != nil)
        #expect(list.formattedLog[0].hasSuffix("  Checking the system"))
        #expect(list.formattedLog[1].hasSuffix("  uname: Linux x86_64"))
        #expect(list.log == ["Checking the system", "uname: Linux x86_64"])
    }

    @Test func aStepWithoutTextAddsNoLine() {
        var list = InstallChecklist()
        list.apply(.step(.connect, ""))
        #expect(list.log.isEmpty)
    }

    @Test func aFailureEndsTheLogWithTheFullErrorText() {
        var list = InstallChecklist()
        list.apply(.step(.check, "Checking the system"))
        list.apply(.failed(.unsupportedPlatform("FreeBSD amd64")))
        let last = list.formattedLog.last ?? ""
        #expect(last.firstMatch(of: stamp) != nil)
        #expect(list.log.last == InstallError.unsupportedPlatform("FreeBSD amd64").errorDescription)
    }

    @Test func failLastAlsoEndsTheLogWithTheError() {
        var list = InstallChecklist(items: ChecklistItem.thisMac)
        list.apply(.step(.pair, "Connecting the app"))
        list.failLast(.tokenNotSaved)
        #expect(list.log.last == InstallError.tokenNotSaved.errorDescription)
    }

    @Test func theLogIsKeptToItsLimit() {
        var list = InstallChecklist()
        for index in 0..<(InstallChecklist.logLimit + 20) {
            list.apply(.log("line \(index)"))
        }
        #expect(list.log.count == InstallChecklist.logLimit)
        #expect(list.log.last == "line \(InstallChecklist.logLimit + 19)")
    }

    @Test func resetClearsTheJournalOfTheLastAttempt() {
        var list = InstallChecklist()
        list.apply(.step(.check, "Checking the system"))
        list.apply(.failed(.sshFailed(.refused)))
        list.reset()
        #expect(list.log.isEmpty)
    }

    // MARK: next steps

    @Test func detailsShownForTheTextualFailures() {
        #expect(InstallFailureAdvice.showsDetails(.sshFailed(.other("boom"))))
        #expect(InstallFailureAdvice.showsDetails(.step("unzip", detail: "no space")))
        #expect(InstallFailureAdvice.showsDetails(.io("disk full")))
        #expect(InstallFailureAdvice.showsDetails(.badResponse("status --json")))
        #expect(InstallFailureAdvice.showsDetails(.downloadFailed("timeout")))
        #expect(InstallFailureAdvice.showsDetails(.serviceFailed("warnings")))
        #expect(InstallFailureAdvice.showsDetails(.pairingFailed("code expired")))
        #expect(!InstallFailureAdvice.showsDetails(.sshFailed(.keyNotAccepted)))
        #expect(!InstallFailureAdvice.showsDetails(.localDaemonNotStarted))
    }

    @Test func aRejectedKeyPointsAtTheTerminalLogin() {
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.keyNotAccepted)) == .checkTerminalLogin)
    }

    @Test func aServerThatCannotBeReachedPointsAtAddressAndNetwork() {
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.timedOut)) == .checkServerReachable)
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.noRoute)) == .checkServerReachable)
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.unknownHost)) == .checkServerAddress)
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.refused)) == .checkSSHPort)
    }

    @Test func aDownloadFailurePointsAtGitHubAccess() {
        #expect(InstallFailureAdvice.nextStep(for: .downloadFailed("timeout")) == .checkGitHubAccess)
    }

    @Test func anUnsupportedSystemShowsWhatUnameSaid() {
        #expect(
            InstallFailureAdvice.nextStep(for: .unsupportedPlatform("Linux armv7l"))
                == .checkSystemSupport(uname: "Linux armv7l"))
    }

    @Test func aFailedSignatureCheckSaysToTryLater() {
        #expect(InstallFailureAdvice.nextStep(for: .releaseCheckFailed(.badSignature)) == .retryLater)
    }

    @Test func aStartFailurePointsAtTheLog() {
        #expect(InstallFailureAdvice.nextStep(for: .localDaemonNotStarted) == .readLog)
        #expect(InstallFailureAdvice.nextStep(for: .serviceFailed("x")) == .readLog)
    }

    @Test func aChangedHostKeyNeverOffersTrust() {
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.hostKeyChanged)) == .checkServerKey)
        #expect(InstallFailureAdvice.nextStep(for: .sshFailed(.hostKeyUnknown)) == .reviewFingerprint)
    }

    @Test func journalVersionKeepsGrowingAfterTheJournalIsTrimmed() {
        var list = InstallChecklist()
        for index in 0..<(InstallChecklist.logLimit + 5) {
            list.apply(.log("line \(index)"))
        }
        #expect(list.log.count == InstallChecklist.logLimit)
        #expect(list.journalVersion == InstallChecklist.logLimit + 5)
    }
}
