import BanditoKit
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

    @Test func haveServerSkipsTheAccountStep() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.haveServer()
        #expect(model.step == .server)
        #expect(!model.needsApproval)
        #expect(model.isActive)
    }

    @Test func accountWithApprovedDeviceGoesToServer() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.advance()
        #expect(model.step == .account)
        model.signedIn(deviceApproved: true)
        #expect(model.step == .server)
    }

    @Test func unapprovedDeviceStopsAtApprovalThenGoesToServer() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
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
        model.advance()
        #expect(model.step == .server)
        #expect(!model.needsApproval)
    }

    @Test func theFullWayEndsTheFlow() {
        let model = OnboardingModel(defaults: makeDefaults())
        for expected: OnboardingStep in [.features, .account, .server, .runtimes, .team, .task] {
            model.advance()
            #expect(model.step == expected)
        }
        model.advance()
        #expect(model.step == .done)
        #expect(model.isDone)
        #expect(!model.isActive)
    }

    @Test func skipFinishesFromAnyStepAndStaysDoneAfterRelaunch() {
        let defaults = makeDefaults()
        for steps in 0...6 {
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

    // MARK: cards of "What you get"

    @Test func cardsTurnOneByOneAndTheLastGoesOn() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        #expect(model.step == .features && model.card == 0)
        model.nextCard()
        #expect(model.card == 1)
        model.nextCard()
        #expect(model.card == 2)
        model.nextCard()
        #expect(model.step == .account)
    }

    @Test func showCardClampsAndOnlyWorksOnTheFeaturesStep() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.showCard(2)
        #expect(model.card == 0)
        model.advance()
        model.showCard(9)
        #expect(model.card == OnboardingRules.cardCount - 1)
        model.showCard(-4)
        #expect(model.card == 0)
    }

    @Test func skipPassesTheCards() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.skipFeatures()
        #expect(model.step == .account)
    }

    @Test func theSavedCardIsClamped() {
        let defaults = makeDefaults()
        defaults.set(40, forKey: OnboardingModel.cardKey)
        #expect(OnboardingModel(defaults: defaults).card == OnboardingRules.cardCount - 1)
        defaults.set(-3, forKey: OnboardingModel.cardKey)
        #expect(OnboardingModel(defaults: defaults).card == 0)
    }

    // MARK: Back

    @Test func backNeverMovesBeforeWelcome() {
        let model = OnboardingModel(defaults: makeDefaults())
        #expect(!model.canGoBack)
        model.back()
        #expect(model.step == .welcome)
    }

    @Test func backGoesCardByCardThenToWelcome() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.advance()
        model.showCard(2)
        model.back()
        #expect(model.step == .features && model.card == 1)
        model.back()
        #expect(model.card == 0)
        model.back()
        #expect(model.step == .welcome)
    }

    @Test func backRetracesTheWayTheyCame() {
        let model = OnboardingModel(defaults: makeDefaults())
        // welcome, features, account, approval, server, runtimes, team
        model.advance()
        model.advance()
        model.signedIn(deviceApproved: false)
        model.advance()
        model.advance()
        model.advance()
        #expect(model.step == .team)
        for expected: OnboardingStep in [.runtimes, .server, .approval] {
            model.back()
            #expect(model.step == expected)
        }
        model.back()
        #expect(model.step == .account)
    }

    @Test func backAfterIHaveAServerReturnsToWelcome() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.haveServer()
        #expect(model.step == .server)
        model.back()
        #expect(model.step == .welcome)
    }

    @Test func backWorksOnEveryStepAfterWelcome() {
        let model = OnboardingModel(defaults: makeDefaults())
        for _ in 0..<6 { model.advance() }
        #expect(model.step == .task)
        while model.step != .welcome {
            let before = model.step
            model.back()
            #expect(model.step != before)
        }
        #expect(model.step == .welcome)
    }

    @Test func returnToServerForgetsTheStepsAfterIt() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.haveServer()
        model.advance()
        model.advance()
        #expect(model.step == .team)
        model.returnToServer()
        #expect(model.step == .server)
        model.back()
        #expect(model.step == .welcome)
    }

    // MARK: resume

    @Test func theWayBackSurvivesARelaunch() {
        let defaults = makeDefaults()
        let first = OnboardingModel(defaults: defaults)
        first.advance()
        first.advance()
        first.advance()
        #expect(first.step == .server)
        let second = OnboardingModel(defaults: defaults)
        #expect(second.step == .server)
        second.back()
        #expect(second.step == .account)
        second.back()
        #expect(second.step == .features)
    }

    @Test func aServerThatIsSavedResumesAfterTheServerStep() {
        let defaults = makeDefaults()
        let first = OnboardingModel(defaults: defaults)
        first.haveServer()
        // The server was connected, then the app quit before "Next".
        let second = OnboardingModel(defaults: defaults, hasSavedServers: true)
        #expect(second.isActive)
        #expect(second.step == .runtimes)
        second.back()
        #expect(second.step == .server)
    }

    @Test func aStepAfterTheServerResumesWhenTheServerIsSaved() {
        let defaults = makeDefaults()
        let first = OnboardingModel(defaults: defaults)
        first.haveServer()
        first.advance()
        first.advance()
        #expect(first.step == .team)
        let second = OnboardingModel(defaults: defaults, hasSavedServers: true)
        #expect(second.isActive)
        #expect(second.step == .team)
    }

    @Test func aStepAfterTheServerWithoutAServerGoesBackToTheServerStep() {
        let defaults = makeDefaults()
        defaults.set(OnboardingStep.team.rawValue, forKey: OnboardingModel.stepKey)
        let model = OnboardingModel(defaults: defaults, hasSavedServers: false)
        #expect(model.step == .server)
        #expect(model.isActive)
    }

    @Test func aLegacyUserWithServersAndNoSavedStepNeverSeesTheFlow() {
        let model = OnboardingModel(defaults: makeDefaults(), hasSavedServers: true)
        #expect(!model.isActive)
    }

    @Test func aStepSavedByAnOlderBuildStillResumes() {
        let defaults = makeDefaults()
        defaults.set("agent", forKey: OnboardingModel.stepKey)
        let model = OnboardingModel(defaults: defaults, hasSavedServers: true)
        #expect(model.step == .runtimes)
        #expect(model.isActive)
    }

    @Test func theFirstAgentIsRememberedAcrossALaunchAndForgottenOnReplay() {
        let defaults = makeDefaults()
        let model = OnboardingModel(defaults: defaults)
        model.rememberFirstAgent("agent-1", team: "web-project")
        let relaunched = OnboardingModel(defaults: defaults)
        #expect(relaunched.firstAgentID == "agent-1")
        #expect(relaunched.firstTeamID == "web-project")
        relaunched.replay()
        #expect(relaunched.firstAgentID == nil)
        #expect(OnboardingModel(defaults: defaults).firstAgentID == nil)
    }

    // MARK: the runtimes step

    @Test func theRuntimesStepContinuesWithAtLeastOneReadyProgram() {
        #expect(!OnboardingRules.canContinueRuntimes(signedIn: []))
        #expect(OnboardingRules.canContinueRuntimes(signedIn: [.grok]))
        #expect(OnboardingRules.canContinueRuntimes(signedIn: [.claude, .codex, .grok]))
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
        #expect(first.step == .account)

        let second = OnboardingModel(defaults: defaults)
        #expect(second.isActive)
        #expect(second.step == .account)
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
        model.advance()
        model.signedIn(deviceApproved: false)
        #expect(model.step == .approval)
        model.returnToSignIn()
        #expect(model.step == .account)
        #expect(!model.needsApproval)
    }

    @Test func progressCountsSevenBarSteps() {
        let model = OnboardingModel(defaults: makeDefaults())
        var positions: [Int] = []
        for _ in 0..<7 {
            positions.append(model.step.position)
            model.advance()
        }
        // welcome, features, account, server, runtimes, team, task
        #expect(positions == [1, 2, 3, 4, 5, 6, 7])
        #expect(OnboardingStep.barCount == 7)
        // Approval belongs to the account dot.
        #expect(OnboardingStep.approval.position == OnboardingStep.account.position)
    }

    @Test func nextStepTableMatchesTheFlow() {
        #expect(OnboardingModel.nextStep(after: .welcome, needsApproval: false) == .features)
        #expect(OnboardingModel.nextStep(after: .features, needsApproval: false) == .account)
        #expect(OnboardingModel.nextStep(after: .account, needsApproval: false) == .server)
        #expect(OnboardingModel.nextStep(after: .account, needsApproval: true) == .approval)
        #expect(OnboardingModel.nextStep(after: .approval, needsApproval: true) == .server)
        #expect(OnboardingModel.nextStep(after: .server, needsApproval: false) == .runtimes)
        #expect(OnboardingModel.nextStep(after: .runtimes, needsApproval: false) == .team)
        #expect(OnboardingModel.nextStep(after: .team, needsApproval: false) == .task)
        #expect(OnboardingModel.nextStep(after: .task, needsApproval: false) == .done)
        #expect(OnboardingModel.nextStep(after: .done, needsApproval: false) == .done)
    }

    @Test func skippingTheFlowFinishesIt() {
        let model = OnboardingModel(defaults: makeDefaults())
        model.skip()
        #expect(model.isDone)
        #expect(!model.isActive)
    }
}
