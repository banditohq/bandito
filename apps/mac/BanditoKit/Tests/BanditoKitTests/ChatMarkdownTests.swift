import Foundation
import Testing

@testable import BanditoKit

/// The blocks the iPhone chat draws: headings, lists, quotes, rules, paragraphs and fenced code.
@Suite struct ChatMarkdownTests {
    @Test func aPlainMessageIsOneParagraph() {
        let blocks = ChatMarkdown.parse("Build is green.\nPushing next.", markdown: true)
        #expect(blocks == [.paragraph("Build is green.\nPushing next.")])
        #expect(ChatMarkdown.isPlain(blocks))
    }

    @Test func headingsListsAndQuotesAreBlocks() {
        let text = """
            ## Plan
            - first
            - second
              wraps here
            1. one
            2) two
            > careful
            > now
            ---
            done
            """
        let blocks = ChatMarkdown.parse(text, markdown: true)
        #expect(
            blocks == [
                .heading(level: 2, text: "Plan"),
                .listItem(marker: "•", depth: 0, text: "first"),
                .listItem(marker: "•", depth: 0, text: "second\nwraps here"),
                .listItem(marker: "1.", depth: 0, text: "one"),
                .listItem(marker: "2.", depth: 0, text: "two"),
                .quote("careful\nnow"),
                .rule,
                .paragraph("done"),
            ])
        #expect(!ChatMarkdown.isPlain(blocks))
    }

    @Test func nestedItemsKeepTheirDepthAndTasksGetBoxes() {
        let blocks = ChatMarkdown.parse("- a\n  - b\n    - c\n- [ ] todo\n- [x] done", markdown: true)
        #expect(
            blocks == [
                .listItem(marker: "•", depth: 0, text: "a"),
                .listItem(marker: "•", depth: 1, text: "b"),
                .listItem(marker: "•", depth: 2, text: "c"),
                .listItem(marker: "☐", depth: 0, text: "todo"),
                .listItem(marker: "☑", depth: 0, text: "done"),
            ])
    }

    @Test func codeFencesBecomeCodeBlocksAndTheirContentIsNotRead() {
        let text = "Run:\n```swift\n# not a heading\n- not a list\n```\nThen stop."
        let blocks = ChatMarkdown.parse(text, markdown: true)
        #expect(
            blocks == [
                .paragraph("Run:"),
                .code(language: "swift", code: "# not a heading\n- not a list", closed: true),
                .paragraph("Then stop."),
            ])
    }

    @Test func aFenceThatIsStillStreamingIsNotClosed() {
        let blocks = ChatMarkdown.parse("Here:\n```rust\nfn main() {", markdown: true)
        #expect(blocks.last == .code(language: "rust", code: "fn main() {", closed: false))
    }

    @Test func aPersonsMessageIsKeptAsTyped() {
        let blocks = ChatMarkdown.parse("# not a heading\n- not a list\n```\ncode\n```", markdown: false)
        #expect(blocks == [.paragraph("# not a heading\n- not a list"), .code(language: nil, code: "code", closed: true)])
    }

    @Test func aTableIsShownAsMonospacedText() {
        let blocks = ChatMarkdown.parse("| a | b |\n|---|---|\n| 1 | 2 |", markdown: true)
        #expect(blocks == [.code(language: nil, code: "| a | b |\n|---|---|\n| 1 | 2 |", closed: true)])
    }

    @Test func aHashWithoutASpaceIsText() {
        #expect(ChatMarkdown.parse("#tag and more", markdown: true) == [.paragraph("#tag and more")])
        #expect(ChatMarkdown.parse("-5 degrees", markdown: true) == [.paragraph("-5 degrees")])
    }

    @Test func onlyWebLinksOpenInTheBrowser() {
        #expect(ChatLinkSafety.webURL(URL(string: "https://bandito.dev")!) != nil)
        #expect(ChatLinkSafety.webURL(URL(string: "file:///etc/passwd")!) == nil)
        #expect(ChatLinkSafety.webURL(URL(string: "javascript:alert(1)")!) == nil)
        #expect(ChatLinkSafety.webURL(URL(string: "bandito-file://open?path=a.swift")!) == nil)
        #expect(ChatLinkSafety.firstWebLink(in: "see https://bandito.dev/docs, then Composer.swift")?.host == "bandito.dev")
        #expect(ChatLinkSafety.firstWebLink(in: "only Composer.swift") == nil)
    }
}
