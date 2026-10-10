import BanditoKit
import SwiftUI
import Foundation
import Testing

@testable import BanditoUI

/// Code blocks, plain text, the reply bar and the words of a form card.
@MainActor
@Suite struct ChatUITests {
    // MARK: code blocks

    @Test func textWithoutFencesIsOneBlock() {
        #expect(MessageBlocks.parse("hello\nworld") == [.text("hello\nworld")])
        #expect(MessageBlocks.parse("") == [])
        #expect(!MessageBlocks.hasCode("use `ls` here"))
    }

    @Test func aFencedBlockIsSplitOut() {
        let blocks = MessageBlocks.parse("Run:\n```bash\nls -la\ncd ..\n```\nDone.")
        #expect(
            blocks == [
                .text("Run:"), .code(language: "bash", code: "ls -la\ncd ..", closed: true), .text("Done."),
            ])
        #expect(MessageBlocks.hasCode("```\nx\n```"))
    }

    @Test func aFenceWithoutLanguageHasNone() {
        #expect(MessageBlocks.parse("```\nx\n```") == [.code(language: nil, code: "x", closed: true)])
        #expect(MessageBlocks.parse("```  swift extra\nx\n```") == [.code(language: "swift", code: "x", closed: true)])
    }

    @Test func aFenceThatNeverEndsIsAnOpenBlock() {
        // A reply still streaming in.
        #expect(MessageBlocks.parse("a\n```py\nprint(1)") == [.text("a"), .code(language: "py", code: "print(1)", closed: false)])
    }

    @Test func aLongerFenceIsClosedByAtLeastAsManyAndShorterOnesAreCode() {
        let text = "````md\n```\ninner\n```\n````\nafter"
        #expect(MessageBlocks.parse(text) == [.code(language: "md", code: "```\ninner\n```", closed: true), .text("after")])
    }

    @Test func tildesFenceToo() {
        #expect(MessageBlocks.parse("~~~\nx\n~~~") == [.code(language: nil, code: "x", closed: true)])
        // Mixed marks do not close each other.
        #expect(MessageBlocks.parse("~~~\nx\n```\ny") == [.code(language: nil, code: "x\n```\ny", closed: false)])
    }

    @Test func inlineTripleBackticksAreNotAFence() {
        #expect(MessageBlocks.parse("see ```code``` here") == [.text("see ```code``` here")])
        #expect(MessageBlocks.parse("```code``` start") == [.text("```code``` start")])
    }

    @Test func aDeeplyIndentedFenceIsText() {
        #expect(MessageBlocks.parse("    ```\n    x\n    ```") == [.text("    ```\n    x\n    ```")])
        // Up to three spaces is a fence.
        #expect(MessageBlocks.parse("   ```\nx\n   ```") == [.code(language: nil, code: "x", closed: true)])
    }

    @Test func emptyCodeAndBlankLinesInsideCodeAreKept() {
        #expect(MessageBlocks.parse("```\n```") == [.code(language: nil, code: "", closed: true)])
        #expect(MessageBlocks.parse("```\na\n\nb\n```") == [.code(language: nil, code: "a\n\nb", closed: true)])
    }

    // MARK: plain text

    @Test func plainTextDropsTheMarks() {
        #expect(MessageBlocks.plainText("**bold** and `code` and [link](https://x.y)") == "bold and code and link")
        #expect(MessageBlocks.plainText("# Title\ntext") == "Title\ntext")
        #expect(MessageBlocks.plainText("###### Six") == "Six")
        #expect(MessageBlocks.plainText("#nospace") == "#nospace")
    }

    @Test func plainTextKeepsCodeWithoutFences() {
        #expect(MessageBlocks.plainText("Run:\n```sh\nls *.txt\n```") == "Run:\n\nls *.txt")
    }

    @Test func plainTextOfBrokenMarkdownIsTheText() {
        #expect(MessageBlocks.plainText("a * b ** c") == "a * b ** c")
    }

    // MARK: reply bar

    @Test func theReplyBarShowsTheFirst120Characters() {
        let long = String(repeating: "word ", count: 60)
        let target = ReplyTarget(seq: 4, fromUser: false, text: long)
        #expect(target.excerpt.count <= 121)
        #expect(target.excerpt.hasSuffix("…"))
        #expect(ReplyTarget(seq: 4, fromUser: true, text: "short").excerpt == "short")
    }

    @Test func theReplyBarIsOneLine() {
        #expect(ReplyTarget(seq: 1, fromUser: false, text: "a\n\nb\nc").excerpt == "a b c")
        #expect(MessageBlocks.excerpt("  x  ", limit: 10) == "x")
        #expect(MessageBlocks.excerpt("exactly10!", limit: 10) == "exactly10!")
    }

    @Test func theReplyBarReadsPlainText() {
        #expect(ReplyTarget(seq: 1, fromUser: false, text: "**Bold** start").excerpt == "Bold start")
    }

    @Test func aReplyStaysWithItsAgent() {
        let drafts = ReplyDrafts()
        let a = ReplyTarget(seq: 1, fromUser: false, text: "a")
        let b = ReplyTarget(seq: 2, fromUser: true, text: "b")
        drafts.set(a, for: "x")
        drafts.set(b, for: "y")
        #expect(drafts.target(for: "x") == a && drafts.target(for: "y") == b)
        #expect(drafts.take(for: "x") == a)
        #expect(drafts.target(for: "x") == nil)
        #expect(drafts.target(for: "y") == b)
    }

    @Test func escTakesTheReplyAway() {
        let drafts = ReplyDrafts()
        drafts.set(ReplyTarget(seq: 1, fromUser: false, text: "a"), for: "x")
        drafts.set(nil, for: "x")
        #expect(drafts.target(for: "x") == nil)
    }

    @Test func aFailedSendPutsTheReplyBackUnlessAnotherWasChosen() {
        let drafts = ReplyDrafts()
        let a = ReplyTarget(seq: 1, fromUser: false, text: "a")
        let b = ReplyTarget(seq: 2, fromUser: false, text: "b")
        drafts.set(a, for: "x")
        let taken = drafts.take(for: "x")
        drafts.restore(taken, for: "x")
        #expect(drafts.target(for: "x") == a)
        _ = drafts.take(for: "x")
        drafts.set(b, for: "x")
        drafts.restore(a, for: "x")
        #expect(drafts.target(for: "x") == b)
        drafts.restore(nil, for: "y")
        #expect(drafts.target(for: "y") == nil)
    }

    @Test func aMessageIsFoundByItsSeqForAQuote() {
        let items: [ThreadItem] = [
            .user(id: "s1", text: "question", source: .user, from: nil, ts: 1),
            .assistant(id: "s2", text: "answer", ts: 2),
            .assistant(id: "s3-s", text: "streamed", ts: 3),
        ]
        #expect(ThreadView.original(1, in: items) == ReplyTarget(seq: 1, fromUser: true, text: "question"))
        #expect(ThreadView.original(2, in: items) == ReplyTarget(seq: 2, fromUser: false, text: "answer"))
        #expect(ThreadView.original(3, in: items) == nil)
        #expect(ThreadView.original(99, in: items) == nil)
    }

    // MARK: reactions

    @Test func theSixUsualReactionsAreValid() {
        #expect(ReactionRules.common == ["👍", "❤️", "😂", "🔥", "👀", "✅"])
        for emoji in ReactionRules.common {
            #expect(ReactionRules.isValid(emoji), "\(emoji)")
        }
    }

    @Test func theDaemonsRulesForAnEmoji() {
        #expect(!ReactionRules.isValid(""))
        #expect(!ReactionRules.isValid("👍👍"))
        #expect(!ReactionRules.isValid("a b"))
        #expect(!ReactionRules.isValid(" "))
        // A family is one cluster, but 18 bytes.
        #expect(!ReactionRules.isValid("👨‍👩‍👧"))
        #expect(ReactionRules.isValid("👨🏽"))
    }

    @Test func theSystemPickerTextYieldsTheFirstEmoji() {
        #expect(ReactionRules.firstEmoji(in: "🎉") == "🎉")
        #expect(ReactionRules.firstEmoji(in: "x🎉") == "🎉")
        #expect(ReactionRules.firstEmoji(in: "abc 1 ") == nil)
        #expect(ReactionRules.firstEmoji(in: "") == nil)
        #expect(ReactionRules.firstEmoji(in: "❤️") == "❤️")
    }

    // MARK: forms

    static let spec = FormSpec(
        title: "Letter", kind: .confirm,
        fields: [
            FormField(id: "to", label: "To", type: .email),
            FormField(id: "body", label: "Text", type: .textarea),
            FormField(id: "copy", label: "Copy", type: .boolean),
            FormField(id: "when", label: "When", type: .date),
            FormField(id: "tags", label: "Tags", type: .multichoice, options: ["a", "b"]),
            FormField(id: "n", label: "N", type: .number),
        ])

    @Test func theSummaryNamesTheAnsweredFieldsInOrder() {
        let values: [String: JSONValue] = [
            "body": .string("Hello"), "to": .string("a@b.c"), "copy": .bool(true), "tags": .array([.string("a"), .string("b")]),
            "n": .number(3),
        ]
        let summary = FormPresentation.summary(spec: Self.spec, values: values)
        #expect(summary.hasPrefix("To: a@b.c · Text: Hello · Copy: "))
        #expect(summary.hasSuffix("Tags: a, b · N: 3"))
        // A field left out is not in the summary.
        #expect(!summary.contains("When"))
    }

    @Test func aDateIsShownInTheReadersFormat() throws {
        let date = try #require(FormDates.date(from: "2026-10-10"))
        let shown = FormPresentation.display(.string("2026-10-10"), field: Self.spec.fields[3])
        #expect(shown == date.formatted(date: .abbreviated, time: .omitted))
    }

    @Test func dateTextRoundTrips() throws {
        let date = try #require(FormDates.date(from: "2028-02-29"))
        #expect(FormDates.string(from: date) == "2028-02-29")
        #expect(FormDates.date(from: "2027-02-29") == nil)
        #expect(FormDates.date(from: "x") == nil)
    }

    @Test func aFinishedFormFoldsIntoOneLine() {
        let question = FormSpec(title: "Q", fields: [FormField(id: "name", label: "Name", type: .text)])
        let answered = FormPresentation.line(spec: question, outcome: .submitted(values: ["name": .string("Ann")]))
        #expect(answered.contains("Name: Ann"))
        // No answered field: still says it was answered.
        #expect(!FormPresentation.line(spec: question, outcome: .submitted(values: [:])).isEmpty)
        #expect(FormPresentation.line(spec: Self.spec, outcome: .submitted(values: ["to": .string("a@b.c")])) != answered)
        let rejectedWhy = FormPresentation.line(spec: Self.spec, outcome: .rejected(comment: "too early"))
        #expect(rejectedWhy.contains("too early"))
        #expect(FormPresentation.line(spec: Self.spec, outcome: .rejected(comment: "  ")) != rejectedWhy)
        #expect(FormPresentation.line(spec: question, outcome: .rejected(comment: nil)) != FormPresentation.line(spec: Self.spec, outcome: .rejected(comment: nil)))
        #expect(!FormPresentation.line(spec: question, outcome: .expired).isEmpty)
    }

    @Test func theAgentsOwnButtonWordsWin() {
        var spec = Self.spec
        let plain = FormPresentation.submitTitle(spec)
        spec.submitLabel = "  Send the letter "
        spec.rejectLabel = "Hold"
        #expect(FormPresentation.submitTitle(spec) == "Send the letter")
        #expect(FormPresentation.rejectTitle(spec) == "Hold")
        spec.submitLabel = "   "
        #expect(FormPresentation.submitTitle(spec) == plain)
    }

    @Test func aChoiceOfFourOrFewerIsAListAndMoreIsASelect() {
        func choice(_ n: Int) -> FormField {
            FormField(id: "c", label: "C", type: .choice, options: (0..<n).map(String.init))
        }
        #expect(FormPresentation.usesRadio(choice(1)))
        #expect(FormPresentation.usesRadio(choice(4)))
        #expect(!FormPresentation.usesRadio(choice(5)))
        #expect(!FormPresentation.usesRadio(FormField(id: "m", label: "M", type: .multichoice, options: ["a"])))
    }

    @Test func everyProblemHasWords() {
        for problem in [FormProblem.required, .notAnEmail, .notANumber, .notADate, .tooLong, .notAnOption] {
            #expect(!FormPresentation.text(for: problem).isEmpty)
        }
    }

    @Test func aFormThatIsOverHasItsOwnSentence() {
        let answered = FormPresentation.message(for: RPCError(code: -32602, message: "already_answered"))
        let expired = FormPresentation.message(for: RPCError(code: -32602, message: "expired"))
        #expect(answered.text != expired.text)
        #expect(answered.technical == nil && expired.technical == nil)
        // Anything else goes through the general mapper.
        let other = FormPresentation.message(for: RPCError(code: -32602, message: "field \"to\": expected an email"))
        #expect(other.text != answered.text)
    }
}

/// Renders the chat pieces to PNG for review (see `SnapshotSupport`): quotes, reactions, code, forms.
@MainActor
@Suite struct ChatSnapshots {
    @Test func threadWithChat() throws {
        let server = ServerModel(config: ServerConfig(name: "vps", endpoint: .defaultLocal))
        var seq: Int64 = 0
        func ev(_ b: EventBody) -> Event {
            seq += 1
            return Event(seq: seq, agentId: "forge", ts: 1_791_530_000_000 + seq * 1000, body: b)
        }
        let spec = FormSpec(
            title: "Send the weekly report?", intro: "I will email it to the team.", kind: .confirm,
            fields: [
                FormField(id: "to", label: "To", type: .email, isRequired: true, defaultValue: .string("team@example.com")),
                FormField(id: "subject", label: "Subject", type: .text, defaultValue: .string("Weekly report")),
                FormField(id: "body", label: "Text", type: .textarea, defaultValue: .string("Hi all,\nThe numbers are in.")),
                FormField(id: "copy", label: "Send me a copy", type: .boolean, defaultValue: .bool(true)),
            ])
        let question = FormSpec(
            title: "A few questions", intro: "So I can pick the right setup.",
            fields: [
                FormField(id: "name", label: "Project name", type: .text, isRequired: true, placeholder: "my-app", help: "Used for the folder."),
                FormField(id: "kind", label: "Kind", type: .choice, options: ["Web", "CLI", "Library"]),
                FormField(id: "tags", label: "Extras", type: .multichoice, options: ["Tests", "CI", "Docker", "Docs"]),
                FormField(id: "when", label: "Start", type: .date, defaultValue: .string("2026-10-12")),
                FormField(id: "n", label: "Team size", type: .number),
            ])
        let events: [EventBody] = [
            .messageUser(text: "Show me how to run the tests.", source: .user, fromAgent: nil),
            .messageAssistant(
                text:
                    "Run them with:\n```bash\ncargo test --all-targets -- --nocapture\n```\nThen check **the output** for `FAILED`."),
            .reaction(seq: 2, emoji: "👍", by: .user),
            .reaction(seq: 2, emoji: "🔥", by: .agent),
            .messageUser(text: "Thanks! And the linter?", source: .user, fromAgent: nil, replyTo: 2),
            .messageAssistant(text: "`cargo clippy -- -D warnings`"),
            .formRequested(formId: "f0", spec: question),
            .formAnswered(formId: "f0", action: .submit, values: ["name": .string("my-app"), "kind": .string("CLI")], comment: nil),
            .formRequested(formId: "f1", spec: spec),
        ]
        for body in events { server.apply(ev(body)) }
        let thread = server.thread(for: "forge")
        var chat = ThreadChat(
            reactionsOn: true, repliesOn: true, formsOn: true, agentName: "Forge", accent: Color(red: 0.95, green: 0.6, blue: 0.4))
        chat.reactions = thread.reactions
        chat.replies = thread.replies
        chat.original = { ThreadView.original($0, in: thread.items) }
        let view = ThreadItemsView(items: thread.items, server: server, agentName: "Forge", chat: chat)
            .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        let url = try SnapshotSupport.render(view, "chat-thread", size: CGSize(width: 900, height: 1100))
        #expect(FileManager.default.fileExists(atPath: url.path))

        // The question form on its own, waiting.
        let waiting = FormCard(row: FormRow(formId: "q", spec: question, ts: 1), agentName: "Forge") { _, _, _ in }
            .padding(24)
            .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        _ = try SnapshotSupport.render(waiting, "chat-form-question", size: CGSize(width: 760, height: 620))
    }
}

@MainActor
@Suite struct FormDraftsTests {
    static let spec = FormSpec(
        title: "T",
        fields: [
            FormField(id: "a", label: "A", type: .text, defaultValue: .string("x")),
            FormField(id: "b", label: "B", type: .boolean),
        ])

    @Test func aFormStartsFromItsDefaults() {
        let drafts = FormDrafts()
        let d = drafts.draft(for: "f", spec: Self.spec)
        #expect(d.inputs["a"] == .text("x") && d.inputs["b"] == .flag(false))
        #expect(d.comment == "" && !d.sent)
        // Asking does not store anything.
        #expect(drafts.drafts.isEmpty)
    }

    @Test func whatWasTypedStaysWithItsForm() {
        let drafts = FormDrafts()
        drafts.setInput(.text("typed"), field: "a", formId: "f1", spec: Self.spec)
        drafts.setComment("why", formId: "f1", spec: Self.spec)
        #expect(drafts.draft(for: "f1", spec: Self.spec).inputs["a"] == .text("typed"))
        #expect(drafts.draft(for: "f1", spec: Self.spec).inputs["b"] == .flag(false))
        #expect(drafts.draft(for: "f1", spec: Self.spec).comment == "why")
        // Another form is untouched.
        #expect(drafts.draft(for: "f2", spec: Self.spec).inputs["a"] == .text("x"))
    }

    @Test func aSentFormStaysSentUntilItIsCleared() {
        let drafts = FormDrafts()
        drafts.markSent(formId: "f", spec: Self.spec)
        #expect(drafts.draft(for: "f", spec: Self.spec).sent)
        drafts.clear(formId: "f")
        #expect(!drafts.draft(for: "f", spec: Self.spec).sent)
        #expect(drafts.drafts.isEmpty)
        drafts.clear(formId: "never")
    }
}
