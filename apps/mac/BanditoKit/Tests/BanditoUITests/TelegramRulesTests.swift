import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The Telegram section's rules: the token the field sends, when Connect is on, the countdown of a link code, when the
/// link sheet closes, and which failure a daemon reply means.
@Suite struct TelegramRulesTests {
    @Test func tokenLosesTheSpacesAndLineBreaksAroundIt() {
        #expect(TelegramRules.token(from: "  123456:ABC-def \n") == "123456:ABC-def")
        #expect(TelegramRules.token(from: "\t\n  ") == "")
    }

    @Test func connectNeedsATokenAndNoRunningRequest() {
        #expect(!TelegramRules.canConnect(draft: "", busy: false))
        #expect(!TelegramRules.canConnect(draft: "   ", busy: false))
        #expect(TelegramRules.canConnect(draft: " 1:x ", busy: false))
        #expect(!TelegramRules.canConnect(draft: "1:x", busy: true))
    }

    @Test func countdownShowsMinutesAndSeconds() {
        #expect(TelegramRules.countdown(remainingMs: 600_000) == "10:00")
        #expect(TelegramRules.countdown(remainingMs: 59_001) == "1:00")
        #expect(TelegramRules.countdown(remainingMs: 59_000) == "0:59")
        #expect(TelegramRules.countdown(remainingMs: 1) == "0:01")
        #expect(TelegramRules.countdown(remainingMs: 0) == "0:00")
        #expect(TelegramRules.countdown(remainingMs: -5) == "0:00")
    }

    @Test func remainingNeverGoesBelowZero() {
        #expect(TelegramRules.remainingMs(until: 100, now: 40) == 60)
        #expect(TelegramRules.remainingMs(until: 100, now: 300) == 0)
    }

    @Test func aChatThatWasNotThereBeforeIsTheNewOne() {
        let chat = TelegramChat(
            chatId: 5, title: "A", language: "en", linkedAt: 1, approvals: true, answers: .all)
        #expect(TelegramRules.hasNewChat(known: [], current: [chat]))
        #expect(!TelegramRules.hasNewChat(known: [5], current: [chat]))
        #expect(!TelegramRules.hasNewChat(known: [5], current: []))
    }

    @Test func daemonCodesMapToTheirFailures() {
        let invalid = RPCError(code: -32000, message: "invalid_token: the token was refused")
        #expect(TelegramRules.failure(for: invalid) == .invalidToken)
        let conflict = RPCError(code: -32000, message: "failed", data: .object(["reason": .string("conflict")]))
        #expect(TelegramRules.failure(for: conflict) == .conflict)
        #expect(TelegramRules.failure(for: RPCError(code: -32000, message: "unauthorized")) == .unauthorized)
        #expect(TelegramRules.failure(for: RPCError(code: -32000, message: "network")) == .network)
    }

    @Test func aFailureWithoutACodeIsTheGeneralOne() {
        let failure = TelegramRules.failure(for: RPCError(code: -32000, message: "something odd happened"))
        guard case .other(let message) = failure else {
            Issue.record("wrong failure \(failure)")
            return
        }
        #expect(!message.text.isEmpty)
    }

    @Test func eachCodeHasItsOwnSentence() {
        let texts = [TelegramFailure.invalidToken, .conflict, .unauthorized, .network].map { $0.message.text }
        #expect(Set(texts).count == 4)
        #expect(texts.allSatisfy { !$0.isEmpty })
    }

    @Test func theStatusProblemComesFromLastError() {
        func status(_ lastError: String?) -> TelegramStatus {
            TelegramStatus(
                configured: true, bot: TelegramBot(username: "b", name: "B"), running: false,
                lastError: lastError, chats: [])
        }
        #expect(TelegramRules.problem(of: status("unauthorized")) == .unauthorized)
        #expect(TelegramRules.problem(of: status("conflict")) == .conflict)
        #expect(TelegramRules.problem(of: status(nil)) == nil)
        #expect(TelegramRules.problem(of: status("something new")) == nil)
    }
}
