import Foundation
import Testing

@testable import BanditoKit

@Suite struct AppUpdateRulesTests {
    typealias Phase = AppUpdateCenter.Phase

    static let phases: [Phase] = [
        .idle, .checking, .available(version: "1.2.3"), .downloading(fraction: nil), .downloading(fraction: 0.4),
        .preparing, .installing, .upToDate, .failed("boom"),
    ]

    // MARK: Share of the download

    @Test func fractionIsReceivedOverExpected() {
        #expect(AppUpdateRules.fraction(received: 50, expected: 200) == 0.25)
        #expect(AppUpdateRules.fraction(received: 0, expected: 200) == 0)
        #expect(AppUpdateRules.fraction(received: 200, expected: 200) == 1)
    }

    @Test func fractionIsNilWhenTheLengthIsUnknown() {
        #expect(AppUpdateRules.fraction(received: 0, expected: 0) == nil)
        #expect(AppUpdateRules.fraction(received: 1_000, expected: 0) == nil)
    }

    @Test func fractionIsClampedToZeroAndOne() {
        // A server that sends more than it announced must not push the bar past its end.
        #expect(AppUpdateRules.fraction(received: 300, expected: 200) == 1)
        #expect(AppUpdateRules.fraction(received: UInt64.max, expected: 1) == 1)
    }

    @Test func percentRoundsDownAndStaysInRange() {
        #expect(AppUpdateRules.percent(0) == 0)
        #expect(AppUpdateRules.percent(0.449) == 44)
        #expect(AppUpdateRules.percent(0.45) == 45)
        #expect(AppUpdateRules.percent(0.999) == 99)
        #expect(AppUpdateRules.percent(1) == 100)
        #expect(AppUpdateRules.percent(-0.5) == 0)
        #expect(AppUpdateRules.percent(7) == 100)
        #expect(AppUpdateRules.percent(nil) == nil)
        #expect(AppUpdateRules.percent(.nan) == nil)
        #expect(AppUpdateRules.percent(.infinity) == nil)
    }

    @Test func percentTextCarriesTheNumber() {
        #expect(AppUpdateRules.percentText(0.45)?.contains("45") == true)
        #expect(AppUpdateRules.percentText(nil) == nil)
    }

    @Test func shouldPublishOnlyWhenTheWholePercentChanges() {
        #expect(!AppUpdateRules.shouldPublish(old: 0.450, new: 0.455))
        #expect(!AppUpdateRules.shouldPublish(old: 0.450, new: 0.459))
        #expect(AppUpdateRules.shouldPublish(old: 0.450, new: 0.460))
        #expect(AppUpdateRules.shouldPublish(old: 0.99, new: 1))
        #expect(!AppUpdateRules.shouldPublish(old: nil, new: nil))
        #expect(AppUpdateRules.shouldPublish(old: nil, new: 0))
        #expect(AppUpdateRules.shouldPublish(old: 0.3, new: nil))
    }

    @Test func downloadCountsBytesAndNeverOverflows() {
        var download = AppUpdateDownload()
        #expect(download.fraction == nil)
        download.expect(1_000)
        download.receive(250)
        download.receive(250)
        #expect(download.fraction == 0.5)
        download.receive(UInt64.max)
        #expect(download.received == UInt64.max)
        #expect(download.fraction == 1)
        // A new download starts from zero.
        download.expect(400)
        #expect(download.received == 0)
        #expect(download.fraction == 0)
    }

    @Test func bytesWithoutAnnouncedLengthGiveNoFraction() {
        var download = AppUpdateDownload()
        download.receive(500)
        #expect(download.fraction == nil)
    }

    // MARK: Visibility and buttons by phase

    @Test func theBannerShowsInEveryPhaseButIdle() {
        for phase in Self.phases {
            #expect(AppUpdateRules.isVisible(phase) == (phase != .idle))
        }
    }

    @Test func busyMeansWaitingForTheUpdate() {
        let busy: [Phase] = [.checking, .downloading(fraction: nil), .downloading(fraction: 0.4), .preparing, .installing]
        for phase in Self.phases {
            #expect(AppUpdateRules.isBusy(phase) == busy.contains(phase))
        }
    }

    @Test func onlyAnOfferedVersionCanBeInstalled() {
        for phase in Self.phases {
            let expected: Bool
            if case .available = phase { expected = true } else { expected = false }
            #expect(AppUpdateRules.canInstall(phase) == expected)
        }
    }

    @Test func aCheckStartsFromRestDoneOrFailed() {
        #expect(AppUpdateRules.canCheck(.idle))
        #expect(AppUpdateRules.canCheck(.upToDate))
        #expect(AppUpdateRules.canCheck(.failed("x")))
        #expect(!AppUpdateRules.canCheck(.checking))
        #expect(!AppUpdateRules.canCheck(.available(version: "1")))
        #expect(!AppUpdateRules.canCheck(.downloading(fraction: nil)))
        #expect(!AppUpdateRules.canCheck(.preparing))
        #expect(!AppUpdateRules.canCheck(.installing))
    }

    @Test func theCrossIsGoneOnceTheInstallCannotBeTakenBack() {
        #expect(!AppUpdateRules.canDismiss(.idle))
        #expect(!AppUpdateRules.canDismiss(.preparing))
        #expect(!AppUpdateRules.canDismiss(.installing))
        #expect(AppUpdateRules.canDismiss(.available(version: "1")))
        #expect(AppUpdateRules.canDismiss(.checking))
        #expect(AppUpdateRules.canDismiss(.downloading(fraction: 0.5)))
        #expect(AppUpdateRules.canDismiss(.upToDate))
        #expect(AppUpdateRules.canDismiss(.failed("x")))
    }

    @Test func everyVisiblePhaseHasATitleAndIdleHasNone() {
        for phase in Self.phases {
            let title = AppUpdateRules.title(for: phase)
            #expect((title == nil) == (phase == .idle))
            if let title { #expect(!title.isEmpty) }
        }
    }

    @Test func theOfferedTitleNamesTheVersion() {
        #expect(AppUpdateRules.title(for: .available(version: "0.2.0"))?.contains("0.2.0") == true)
    }

    @Test func aFailureShowsItsReasonOrAHintWhenThereIsNone() {
        #expect(AppUpdateRules.subtitle(for: .failed("No route to host")) == "No route to host")
        let hint = AppUpdateRules.subtitle(for: .failed("  \n"))
        #expect(hint != nil && !hint!.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(AppUpdateRules.subtitle(for: .failed("")) == hint)
        #expect(AppUpdateRules.subtitle(for: .available(version: "1")) != nil)
        #expect(AppUpdateRules.subtitle(for: .checking) == nil)
        #expect(AppUpdateRules.subtitle(for: .idle) == nil)
    }

    @Test func spinnerOnlyWhereThereIsNoShareToShow() {
        #expect(AppUpdateRules.showsSpinner(.checking))
        #expect(AppUpdateRules.showsSpinner(.preparing))
        #expect(AppUpdateRules.showsSpinner(.installing))
        #expect(!AppUpdateRules.showsSpinner(.downloading(fraction: nil)))
        #expect(!AppUpdateRules.showsSpinner(.available(version: "1")))
        #expect(!AppUpdateRules.showsSpinner(.idle))
    }

    @Test func layoutKeyIgnoresTheShareAndTheVersion() {
        #expect(AppUpdateRules.layoutKey(.downloading(fraction: nil)) == AppUpdateRules.layoutKey(.downloading(fraction: 0.7)))
        #expect(AppUpdateRules.layoutKey(.available(version: "1")) == AppUpdateRules.layoutKey(.available(version: "2")))
        #expect(AppUpdateRules.layoutKey(.failed("a")) == AppUpdateRules.layoutKey(.failed("b")))
        // Every kind of phase has its own layout.
        let kinds: [Phase] = [.idle, .checking, .available(version: "1"), .downloading(fraction: nil), .preparing, .installing, .upToDate, .failed("x")]
        #expect(Set(kinds.map(AppUpdateRules.layoutKey)).count == kinds.count)
    }

    @Test func badgeSymbolFollowsThePhase() {
        #expect(AppUpdateRules.symbol(for: .upToDate) == "checkmark.circle.fill")
        #expect(AppUpdateRules.symbol(for: .failed("x")) == "exclamationmark.triangle.fill")
        #expect(AppUpdateRules.symbol(for: .available(version: "1")) == "arrow.down.circle.fill")
        #expect(AppUpdateRules.symbol(for: .downloading(fraction: nil)) == "arrow.down.circle.fill")
    }

    // MARK: Release notes link

    @Test func releaseNotesLinkPointsAtTheTag() {
        #expect(
            AppUpdateRules.releaseNotesURL(version: "0.2.0")?.absoluteString
                == "https://github.com/banditohq/bandito/releases/tag/v0.2.0")
        #expect(
            AppUpdateRules.releaseNotesURL(version: "0.2.0-beta.1")?.absoluteString
                == "https://github.com/banditohq/bandito/releases/tag/v0.2.0-beta.1")
    }

    @Test func releaseNotesLinkRefusesOddVersionStrings() {
        #expect(AppUpdateRules.releaseNotesURL(version: "") == nil)
        #expect(AppUpdateRules.releaseNotesURL(version: "1.0/../x") == nil)
        #expect(AppUpdateRules.releaseNotesURL(version: "1.0 beta") == nil)
        #expect(AppUpdateRules.releaseNotesURL(version: "1.0?x=1") == nil)
        #expect(AppUpdateRules.releaseNotesURL(version: "1.0#a") == nil)
    }

    @Test func releaseNotesLinkOnlyForAnOfferedVersion() {
        #expect(AppUpdateRules.releaseNotesURL(for: .available(version: "0.2.0")) != nil)
        #expect(AppUpdateRules.releaseNotesURL(for: .checking) == nil)
        #expect(AppUpdateRules.releaseNotesURL(for: .idle) == nil)
    }
}
