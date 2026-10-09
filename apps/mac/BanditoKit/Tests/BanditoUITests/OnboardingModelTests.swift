import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct OnboardingModelTests {
    /// A private defaults suite per test, so nothing touches the real preferences.
    private func makeDefaults() -> UserDefaults {
        let suite = "onboarding-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallStartsAtWelcomeAndIsActive() {
        let model = OnboardingModel(defaults: makeDefaults(), hasSavedServers: false)
        #expect(model.isActive)
        #expect(model.step == .welcome)
        #expect(!model.isDone)
    }

    @Test func accountWithApprovedDeviceGoesToServer() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        #expect(model.step == .account)
        model.signedIn(deviceApproved: true)
        #expect(model.step == .server)
    }

    @Test func unapprovedDeviceStopsAtApprovalThenGoesToServer() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.signedIn(deviceApproved: false)
        #expect(model.step == .approval)
        #expect(model.needsApproval)
        model.advance()
        #expect(model.step == .server)
    }

    @Test func continuingWithoutAccountSkipsApproval() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.advance()
        #expect(model.step == .server)
        #expect(!model.needsApproval)
    }

    @Test func serverThenAgentFinishesTheFlow() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.advance()
        model.advance()
        #expect(model.step == .agent)
        model.advance()
        #expect(model.step == .done)
        #expect(model.isDone)
        #expect(!model.isActive)
    }

    @Test func skipFinishesFromAnyStepAndStaysDoneAfterRelaunch() {
        let defaults = makeDefaults()
        for steps in 0...4 {
            let model = OnboardingModel(defaults: defaults)
            defaults.set(false, forKey: OnboardingModel.doneKey)
            for _ in 0..<steps { model.advance() }
            model.skip()
            #expect(!model.isActive)
            #expect(model.isDone)
        }
        let relaunched = OnboardingModel(defaults: defaults)
        #expect(!relaunched.isActive)
    }

    // MARK: launch decision (made in init, from local data only)

    @Test func savedServersOpenTheMainWindowAtOnce() {
        let model = OnboardingModel(defaults: makeDefaults(), hasSavedServers: true)
        #expect(!model.isActive)
    }

    @Test func finishedFlowStaysHiddenOnLaunch() {
        let defaults = makeDefaults()
        let first = OnboardingModel(defaults: defaults)
        first.finish()
        let second = OnboardingModel(defaults: defaults, hasSavedServers: false)
        #expect(!second.isActive)
    }

    @Test func finishedFlowIsHiddenEvenWithoutServers() {
        let defaults = makeDefaults()
        OnboardingModel(defaults: defaults).finish()
        #expect(!OnboardingModel(defaults: defaults, hasSavedServers: false).isActive)
    }

    @Test func relaunchResumesTheSavedStep() {
        let defaults = makeDefaults()
        let first = OnboardingModel(defaults: defaults)
        first.advance()
        first.advance()
        #expect(first.step == .server)

        let second = OnboardingModel(defaults: defaults)
        #expect(second.isActive)
        #expect(second.step == .server)
    }

    @Test func savedDoneStepWithoutDoneFlagResumesAtWelcome() {
        let defaults = makeDefaults()
        defaults.set(OnboardingStep.done.rawValue, forKey: OnboardingModel.stepKey)
        let model = OnboardingModel(defaults: defaults)
        #expect(model.step == .welcome)
        #expect(model.isActive)
    }

    @Test func replayShowsWelcomeEvenWhenServersExist() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults, hasSavedServers: true)
        model.finish()
        model.replay()
        #expect(model.isActive)
        #expect(model.step == .welcome)
        #expect(!model.isDone)
    }

    @Test func replayResetsTheDoneFlagForTheNextLaunch() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        model.finish()
        model.replay()
        let relaunched = OnboardingModel(defaults: defaults, hasSavedServers: false)
        #expect(relaunched.isActive)
        #expect(defaults.bool(forKey: OnboardingModel.doneKey) == false)
    }

    @Test func sessionTooOldReturnsToSignIn() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.signedIn(deviceApproved: false)
        #expect(model.step == .approval)
        model.returnToSignIn()
        #expect(model.step == .account)
        #expect(!model.needsApproval)
    }

    @Test func progressCountsFiveDesignSteps() {
        let model = OnboardingModel(defaults: makeDefaults())
        #expect(model.step.position == 1)
        model.advance()
        #expect(model.step.position == 2)
        model.signedIn(deviceApproved: false)
        #expect(model.step.position == 2)
        model.advance()
        #expect(model.step.position == 3)
        model.advance()
        #expect(model.step.position == 4)
        model.advance()
        #expect(model.step.position == 5)
        #expect(OnboardingStep.allCases.count == 6)
    }

    @Test func nextStepTableMatchesTheFlow() {
        #expect(OnboardingModel.nextStep(after: .welcome, needsApproval: false) == .account)
        #expect(OnboardingModel.nextStep(after: .account, needsApproval: false) == .server)
        #expect(OnboardingModel.nextStep(after: .account, needsApproval: true) == .approval)
        #expect(OnboardingModel.nextStep(after: .approval, needsApproval: true) == .server)
        #expect(OnboardingModel.nextStep(after: .server, needsApproval: false) == .agent)
        #expect(OnboardingModel.nextStep(after: .agent, needsApproval: false) == .done)
        #expect(OnboardingModel.nextStep(after: .done, needsApproval: false) == .done)
    }

    // MARK: tour

    @Test func creatingTheFirstAgentFinishesWithTheTour() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.finishWithTour()
        #expect(model.isDone)
        #expect(!model.isActive)
        #expect(model.tourRequested)
        model.endTour()
        #expect(!model.tourRequested)
    }

    @Test func skippingTheFlowDoesNotStartTheTour() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.skip()
        #expect(model.isDone)
        #expect(!model.tourRequested)
    }

    @Test func replayClearsAPendingTour() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.finishWithTour()
        model.replay()
        #expect(!model.tourRequested)
        #expect(model.isActive)
    }
}
