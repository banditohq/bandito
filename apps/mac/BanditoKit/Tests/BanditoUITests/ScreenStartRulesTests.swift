import Testing

@testable import BanditoUI

/// The states of "Запустить экран": every case has one phase, so a start never goes silent.
@Suite struct ScreenStartRulesTests {
    private let failure = UserFacingMessage(text: "Не удалось", canRetry: true)

    private func facts(
        supported: Bool = true, startInFlight: Bool = false, running: Bool = false, hasFrame: Bool = false,
        frameTimedOut: Bool = false, error: UserFacingMessage? = nil
    ) -> ScreenStartRules.Facts {
        ScreenStartRules.Facts(
            supported: supported, startInFlight: startInFlight, running: running, hasFrame: hasFrame,
            frameTimedOut: frameTimedOut, error: error)
    }

    @Test func oldDaemonWithoutTheFeatureNeedsAnUpdate() {
        #expect(ScreenStartRules.phase(facts(supported: false)) == .needsUpdate)
    }

    @Test func missingFeatureWinsOverAnyOtherState() {
        let busy = facts(supported: false, startInFlight: true, running: true, frameTimedOut: true, error: failure)
        #expect(ScreenStartRules.phase(busy) == .needsUpdate)
    }

    @Test func startInFlightShowsStarting() {
        #expect(ScreenStartRules.phase(facts(startInFlight: true)) == .starting)
    }

    @Test func asleepWithoutErrorIsIdle() {
        #expect(ScreenStartRules.phase(facts()) == .idle)
    }

    @Test func failedStartShowsTheFailure() {
        #expect(ScreenStartRules.phase(facts(error: failure)) == .failed(failure))
    }

    @Test func runningWithoutPictureIsConnecting() {
        #expect(ScreenStartRules.phase(facts(running: true)) == .connecting)
    }

    @Test func runningWithoutPictureAfterTheTimeoutIsNoFrame() {
        #expect(ScreenStartRules.phase(facts(running: true, frameTimedOut: true)) == .noFrame)
    }

    @Test func aFailureBeatsTheTimeout() {
        let phase = ScreenStartRules.phase(facts(running: true, frameTimedOut: true, error: failure))
        #expect(phase == .failed(failure))
    }

    @Test func aPictureOnARunningScreenIsRunning() {
        #expect(ScreenStartRules.phase(facts(running: true, hasFrame: true)) == .running)
    }

    @Test func aPictureWithoutARunningScreenIsNotRunning() {
        #expect(ScreenStartRules.phase(facts(running: false, hasFrame: true)) == .idle)
    }

    @Test func aCallInFlightBeatsAStalePicture() {
        #expect(ScreenStartRules.phase(facts(startInFlight: true, running: true, hasFrame: true)) == .starting)
    }

    @Test func frameTimeoutIsTwentySeconds() {
        #expect(ScreenStartRules.frameTimeout == .seconds(20))
    }
}
