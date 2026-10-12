import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct AppUpdateCenterTests {
    /// Counts what the bound actions were asked to do.
    final class Calls {
        var install = 0
        var dismiss = 0
        var check = 0
    }

    static func bound(_ center: AppUpdateCenter) -> Calls {
        let calls = Calls()
        center.bind(
            install: { calls.install += 1 },
            dismiss: { calls.dismiss += 1 },
            check: { calls.check += 1 })
        return calls
    }

    @Test func startsIdle() {
        #expect(AppUpdateCenter().phase == .idle)
    }

    @Test func installOnlyRunsWhileAVersionIsOffered() {
        let center = AppUpdateCenter()
        let calls = Self.bound(center)
        center.install()
        #expect(calls.install == 0)
        center.setPhase(.available(version: "1.0.0"))
        center.install()
        #expect(calls.install == 1)
        // The driver moves on at once; a second click lands on a phase that cannot install.
        center.setPhase(.downloading(fraction: nil))
        center.install()
        #expect(calls.install == 1)
    }

    @Test func checkRunsFromRestDoneAndFailedOnly() {
        let center = AppUpdateCenter()
        let calls = Self.bound(center)
        center.check()
        center.setPhase(.failed("x"))
        center.check()
        center.setPhase(.upToDate)
        center.check()
        #expect(calls.check == 3)
        center.setPhase(.checking)
        center.check()
        center.setPhase(.available(version: "1"))
        center.check()
        #expect(calls.check == 3)
    }

    @Test func dismissGoesToTheBoundAction() {
        let center = AppUpdateCenter()
        let calls = Self.bound(center)
        center.setPhase(.available(version: "1"))
        center.dismiss()
        #expect(calls.dismiss == 1)
        center.setPhase(.installing)
        center.dismiss()
        #expect(calls.dismiss == 1)
        center.setPhase(.idle)
        center.dismiss()
        #expect(calls.dismiss == 1)
    }

    @Test func dismissWithoutADriverJustClears() {
        let center = AppUpdateCenter()
        center.setPhase(.failed("x"))
        center.dismiss()
        #expect(center.phase == .idle)
    }

    @Test func actionsWithoutADriverDoNothing() {
        let center = AppUpdateCenter()
        center.install()
        center.check()
        #expect(center.phase == .idle)
    }

    @Test func downloadShareMovesOnlyWhenThePercentChanges() {
        let center = AppUpdateCenter()
        center.setPhase(.downloading(fraction: nil))
        center.updateDownload(fraction: 0.100)
        #expect(center.phase == .downloading(fraction: 0.100))
        // Same whole percent: the stored value stays, nothing is written.
        center.updateDownload(fraction: 0.105)
        #expect(center.phase == .downloading(fraction: 0.100))
        center.updateDownload(fraction: 0.110)
        #expect(center.phase == .downloading(fraction: 0.110))
    }

    @Test func downloadShareIsIgnoredOutsideADownload() {
        let center = AppUpdateCenter()
        center.updateDownload(fraction: 0.5)
        #expect(center.phase == .idle)
        center.setPhase(.available(version: "1"))
        center.updateDownload(fraction: 0.5)
        #expect(center.phase == .available(version: "1"))
        // A late chunk after the person cancelled must not bring the banner back.
        center.setPhase(.idle)
        center.updateDownload(fraction: 0.9)
        #expect(center.phase == .idle)
    }

    @Test func upToDateGoesBackToIdleByItself() async throws {
        let center = AppUpdateCenter(upToDateDelay: .milliseconds(40))
        center.setPhase(.upToDate)
        #expect(center.phase == .upToDate)
        #expect(await phaseBecomes(.idle, in: center))
    }

    @Test func aNewPhaseCancelsTheUpToDateTimer() async throws {
        let center = AppUpdateCenter(upToDateDelay: .milliseconds(60))
        center.setPhase(.upToDate)
        center.setPhase(.checking)
        try await Task.sleep(for: .milliseconds(400))
        #expect(center.phase == .checking)
    }

    @Test func aSecondUpToDateRestartsTheTimerFromTheNewPhase() async throws {
        let center = AppUpdateCenter(upToDateDelay: .milliseconds(150))
        center.setPhase(.upToDate)
        center.setPhase(.checking)
        center.setPhase(.upToDate)
        #expect(await phaseBecomes(.idle, in: center))
    }

    /// Waits for the phase, up to a deadline long enough for a busy CI machine, instead of a fixed sleep.
    private func phaseBecomes(
        _ wanted: AppUpdateCenter.Phase, in center: AppUpdateCenter, within limit: Duration = .seconds(30)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if center.phase == wanted { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return center.phase == wanted
    }
}
