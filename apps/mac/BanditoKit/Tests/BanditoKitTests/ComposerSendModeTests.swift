import Foundation
import Testing
@testable import BanditoKit


@Suite struct ComposerSendModeTests {
    private func form(_ id: String) -> FormRow {
        FormRow(formId: id, spec: FormSpec(title: "T", fields: []), ts: 1)
    }

    @Test func aFormWaitsAndTheFieldIsEmptyShowsStop() {
        #expect(
            ComposerSendMode.resolve(running: true, hasText: false, hasFiles: false, waitingFormId: "f1") == .stop)
    }

    @Test func aFormWaitsAndTextIsTypedAnswersTheForm() {
        #expect(
            ComposerSendMode.resolve(running: true, hasText: true, hasFiles: false, waitingFormId: "f1")
                == .replyToForm("f1"))
    }

    @Test func noFormKeepsTheOldBehaviour() {
        #expect(ComposerSendMode.resolve(running: true, hasText: true, hasFiles: false, waitingFormId: nil) == .stop)
        #expect(ComposerSendMode.resolve(running: true, hasText: false, hasFiles: false, waitingFormId: nil) == .stop)
        #expect(ComposerSendMode.resolve(running: false, hasText: true, hasFiles: false, waitingFormId: nil) == .send)
        #expect(ComposerSendMode.resolve(running: false, hasText: false, hasFiles: false, waitingFormId: nil) == .send)
    }

    @Test func filesInTheTrayKeepTheUsualQueue() {
        #expect(ComposerSendMode.resolve(running: true, hasText: true, hasFiles: true, waitingFormId: "f1") == .stop)
    }

    @Test func theLastWaitingFormIsAnswered() {
        #expect(ComposerSendMode.formToAnswer(in: [form("f1"), form("f2")], supportsReply: true) == "f2")
        #expect(ComposerSendMode.formToAnswer(in: [form("f1")], supportsReply: true) == "f1")
        #expect(ComposerSendMode.formToAnswer(in: [], supportsReply: true) == nil)
        #expect(ComposerSendMode.formToAnswer(in: [form("f1")], supportsReply: false) == nil, "an old daemon")
    }
}
