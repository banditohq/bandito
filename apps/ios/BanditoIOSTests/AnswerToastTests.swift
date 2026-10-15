import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito
@testable import BanditoL10n

/// The toast after an answer: one message on screen, a new one replaces it, it leaves after 2.5 s, and its Russian
/// text names the agent.
@MainActor
@Suite struct AnswerToastTests {
    @Test func showSetsTheCurrentMessage() {
        let center = AnswerToastCenter()
        let message = AnswerToastMessage(text: "Allowed — Forge goes on", allowed: true)
        center.show(message)
        #expect(center.current == message)
    }

    @Test func aSecondMessageReplacesTheFirst() {
        let center = AnswerToastCenter()
        center.show(AnswerToastMessage(text: "Allowed — Forge goes on", allowed: true))
        let second = AnswerToastMessage(text: "Denied — Forge will know", allowed: false)
        center.show(second)
        #expect(center.current == second)
    }

    @Test func theMessageLeavesAfterAboutTwoAndAHalfSeconds() async {
        let center = AnswerToastCenter()
        center.show(AnswerToastMessage(text: "Sent to Forge", allowed: true))
        #expect(center.current != nil)
        // Up to 4 s in 100 ms steps: the toast should be gone at about 2.5 s.
        var steps = 0
        while center.current != nil, steps < 40 {
            try? await Task.sleep(for: .milliseconds(100))
            steps += 1
        }
        #expect(center.current == nil)
    }

    @Test func messagesInTurnAreAllShownOneAfterTheOther() async {
        let center = AnswerToastCenter()
        let first = AnswerToastMessage(text: "one", allowed: false)
        let second = AnswerToastMessage(text: "two", allowed: false)
        center.showInTurn([first, second])
        #expect(center.current == first)
        var steps = 0
        while center.current != second, steps < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            steps += 1
        }
        #expect(center.current == second, "the second waited for the first instead of replacing it")
    }

    @Test func aFailedShareWithoutANameDoesNotShowTheAgentID() {
        let text = ShareNotice(kind: .failedForGood, agentName: nil).text
        #expect(!text.isEmpty)
        #expect(!text.contains("3f2a"))
    }

    @Test func russianStringsAreFilledAndNameTheAgent() {
        let texts = L10n.withLanguageForTests("ru") {
            [
                L10n.Ios.AnswerToast.allowed(name: "Forge"),
                L10n.Ios.AnswerToast.denied(name: "Forge"),
                L10n.Ios.AnswerToast.sent(name: "Forge"),
            ]
        }
        for text in texts {
            #expect(!text.isEmpty)
            #expect(text.contains("Forge"))
        }
    }
}
