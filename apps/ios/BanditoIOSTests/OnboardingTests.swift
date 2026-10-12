import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The rules of the first run's steps: where Next, Back and Skip lead, and what a restored position may be.
@MainActor
@Suite struct OnboardingRulesTests {
    private let welcome = OnboardingPosition(step: .welcome, card: 0)
    private let features0 = OnboardingPosition(step: .features, card: 0)
    private let features2 = OnboardingPosition(step: .features, card: 2)
    private let connect = OnboardingPosition(step: .connect, card: 0)

    @Test func nextWalksWelcomeThenTheThreeCardsThenConnect() {
        var position = OnboardingPosition.start
        var visited = [position]
        while let next = OnboardingRules.forward(from: position) {
            visited.append(next)
            position = next
        }
        #expect(visited == [welcome, features0, OnboardingPosition(step: .features, card: 1), features2, connect])
        #expect(OnboardingRules.forward(from: connect) == nil, "the last step has no next")
    }

    @Test func backUndoesNextOnEveryStep() {
        for position in [welcome, features0, OnboardingPosition(step: .features, card: 1), features2] {
            let next = OnboardingRules.forward(from: position)
            #expect(next.flatMap { OnboardingRules.back(from: $0) } == position)
        }
    }

    @Test func theFirstStepHasNoBack() {
        #expect(OnboardingRules.back(from: welcome) == nil)
        #expect(OnboardingRules.back(from: features0) == welcome)
        #expect(OnboardingRules.back(from: connect) == features2, "Back from connect returns to the last card")
    }

    @Test func skipAndHaveServerGoToConnectWithoutStepsInBetween() {
        #expect(OnboardingRules.skipToConnect() == connect)
    }

    @Test func restoreUsesTheSavedStepAndClampsTheCard() {
        #expect(OnboardingRules.restore(step: "features", card: 1) == OnboardingPosition(step: .features, card: 1))
        #expect(OnboardingRules.restore(step: "features", card: 9) == features2)
        #expect(OnboardingRules.restore(step: "features", card: -4) == features0)
        #expect(OnboardingRules.restore(step: "connect", card: 2) == connect, "a card means nothing on connect")
    }

    @Test func restoreFallsBackToTheStartForWhatItDoesNotKnow() {
        #expect(OnboardingRules.restore(step: nil, card: nil) == .start)
        #expect(OnboardingRules.restore(step: "cli", card: 1) == .start, "steps 4 to 6 are not built yet")
        #expect(OnboardingRules.restore(step: "features", card: nil) == features0)
    }

    @Test func stepsHaveTheirPlaceInTheProgressLine() {
        #expect(OnboardingStep.allCases.map(\.index) == [0, 1, 2])
        #expect(OnboardingStep.count == 3)
    }
}

/// The saved progress and the flow's visibility, on a throwaway suite per test.
@MainActor
@Suite struct OnboardingStoreTests {
    private func suite() -> UserDefaults {
        let name = "dev.bandito.ios.tests.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func progressSurvivesAFreshLaunch() {
        let defaults = suite()
        OnboardingStore(defaults: defaults, forced: false).show(OnboardingPosition(step: .features, card: 2))
        let relaunched = OnboardingStore(defaults: defaults, forced: false)
        #expect(relaunched.position == OnboardingPosition(step: .features, card: 2))
    }

    @Test func aPairedServerHidesTheFlow() {
        let store = OnboardingStore(defaults: suite(), forced: false)
        #expect(store.shows(hasServers: false))
        #expect(!store.shows(hasServers: true))
    }

    @Test func aFinishedFlowIsNotShownAgain() {
        let defaults = suite()
        OnboardingStore(defaults: defaults, forced: false).markCompleted()
        let relaunched = OnboardingStore(defaults: defaults, forced: false)
        #expect(relaunched.completed)
        #expect(!relaunched.shows(hasServers: false), "after the first server the flow never comes back")
    }

    @Test func theForcedFlowShowsWhateverTheServers() {
        let store = OnboardingStore(defaults: suite(), forced: true)
        #expect(store.shows(hasServers: true))
    }

    @Test func aLaunchCanStartAtAStepAndACard() {
        let start = OnboardingStore.requestedStart(in: ["-onboarding", "-onboarding-step", "features", "-onboarding-card", "2"])
        #expect(start == OnboardingPosition(step: .features, card: 2))
        #expect(OnboardingStore.requestedStart(in: ["-onboarding-step", "connect"]) == OnboardingPosition(step: .connect, card: 0))
        #expect(OnboardingStore.requestedStart(in: ["-onboarding-step", "cli"]) == nil)
        #expect(OnboardingStore.requestedStart(in: ["-demo"]) == nil)
    }
}

/// The night shift's timeline: events in order, the morning last, then the cycle starts again.
@MainActor
@Suite struct NightShiftTests {
    @Test func eventsAreInsideTheShiftAndInOrder() {
        let minutes = NightShift.eventMinutes
        #expect(minutes == minutes.sorted())
        #expect(minutes.allSatisfy { $0 > 0 && $0 < NightShift.lengthMinutes })
        #expect(NightShift.fraction(ofMinute: 0) == 0)
        #expect(NightShift.fraction(ofMinute: NightShift.lengthMinutes) == 1)
        #expect(NightShift.fraction(ofMinute: NightShift.lengthMinutes * 2) == 1, "the strip never runs past 08:00")
    }

    @Test func eventsLightOneByOneAndTheMorningComesLast() {
        #expect(NightShift.state(at: 0).lit == 0)
        #expect(NightShift.state(at: NightShift.firstEventAt).lit == 1)
        let beforeMorning = NightShift.state(at: NightShift.morningAt - 0.01)
        #expect(beforeMorning.lit == NightShift.eventMinutes.count)
        #expect(!beforeMorning.morning)
        #expect(NightShift.state(at: NightShift.morningAt).morning)
    }

    @Test func litEventsNeverGoBackWithinACycle() {
        var previous = 0
        var time = 0.0
        while time < NightShift.morningAt {
            let lit = NightShift.state(at: time).lit
            #expect(lit >= previous)
            previous = lit
            time += 0.2
        }
    }

    @Test func theCycleStartsAgainAfterTheMorningHolds() {
        let again = NightShift.state(at: NightShift.cycleSeconds + 0.1)
        #expect(again.lit == 0)
        #expect(!again.morning)
    }
}

/// The figure of lights: its size, its place on the design grid, the open mask band, and the timing of the flight.
@MainActor
@Suite struct RaccoonLightsTests {
    private let lights = RaccoonLights.make()

    @Test func theFigureHasAboutTwoThousandLights() {
        #expect((1500...2500).contains(lights.count), "got \(lights.count)")
    }

    @Test func theFigureIsTheSameEveryTime() {
        #expect(RaccoonLights.make() == lights)
    }

    @Test func lightsRestOnTheGridAndStartOutsideTheFigure() {
        for light in lights {
            #expect((0...RaccoonLights.gridEdge).contains(light.x) && (0...RaccoonLights.gridEdge).contains(light.y))
            #expect(RaccoonLights.region(x: light.x, y: light.y) == light.region)
            let distance = hypot(light.startX - 26, light.startY - 27)
            #expect(distance >= 23.9 && distance <= 32.1, "lights start on a ring around the figure")
        }
    }

    @Test func theMaskStaysOpenAndTheEyesAreLit() {
        for light in lights where light.region != .eye {
            #expect(!RaccoonLights.inMask(x: light.x, y: light.y))
        }
        #expect(lights.contains { $0.region == .eye }, "the eyes are lit")
        #expect(RaccoonLights.inMask(x: 26, y: 26), "the mask is the avatar's mask, the eyes sit in it")
    }

    @Test func everyFlightEndsInsideTheAssembly() {
        for light in lights {
            #expect(light.delay >= 0)
            #expect(light.delay + light.duration <= RaccoonLights.assemblyDuration + 1e-9)
            #expect(light.alpha > 0 && light.alpha <= 1)
        }
    }

    @Test func eyesArriveAfterTheFigure() {
        let figureLast = lights.filter { $0.region != .eye }.map(\.delay).max() ?? 0
        let eyesFirst = lights.filter { $0.region == .eye }.map(\.delay).min() ?? 0
        #expect(eyesFirst > figureLast)
    }

    /// Building the figure (one layer per light, one grouped animation each) happens on the main thread once per
    /// appearance; it must stay well inside a frame. The measured time is printed for the review.
    @Test func buildingTheFigureStaysWellInsideAFrame() {
        let view = RaccoonLightsView(frame: CGRect(x: 0, y: 0, width: 280, height: 280))
        let start = ContinuousClock.now
        view.layoutIfNeeded()
        let elapsed = ContinuousClock.now - start
        print("RaccoonLights build (\(lights.count) lights): \(elapsed)")
        #expect(elapsed < .milliseconds(250))
    }

    @Test func theHaltonSequenceAndNoiseStayInRange() {
        #expect(RaccoonLights.halton(1, base: 2) == 0.5)
        #expect(RaccoonLights.halton(2, base: 3) == 2.0 / 3.0)
        for seed in 0..<1000 {
            let value = RaccoonLights.noise(seed, 3)
            #expect(value >= 0 && value < 1)
        }
    }
}
