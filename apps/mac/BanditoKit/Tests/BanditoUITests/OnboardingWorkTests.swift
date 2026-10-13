#if os(macOS) && DEBUG
import AppKit
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

extension ScreenWorkSuites {
    /// The first-run flow does no more work than it needs. The counts are of bodies built (never time), in a window
    /// nobody sees: no window on any screen. A step change builds the step that comes, not the ones around it; the live
    /// cards build only the card on screen and run no timer that rebuilds anything while it stands still.
    @MainActor @Suite(.serialized) struct OnboardingWorkTests {
        private func check(
            _ counts: [String: Int], _ budgets: [WorkBudget], _ scenario: String,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            if WorkBudgetTests.probe { print("WORKBUDGET \(scenario): \(counts.sorted { $0.key < $1.key })") }
            for message in WorkBudget.excesses(counts, budgets, scenario: scenario) {
                Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
            }
        }

        private static let flow = "the flow's step switch (Onboarding/OnboardingFlow.swift): a step must not read what another step reads"

        @Test func aStepChangeBuildsOnlyTheStepThatComes() async {
            let world = OnboardingWorld(step: .runtimes)
            await world.prepare(readServerSteps: true)
            world.show()
            defer { Task { await world.stop() } }

            // Runtimes to the crew: the crew step is built, the runtimes step and the ones around it are not.
            let toCrew = world.count { world.onboarding.advance() }
            check(
                toCrew,
                [
                    WorkBudget(counter: "OnboardingRuntimesStep", limit: 0, lookAt: Self.flow),
                    WorkBudget(counter: "OnboardingFeaturesStep", limit: 0, lookAt: Self.flow),
                    WorkBudget(counter: "OnboardingTaskStep", limit: 0, lookAt: Self.flow),
                    WorkBudget(counter: "OnboardingCrewStep", limit: 6, lookAt: "CrewStep (Onboarding/Crew/CrewStep.swift)"),
                    // Five cards (four teams and one agent), built once each on arrival, a second pass at most.
                    WorkBudget(counter: "OnboardingCrewOption", limit: 10, lookAt: "CrewOptionCard is Equatable"),
                ], "runtimes to crew")
            #expect(toCrew["OnboardingCrewStep", default: 0] >= 1, "the crew step is on screen")

            // Crew to the first task: the crew step is gone and does not build again.
            let toTask = world.count { world.onboarding.advance() }
            check(
                toTask,
                [
                    WorkBudget(counter: "OnboardingCrewStep", limit: 0, lookAt: Self.flow),
                    WorkBudget(counter: "OnboardingRuntimesStep", limit: 0, lookAt: Self.flow),
                    WorkBudget(counter: "OnboardingTaskStep", limit: 6, lookAt: "FirstTaskStep (Onboarding/Task/FirstTaskStep.swift)"),
                ], "crew to task")

            // Back: the crew step comes again, the task step does not stay behind.
            let back = world.count { world.onboarding.back() }
            check(back, [WorkBudget(counter: "OnboardingTaskStep", limit: 0, lookAt: Self.flow)], "task back to crew")
            #expect(back["OnboardingCrewStep", default: 0] >= 1)
        }

        @Test func theCrewStepIsQuietWhenNothingChanges() async {
            let world = OnboardingWorld(step: .team)
            await world.prepare(readServerSteps: true)
            world.show()
            defer { Task { await world.stop() } }
            let idle = world.count {}
            check(
                idle,
                [
                    WorkBudget(counter: "OnboardingCrewStep", limit: 0, lookAt: "a timer or a read that changes without the person: CrewModel"),
                    WorkBudget(counter: "OnboardingCrewPreview", limit: 0, lookAt: "CrewStep.preview"),
                ], "crew idle")
        }

        @Test func choosingATeamDoesNotRebuildTheOtherCards() async {
            let world = OnboardingWorld(step: .team)
            await world.prepare(readServerSteps: true)
            world.show()
            defer { Task { await world.stop() } }
            let crew = world.session!.crew
            let counts = world.count { crew.select(.team("server-duty")) }
            // One choice changes two cards (the one that was chosen and the one that is now), never all of them.
            check(
                counts,
                [WorkBudget(counter: "OnboardingCrewOption", limit: 4, lookAt: "CrewOptionCard (Onboarding/Crew/CrewStep.swift) is Equatable: what it reads must not change")],
                "choosing a team")
        }

        @Test func onlyTheCardOnScreenIsBuiltAndAStillCardStaysQuiet() {
            let world = OnboardingWorld(step: .features, card: 0)
            world.show()
            // Card one has no timer: a quiet stretch builds nothing.
            let idle = world.count {}
            check(
                idle,
                [
                    WorkBudget(counter: "OnboardingFeatureCard", limit: 0, lookAt: "the crew card (Onboarding/Features/FeaturesStep.swift): its moods are layers, it needs no timer"),
                    WorkBudget(counter: "OnboardingFeaturesStep", limit: 0, lookAt: "FeaturesStep"),
                ], "crew card idle")

            // Turning to the next card builds that one card, once or twice, and the first is gone.
            let turn = world.count { world.onboarding.showCard(1) }
            check(
                turn,
                [WorkBudget(counter: "OnboardingFeatureCard", limit: 4, lookAt: "FeatureCardView: a switch builds the card shown only")],
                "turn to the approval card")
            #expect(turn["OnboardingFeatureCard", default: 0] >= 1)
            world.window.contentView = nil
        }

        @Test func theNightCardWakesOnItsEventsAndNotPerFrame() {
            // The strip changes six times in a cycle of about eight seconds; the card sleeps between them.
            var wakes = 0
            var t = 0.0
            while t < 60 {
                t += NightShift.secondsToNextChange(from: t)
                wakes += 1
            }
            #expect(wakes <= Int(60 / NightShift.cycleSeconds * 6) + 7)
            #expect(wakes >= Int(60 / NightShift.cycleSeconds * 6) - 1)
        }
    }
}
#endif
