import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

// MARK: - E: subscriptions

@Suite struct SubscriptionStateTests {
    @Test func aMissingProgramIsNotInstalled() {
        #expect(SubscriptionState.resolve(installed: false, loggedIn: true, plan: "Max ×20", confirmed: false)
            == .notInstalled)
    }

    @Test func aFalseLoginNeedsSignIn() {
        #expect(SubscriptionState.resolve(installed: true, loggedIn: false, plan: nil, confirmed: false)
            == .needsLogin)
    }

    @Test func aTrueLoginKeepsThePlan() {
        #expect(SubscriptionState.resolve(installed: true, loggedIn: true, plan: "Max ×20", confirmed: false)
            == .loggedIn(plan: "Max ×20"))
    }

    @Test func anUnknownLoginIsUnverifiedUntilTheUserConfirms() {
        #expect(SubscriptionState.resolve(installed: true, loggedIn: nil, plan: nil, confirmed: false)
            == .unverified)
        #expect(SubscriptionState.resolve(installed: true, loggedIn: nil, plan: nil, confirmed: true)
            == .loggedIn(plan: nil))
    }

    @Test func anExplicitNotSignedInBeatsAnEarlierDone() {
        #expect(SubscriptionState.resolve(installed: true, loggedIn: false, plan: nil, confirmed: true)
            == .needsLogin)
    }

    @Test func onlyASignedInStateCountsAsReady() {
        #expect(SubscriptionState.loggedIn(plan: nil).isReady)
        #expect(!SubscriptionState.unverified.isReady)
        #expect(!SubscriptionState.needsLogin.isReady)
        #expect(!SubscriptionState.notInstalled.isReady)
    }
}

@Suite struct LoginGateTests {
    @Test func aSecondStartWhileOpeningIsRefused() {
        var gate = LoginGate()
        let first = gate.tryStart()
        let second = gate.tryStart()
        gate.finish()
        let third = gate.tryStart()
        #expect(first)
        #expect(!second)
        #expect(third)
    }
}

@Suite struct LoginLinkTests {
    @Test func theLastHTTPSLinkIsTheOneToOpen() {
        let text = "Open https://claude.example/a first\nthen https://claude.example/device?code=ABC.\n"
        #expect(LoginLink.lastHTTPS(in: text) == URL(string: "https://claude.example/device?code=ABC"))
    }

    @Test func plainHTTPIsNeverOffered() {
        #expect(LoginLink.lastHTTPS(in: "visit http://insecure.example/login") == nil)
    }

    @Test func otherSchemesAreNeverOffered() {
        #expect(LoginLink.lastHTTPS(in: "file:///etc/passwd and javascript:alert(1)") == nil)
    }

    @Test func terminalColourCodesAreRemovedBeforeLooking() {
        let text = "\u{1B}[31mhttps://auth.example/login\u{1B}[0m"
        #expect(LoginLink.lastHTTPS(in: text) == URL(string: "https://auth.example/login"))
    }

    @Test func noLinkMeansNil() {
        #expect(LoginLink.lastHTTPS(in: "Waiting for input…") == nil)
    }
}

@Suite struct LoginCommandTests {
    @Test func eachRuntimeLogsInWithItsOwnCommand() {
        #expect(LoginCommand.arguments(for: .claude) == ["claude"])
        #expect(LoginCommand.arguments(for: .codex) == ["codex", "login"])
        #expect(LoginCommand.arguments(for: .grok) == ["grok", "login", "--device-auth"])
    }
}

// MARK: - F: first agent

@Suite struct AgentNameRuleTests {
    @Test func aNameIsRequired() {
        #expect(AgentNameRule.problem(for: "", existing: []) == .empty)
        #expect(AgentNameRule.problem(for: "   ", existing: []) == .empty)
    }

    @Test func aLongNameIsRefused() {
        #expect(AgentNameRule.problem(for: String(repeating: "a", count: 41), existing: []) == .tooLong)
        #expect(AgentNameRule.problem(for: String(repeating: "a", count: 40), existing: []) == nil)
    }

    @Test func onlyLettersDigitsSpacesDashesAndUnderscoresAreAllowed() {
        #expect(AgentNameRule.problem(for: "Forge 2_b-x", existing: []) == nil)
        #expect(AgentNameRule.problem(for: "bad;name", existing: []) == .badCharacters)
        #expect(AgentNameRule.problem(for: "$(id)", existing: []) == .badCharacters)
    }

    @Test func namesAreUniqueIgnoringCase() {
        #expect(AgentNameRule.problem(for: "forge", existing: ["Forge"]) == .duplicate)
        #expect(AgentNameRule.problem(for: "Forge 2", existing: ["Forge"]) == nil)
    }
}

@Suite struct AgentRuntimeChoiceTests {
    @Test func thePreferredRuntimeWinsWhenSignedIn() {
        #expect(AgentRuntimeChoice.pick(preferred: .codex, signedIn: [.claude, .codex]) == .codex)
    }

    @Test func otherwiseTheFirstSignedInRuntimeIsUsed() {
        #expect(AgentRuntimeChoice.pick(preferred: .codex, signedIn: [.claude]) == .claude)
    }

    @Test func noSignedInRuntimeMeansNoAgent() {
        #expect(AgentRuntimeChoice.pick(preferred: .claude, signedIn: []) == nil)
    }
}

@Suite struct AgentFolderNamingTests {
    @Test func aFreeFolderKeepsItsName() {
        #expect(AgentFolder.unique("/h/projects/forge", taken: []) == "/h/projects/forge")
    }

    @Test func aTakenFolderGetsTheNextFreeNumber() {
        #expect(AgentFolder.unique("/h/projects/forge", taken: ["/h/projects/forge"]) == "/h/projects/forge-2")
        #expect(AgentFolder.unique("/h/projects/forge", taken: ["/h/projects/forge", "/h/projects/forge-2"])
            == "/h/projects/forge-3")
        #expect(AgentFolder.unique("/h/projects/forge", taken: ["/h/projects/forge-2"]) == "/h/projects/forge")
    }
}

@Suite struct KnownHostRemovalTests {
    @Test func theCommandNamesTheHostInQuotes() {
        #expect(KnownHostRemoval.command(for: "[203.0.113.7]:2222") == "ssh-keygen -R '[203.0.113.7]:2222'")
    }

    @Test func aQuoteInTheNameCannotEndTheQuoting() {
        #expect(KnownHostRemoval.command(for: "a';rm -rf ~;'") == "ssh-keygen -R 'a'\\'';rm -rf ~;'\\'''")
    }
}

@Suite struct AgentFolderTests {
    @Test func theDefaultFolderIsAProjectUnderHome() {
        #expect(AgentFolder.defaultPath(home: "/home/dev", name: "Forge Bot") == "/home/dev/projects/forge-bot")
    }

    @Test func aNameWithoutLettersFallsBackToAgent() {
        #expect(AgentFolder.defaultPath(home: "/home/dev", name: "!!!") == "/home/dev/projects/agent")
    }
}

// MARK: - tour

@Suite struct TourPlanTests {
    @Test func stepsKeepTheirOrder() {
        let steps = TourPlan.steps(available: Set(TourAnchor.allCases))
        #expect(steps == TourAnchor.allCases)
    }

    @Test func stepsWithoutTheirAnchorAreSkipped() {
        let steps = TourPlan.steps(available: [.composer, .modes])
        #expect(steps == [.composer, .modes])
    }

    @Test func nextMovesThroughTheSteps() {
        var tour = TourModel(steps: [.agents, .composer])
        #expect(tour.current == .agents)
        #expect(!tour.isLast)
        tour.next()
        #expect(tour.current == .composer)
        #expect(tour.isLast)
        tour.next()
        #expect(tour.isFinished)
    }

    @Test func skippingFinishesAtOnce() {
        var tour = TourModel(steps: [.agents, .composer, .modes])
        tour.skip()
        #expect(tour.isFinished)
        #expect(tour.current == nil)
    }

    @Test func aTourWithNoAvailableStepIsFinished() {
        let tour = TourModel(steps: [])
        #expect(tour.isFinished)
    }

    @Test func aTourWithoutAnyAnchorOnScreenEndsWithNext() {
        var tour = TourModel(steps: [.agents, .composer])
        tour.skipMissing(available: [])
        #expect(tour.isFinished)
    }

    @Test func nextPassesOverStepsWhoseAnchorIsGone() {
        var tour = TourModel(steps: [.agents, .approvals, .modes])
        tour.next(available: [.agents, .modes])
        #expect(tour.current == .modes)
        #expect(!tour.hasNext(available: [.agents, .modes]))
        tour.next(available: [.agents, .modes])
        #expect(tour.isFinished)
    }

    @Test func aTourEndsWhenNoLaterStepIsOnScreen() {
        var tour = TourModel(steps: [.agents, .composer])
        #expect(!tour.hasNext(available: []))
        tour.next(available: [])
        #expect(tour.isFinished)
    }

    @Test func skippingMovesPastAllStepsFromAnyPlace() {
        var tour = TourModel(steps: [.agents, .composer, .modes])
        tour.next()
        tour.skip()
        #expect(tour.isFinished)
    }
}
