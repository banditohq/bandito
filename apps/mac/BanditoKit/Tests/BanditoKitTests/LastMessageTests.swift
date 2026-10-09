import Foundation
import Testing

@testable import BanditoKit

@Suite struct LastMessageTests {
    private func event(_ body: EventBody, ts: Int64 = 9) -> Event {
        Event(seq: 1, agentId: "a", ts: ts, body: body)
    }

    @Test func userAndAssistantMessagesBecomeThePreviewEntry() {
        #expect(LastMessage(event: event(.messageUser(text: "hi", source: .user, fromAgent: nil))) == LastMessage(role: "user", text: "hi", ts: 9))
        #expect(LastMessage(event: event(.messageUser(text: "hi", source: .crew, fromAgent: "Scout"))) != nil)
        #expect(LastMessage(event: event(.messageAssistant(text: "hello"))) == LastMessage(role: "assistant", text: "hello", ts: 9))
    }

    @Test func messagesBandidoSentItselfAndOtherEventsAreNoPreview() {
        #expect(LastMessage(event: event(.messageUser(text: "save memory", source: .system, fromAgent: nil))) == nil)
        #expect(LastMessage(event: event(.messageDelta(text: "He"))) == nil)
        #expect(LastMessage(event: event(.turnStarted(turnId: "t", source: .user))) == nil)
    }

    @Test func previewTextIsCutToTwoHundredCharactersOnACharacterBoundary() {
        let long = String(repeating: "я", count: 250) + "🙂"
        let cut = LastMessage(event: event(.messageAssistant(text: long)))?.text ?? ""
        #expect(cut.unicodeScalars.count == 200)
        #expect(long.hasPrefix(cut))
        let short = "коротко"
        #expect(LastMessage(event: event(.messageAssistant(text: short)))?.text == short)
    }

    @Test func threadTextIsTheNewestMessageNotAnApprovalOrNote() {
        var thread = AgentThread()
        #expect(thread.lastMessageText == nil)

        thread.items = [
            .user(id: "u1", text: "first", source: .user, from: nil, ts: 1),
            .assistant(id: "a1", text: "answer", ts: 2),
            .approval(
                ApprovalRow(
                    approvalId: "p1", tool: "shell", title: "rm -rf build", command: nil, diff: nil, reason: "",
                    state: .pending)),
            .note(id: "n1", text: "Stopped", kind: .info, ts: 3),
        ]
        #expect(thread.lastMessageText == "answer")

        thread.items.append(.streaming(text: "still typing"))
        #expect(thread.lastMessageText == "still typing")
    }
}
