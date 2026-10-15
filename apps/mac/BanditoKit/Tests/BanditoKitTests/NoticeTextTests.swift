import Foundation
import Testing

@testable import BanditoKit
import BanditoL10n

// The text a notification shows, from an agent's reply: the same rules as the daemon's push text (`plain` in
// daemon/src/push.rs), so a local notice and a pushed one read the same.
@Suite struct NoticeTextTests {
    @Test func theMarkdownComesOffTheText() {
        let raw = "## Итог\n\n**Сделано:** `fmt` и [отчёт](https://e.x/r)\n```rust\nlet a = 1;\n```\nвсё_готово *ok*"
        #expect(NoticeText.plain(raw, limit: 400) == "Итог Сделано: fmt и отчёт let a = 1; всё_готово ok")
        #expect(NoticeText.plain("```\n```\n** **", limit: 400) == "")
        #expect(NoticeText.plain("[без ссылки", limit: 400) == "[без ссылки")
        #expect(NoticeText.plain("2*3 = 6, my_var", limit: 400) == "2*3 = 6, my_var")
    }

    @Test func theTextIsCutWithAnEllipsis() {
        let cut = NoticeText.plain(String(repeating: "а", count: 1000), limit: 400)
        #expect(cut.count == 400)
        #expect(cut.hasSuffix("…"))
        #expect(NoticeText.plain("Готово", limit: 400) == "Готово")
    }

    @Test func aBlankReplyHasNoFinishedText() {
        #expect(NoticeText.finishedText(nil) == nil)
        #expect(NoticeText.finishedText("  \n ** ") == nil)
        #expect(NoticeText.finishedText("**Готово**") == "Готово")
    }
}

@Suite struct FinishedNoticeTests {
    @Test func aFinishedTurnWithTextTitlesTheAgentAndCarriesTheText() {
        let content = NotificationContent.make(.finished(agentID: "a", agentName: "Forge", text: "Готово"))
        #expect(content.title == "Forge")
        #expect(content.body == "Готово")
        #expect(content.categoryID == NotificationContent.finishedCategory)
    }

    @Test func aFinishedTurnWithoutTextKeepsItsOldTitle() {
        let content = NotificationContent.make(.finished(agentID: "a", agentName: "Forge", text: nil))
        #expect(content.title == L10n.Notify.finished(name: "Forge"))
        #expect(content.body == "")
    }

    @Test func theNoticeOfATurnTakesItsTextAndAQuietTurnMakesNone() {
        let done = Event(
            seq: 5, agentId: "a", ts: 1, body: .turnCompleted(turnId: "t", status: .ok, usage: nil, costUsd: nil))
        guard case .finished(_, _, let text)? = AgentNotice.notice(
            for: done, agentName: "Forge", quietTurn: { false }, turnText: { "Готово" })
        else {
            Issue.record("a finished turn makes a notice")
            return
        }
        #expect(text == "Готово")
        #expect(AgentNotice.notice(for: done, agentName: "Forge", quietTurn: { true }, turnText: { "Готово" }) == nil)
        guard case .finished(_, _, nil)? = AgentNotice.notice(
            for: done, agentName: "Forge", quietTurn: { false }, turnText: { nil })
        else {
            Issue.record("a finished turn without text still makes a notice for an older daemon")
            return
        }
    }
}
