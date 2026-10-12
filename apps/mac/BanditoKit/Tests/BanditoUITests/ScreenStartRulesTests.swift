import BanditoL10n
import Testing

@testable import BanditoUI

/// The states of "Запустить экран": every case has one phase, so a start never goes silent.
@Suite struct ScreenStartRulesTests {
    private let failure = UserFacingMessage(text: "Не удалось", canRetry: true)

    private func facts(
        supported: Bool = true, startInFlight: Bool = false, running: Bool = false, hasFrame: Bool = false,
        frameTimedOut: Bool = false, error: UserFacingMessage? = nil, missing: [String] = [], installing: Bool = false
    ) -> ScreenStartRules.Facts {
        ScreenStartRules.Facts(
            supported: supported, startInFlight: startInFlight, running: running, hasFrame: hasFrame,
            frameTimedOut: frameTimedOut, error: error, missing: missing, installing: installing)
    }

    // MARK: Reading a failed start

    @Test func missingComponentWithOneNameIsTheList() {
        let result = ScreenStartRules.failure(
            reason: "missing_component", components: ["x11vnc"], component: "x11vnc", message: "missing components: x11vnc")
        #expect(result == .missingComponents(["x11vnc"]))
    }

    @Test func missingComponentsKeepTheDaemonsOrder() {
        let result = ScreenStartRules.failure(
            reason: "missing_component", components: ["x11vnc", "xdotool"], component: "x11vnc", message: "m")
        #expect(result == .missingComponents(["x11vnc", "xdotool"]))
    }

    @Test func anOlderDaemonWithOnlyComponentGivesOneName() {
        let result = ScreenStartRules.failure(
            reason: "missing_component", components: [], component: "xdotool", message: "missing component: xdotool")
        #expect(result == .missingComponents(["xdotool"]))
    }

    @Test func missingComponentWithoutAnyNameIsAGenericFailure() {
        let result = ScreenStartRules.failure(reason: "missing_component", components: [], component: nil, message: "m")
        #expect(result == .failed(UserFacingMessage(text: L10n.Screen.startFailed, technical: "m", canRetry: true)))
    }

    @Test func startFailedIsTheSentenceWithTheDaemonsMessageUnderDetails() {
        let result = ScreenStartRules.failure(
            reason: "start_failed", components: [], component: nil, message: "cannot start the screen: Xvfb exited")
        #expect(
            result
                == .failed(
                    UserFacingMessage(
                        text: L10n.Screen.startFailed, technical: "cannot start the screen: Xvfb exited", canRetry: true)))
    }

    @Test func anyOtherReasonIsTheSameSentence() {
        let result = ScreenStartRules.failure(reason: "user_controls", components: [], component: nil, message: "busy")
        #expect(result == .failed(UserFacingMessage(text: L10n.Screen.startFailed, technical: "busy", canRetry: true)))
    }

    @Test func installTakesTheNamedProgramsThenTheRestOfTheFeature() {
        let ids = ScreenStartRules.installIds(
            required: ["x11vnc", "xdotool"], feature: ["xvfb", "x11vnc", "xdotool", "window_manager", "fonts"])
        #expect(ids == ["x11vnc", "xdotool", "xvfb", "window_manager", "fonts"])
    }

    @Test func installWithNothingElseMissingIsTheNamedProgramsOnly() {
        #expect(ScreenStartRules.installIds(required: ["xdotool"], feature: []) == ["xdotool"])
    }

    // MARK: Phases

    @Test func missingProgramsAreNamedInTheirOwnPhase() {
        #expect(ScreenStartRules.phase(facts(missing: ["x11vnc", "xdotool"])) == .missingComponents(["x11vnc", "xdotool"]))
    }

    @Test func aRunningInstallBeatsTheMissingList() {
        let phase = ScreenStartRules.phase(facts(missing: ["x11vnc"], installing: true))
        #expect(phase == .installing)
    }

    @Test func aCallInFlightBeatsTheMissingList() {
        #expect(ScreenStartRules.phase(facts(startInFlight: true, missing: ["x11vnc"])) == .starting)
    }

    @Test func missingProgramsBeatAFailureSentence() {
        #expect(ScreenStartRules.phase(facts(error: failure, missing: ["x11vnc"])) == .missingComponents(["x11vnc"]))
    }

    @Test func noMissingProgramsLeavesTheStartButtonAsItWas() {
        #expect(ScreenStartRules.phase(facts(missing: [])) == .idle)
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
