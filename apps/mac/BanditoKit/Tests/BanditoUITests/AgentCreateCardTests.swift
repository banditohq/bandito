import SwiftUI
import Testing

@testable import BanditoKit
@testable import BanditoL10n
@testable import BanditoUI

/// The card of an agent that asks to create another agent, and the row of quick replies: what they say, as pure
/// values (docs/ARCHITECTURE.md#agents-creating-agents, #quick-replies).
@MainActor
@Suite struct AgentCreateCardTests {
    static let input: JSONValue = .object([
        "name": .string("Mailer"), "role": .string("mail watcher"), "runtime": .string("claude"),
        "model": .string("sonnet"), "approvalMode": .string("risky"),
        "capabilities": .array([.string("browser"), .string("team"), .string("telepathy")]),
        "integrations": .array([.string("Gmail"), .string("Notion")]), "integrationsAll": .bool(false),
        "schedules": .array([
            .object([
                "title": .string("Mail"), "prompt": .string("Check the mail"), "humanEn": .string("every 5 minutes"),
                "humanRu": .string("каждые 5 минут"),
            ])
        ]),
        "folder": .object(["mode": .string("new"), "path": .string("/agents/mailer")]),
        "instructions": .string("Watch the mailbox and report new letters."), "creator": .string("Forge"),
    ])

    static func row(
        _ state: ApprovalState = .pending, input: JSONValue? = AgentCreateCardTests.input,
        tool: String = AgentCreateSummary.tool
    ) -> ApprovalRow {
        ApprovalRow(
            approvalId: "ap1", tool: tool, title: "Create agent «Mailer»", command: "Mailer · claude sonnet\nFolder: new",
            diff: nil, reason: "agent: create", state: state, input: input)
    }

    private var summary: AgentCreateSummary { AgentCreateSummary(input: Self.input)! }

    @Test func theRowsSayEverythingThePersonDecidesOn() throws {
        L10n.withLanguageForTests("en") {
            let rows = AgentCreateRows.rows(summary, languageCode: "en")
            #expect(rows.map(\.id) == ["role", "runtime", "mode", "can", "services", "runs", "folder", "instructions"])
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
            #expect(byID["role"] == "mail watcher")
            #expect(byID["runtime"] == "Claude · sonnet")
            #expect(byID["mode"] == ApprovalMode.risky.title)
            // The chips' names in their order; a capability this app does not know is shown as sent.
            #expect(byID["can"] == "\(AgentCapability.browser.title) · \(AgentCapability.team.title) · telepathy")
            #expect(byID["services"] == "Gmail, Notion")
            #expect(byID["runs"] == "every 5 minutes: Mail")
            #expect(byID["folder"] == "A new folder of its own")
            #expect(byID["instructions"] == "Watch the mailbox and report new letters.")
            #expect(rows.first { $0.id == "folder" }?.mono == false)
        }
    }

    @Test func theRunsSpeakTheLanguageOfTheApp() {
        L10n.withLanguageForTests("ru") {
            let rows = AgentCreateRows.rows(summary, languageCode: "ru")
            #expect(rows.first { $0.id == "runs" }?.value == "каждые 5 минут: Mail")
        }
    }

    @Test func anExistingFolderIsShownAsAPath() throws {
        let input = JSONValue.object([
            "name": .string("Mailer"),
            "folder": .object(["mode": .string("existing"), "path": .string("/Users/me/work")]),
        ])
        let s = try #require(AgentCreateSummary(input: input))
        let folder = try #require(AgentCreateRows.rows(s, languageCode: "en").first { $0.id == "folder" })
        #expect(folder.value == "/Users/me/work" && folder.mono)
    }

    @Test func servicesAndCapabilitiesHaveWordsWhenThereAreNone() throws {
        func s(_ fields: [String: JSONValue]) throws -> AgentCreateSummary {
            try #require(AgentCreateSummary(input: .object(["name": .string("X")].merging(fields) { $1 })))
        }
        L10n.withLanguageForTests("en") {
            #expect(AgentCreateRows.capabilitiesLine((try? s([:]))!) == "Nothing extra")
            #expect(AgentCreateRows.servicesLine((try? s([:]))!) == "None")
            #expect(AgentCreateRows.servicesLine((try? s(["integrationsAll": .bool(true)]))!) == "All enabled")
            let some = try? s(["integrationsAll": .bool(true), "integrations": .array([.string("Gmail")])])
            #expect(AgentCreateRows.servicesLine(some!) == "All enabled · Gmail")
        }
    }

    @Test func aLongRunIsCutAndAnEmptyTimingIsLeftOut() {
        let long = AgentCreateSummary.Run(title: nil, prompt: String(repeating: "word ", count: 40), humanEn: "", humanRu: "")
        let line = AgentCreateRows.runLine(long, languageCode: "en")
        #expect(line.count == AgentCreateRows.runNameLimit && line.hasSuffix("…"))
        let timed = AgentCreateSummary.Run(title: "Mail", prompt: "x", humanEn: "every hour", humanRu: "")
        // Russian words that the daemon did not send fall back to the English ones.
        #expect(timed.timing(languageCode: "ru") == "every hour")
    }

    @Test func theFoldedLinesSayWhatHappened() {
        L10n.withLanguageForTests("en") {
            #expect(AgentCreateRows.resolvedLine(for: .pending, name: "Mailer") == nil)
            #expect(AgentCreateRows.resolvedLine(for: .approved(by: .user, remember: false), name: "Mailer") == "You allowed creating “Mailer”")
            #expect(AgentCreateRows.resolvedLine(for: .denied(by: .user), name: "Mailer") == "You declined creating “Mailer”")
            // Denied by the daemon: nobody answered in time, or the agent went away.
            #expect(AgentCreateRows.resolvedLine(for: .denied(by: .policy), name: "Mailer") == "The request to create “Mailer” timed out")
            #expect(AgentCreateRows.resolvedLine(for: .withdrawn, name: "Mailer") == "The request to create “Mailer” timed out")
        }
    }

    @Test func onlyLongInstructionsGoInTheScrollingBox() {
        #expect(!AgentCreateRows.scrolls("Watch the mailbox."))
        #expect(!AgentCreateRows.scrolls(String(repeating: "a", count: AgentCreateRows.scrollCharacters)))
        #expect(AgentCreateRows.scrolls(String(repeating: "a", count: AgentCreateRows.scrollCharacters + 1)))
        #expect(!AgentCreateRows.scrolls(Array(repeating: "line", count: AgentCreateRows.scrollLines).joined(separator: "\n")))
        #expect(AgentCreateRows.scrolls(Array(repeating: "line", count: AgentCreateRows.scrollLines + 1).joined(separator: "\n")))
    }

    @Test func theReasonIsInWords() {
        L10n.withLanguageForTests("en") {
            #expect(ApprovalReason.text("agent: create") == "creates an agent")
        }
    }

    @Test func onlyACreationApprovalWithAReadableInputGetsTheCard() {
        #expect(AgentCreateRows.summary(for: Self.row())?.name == "Mailer")
        // Another tool never turns into a creation card, whatever its input says.
        #expect(AgentCreateRows.summary(for: Self.row(tool: "Bash")) == nil)
        // A creation from a daemon that sent no input, or an input without a name, stays the plain card.
        #expect(AgentCreateRows.summary(for: Self.row(input: nil)) == nil)
        #expect(AgentCreateRows.summary(for: Self.row(input: .object(["role": .string("x")]))) == nil)
    }
}

@MainActor
@Suite struct QuickRepliesRulesTests {
    private func set(
        _ buttons: [(String, String)], link: QuickReplyLink? = nil, progress: QuickReplyProgress? = nil, seq: Int64 = 1
    ) -> QuickReplies {
        QuickReplies(
            buttons: buttons.map { QuickReplyButton(label: $0.0, reply: $0.1) }, link: link, progress: progress, seq: seq)
    }

    @Test func theFirstButtonIsThePrimaryOne() {
        let shown = QuickRepliesRules.buttons(set([("Done", "Connected"), ("Later", "Not now")]))
        #expect(shown.map(\.label) == ["Done", "Later"])
        #expect(shown.map(\.isPrimary) == [true, false])
        #expect(shown.map(\.reply) == ["Connected", "Not now"])
        // The label is the whole reply: nothing to tell on hover.
        #expect(QuickRepliesRules.buttons(set([("Yes", "Yes")]))[0].help == nil)
        #expect(shown[0].help == "Connected")
    }

    @Test func buttonsAreBoundedAndOneLine() {
        let many = QuickRepliesRules.buttons(set((0..<7).map { ("b\($0)", "r\($0)") }))
        #expect(many.count == QuickRepliesRules.maxButtons)
        let long = QuickRepliesRules.buttons(set([(String(repeating: "x", count: 90), "r")]))[0]
        #expect(long.label.count == QuickRepliesRules.labelLimit && long.label.hasSuffix("…"))
        let broken = QuickRepliesRules.buttons(set([("two\nlines", "r")]))[0]
        #expect(broken.label == "two lines")
        // A button that could send nothing is not drawn, and the next one becomes the primary.
        let empty = QuickRepliesRules.buttons(set([("", "r"), ("x", "  "), ("ok", "go")]))
        #expect(empty.map(\.label) == ["ok"] && empty[0].isPrimary)
    }

    @Test func aLinkIsHttpsWithAHostOnly() {
        for good in ["https://mail.google.com/mail/u/0/#settings", "https://example.com:8443/x?y=1"] {
            #expect(QuickRepliesRules.webURL(good) != nil, "\(good)")
        }
        for bad in [
            "http://example.com", "javascript:alert(1)", "file:///etc/passwd", "https://", "https://user@evil.com",
            "https://user:pw@evil.com", "https://exa mple.com", "example.com", "", "   ", "bandito-file://open?path=/etc/passwd",
        ] {
            #expect(QuickRepliesRules.webURL(bad) == nil, "\(bad)")
        }
        let long = QuickReplies(
            buttons: [QuickReplyButton(label: "a", reply: "b")], link: QuickReplyLink(label: "Open", url: "https://example.com/" + String(repeating: "a", count: 2000)))
        #expect(QuickRepliesRules.link(long) == nil)
        let ok = set([("a", "b")], link: QuickReplyLink(label: " Open Gmail ", url: "https://mail.google.com"))
        #expect(QuickRepliesRules.link(ok)?.label == "Open Gmail")
        #expect(QuickRepliesRules.link(ok)?.url.host == "mail.google.com")
        #expect(QuickRepliesRules.link(set([("a", "b")], link: QuickReplyLink(label: "", url: "https://example.com"))) == nil)
    }

    @Test func theProgressIsACount() {
        L10n.withLanguageForTests("en") {
            #expect(QuickRepliesRules.progressText(QuickReplyProgress(done: 2, total: 6)) == "2 of 6")
            #expect(QuickRepliesRules.progressText(QuickReplyProgress(done: 0, total: 3)) == "0 of 3")
            #expect(QuickRepliesRules.progressText(QuickReplyProgress(done: 4, total: 3)) == nil)
            #expect(QuickRepliesRules.progressText(QuickReplyProgress(done: 1, total: 0)) == nil)
            #expect(QuickRepliesRules.progressText(nil) == nil)
        }
        L10n.withLanguageForTests("ru") {
            #expect(QuickRepliesRules.progressText(QuickReplyProgress(done: 2, total: 6)) == "2 из 6")
        }
    }

    @Test func aPressedSetIsHiddenAtOnceAndAnotherOneComesBack() {
        let first = set([("a", "b")], seq: 10)
        #expect(QuickRepliesRules.shown(first, pressed: nil) == first)
        #expect(QuickRepliesRules.shown(first, pressed: first.id) == nil)
        // The next set (another seq) is not the one that was pressed.
        let second = set([("c", "d")], seq: 11)
        #expect(QuickRepliesRules.shown(second, pressed: first.id) == second)
        #expect(QuickRepliesRules.shown(nil, pressed: nil) == nil)
        #expect(QuickRepliesRules.shown(set([("", "")]), pressed: nil) == nil)
    }
}

/// Pictures for review: PNG files go to `BANDITO_SNAPSHOTS`.
@MainActor
@Suite struct AgentCreateSnapshots {
    @Test func theCardAndTheButtons() throws {
        let view = VStack(alignment: .leading, spacing: 20) {
            ApprovalCard(row: AgentCreateCardTests.row(), agentName: "Forge", onDecide: { _, _ in })
            ApprovalCard(
                row: AgentCreateCardTests.row(
                    input: .object([
                        "name": .string("Long"), "runtime": .string("claude"), "approvalMode": .string("always"),
                        "instructions": .string(String(repeating: "Report each new letter in one line. ", count: 60)),
                    ])),
                agentName: "Forge", onDecide: { _, _ in })
            ApprovalCard(row: AgentCreateCardTests.row(.approved(by: .user, remember: false)), agentName: "Forge", onDecide: { _, _ in })
            ApprovalCard(row: AgentCreateCardTests.row(.denied(by: .user)), agentName: "Forge", onDecide: { _, _ in })
            QuickRepliesBar(
                replies: QuickReplies(
                    buttons: [
                        QuickReplyButton(label: "Done, it is connected", reply: "The mailbox is connected"),
                        QuickReplyButton(label: "Not yet", reply: "Not yet"),
                    ],
                    link: QuickReplyLink(label: "Open Gmail settings", url: "https://mail.google.com"),
                    progress: QuickReplyProgress(done: 2, total: 6), seq: 1),
                onReply: { _ in }, onOpen: { _ in })
        }
        .padding(24)
        .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        let url = try SnapshotSupport.render(view, "chat-agent-create-card", size: CGSize(width: 680, height: 1250))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
