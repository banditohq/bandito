import Testing

@testable import BanditoUI

/// Markdown blocks for the preview, the checklist toggle, and the line diff used by the conflict dialog.
@Suite struct MarkdownTests {
    static let sample = """
        # Forge — память

        ## Проекты
        - **billing** — `~/projects/billing`
          Деньги в копейках.
        ## Открытые задачи
        - [ ] PR #43: тесты вебхука
        - [x] Перевести суммы
        1. первый
        > Пишу коротко.
        ```rust
        let amount = 1;
        # not a heading
        ```
        ### Конец
        """

    @Test func parsesHeadingsAndParagraphs() {
        let blocks = MarkdownParser.parse(Self.sample)
        #expect(blocks.first == .heading(level: 1, text: "Forge — память", line: 0))
        #expect(blocks.contains(.heading(level: 2, text: "Проекты", line: 2)))
        #expect(blocks.contains(.heading(level: 2, text: "Открытые задачи", line: 5)))
        #expect(blocks.contains(.heading(level: 3, text: "Конец", line: 14)))
    }

    @Test func parsesBulletsCheckboxesAndOrderedItems() {
        let blocks = MarkdownParser.parse(Self.sample)
        #expect(blocks.contains(.item(text: "**billing** — `~/projects/billing` Деньги в копейках.", line: 3, checkbox: nil)))
        #expect(blocks.contains(.item(text: "PR #43: тесты вебхука", line: 6, checkbox: false)))
        #expect(blocks.contains(.item(text: "Перевести суммы", line: 7, checkbox: true)))
        #expect(blocks.contains(.item(text: "первый", line: 8, checkbox: nil)))
    }

    @Test func parsesQuoteAndFencedCodeWithoutReadingItAsMarkdown() {
        let blocks = MarkdownParser.parse(Self.sample)
        #expect(blocks.contains(.quote(text: "Пишу коротко.", line: 9)))
        #expect(blocks.contains(.code(language: "rust", text: "let amount = 1;\n# not a heading", line: 10)))
        #expect(!blocks.contains(.heading(level: 1, text: "not a heading", line: 12)))
    }

    @Test func togglingCheckboxChangesOnlyThatLine() {
        let source = "# T\n- [ ] one\n- [x] two\n- plain\n"
        let checked = MarkdownChecklist.toggle(source, line: 1)
        #expect(checked == "# T\n- [x] one\n- [x] two\n- plain\n")
        let unchecked = MarkdownChecklist.toggle(checked ?? "", line: 2)
        #expect(unchecked == "# T\n- [x] one\n- [ ] two\n- plain\n")
    }

    @Test func togglingLineWithoutCheckboxIsNil() {
        #expect(MarkdownChecklist.toggle("- plain\n", line: 0) == nil)
        #expect(MarkdownChecklist.toggle("- [ ] x\n", line: 9) == nil)
    }

    @Test func lineDiffMarksRemovedAndAddedLines() {
        let diff = LineDiff.diff(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(
            diff == [
                DiffLine(kind: .same, text: "a"),
                DiffLine(kind: .removed, text: "b"),
                DiffLine(kind: .added, text: "B"),
                DiffLine(kind: .same, text: "c"),
                DiffLine(kind: .added, text: "d"),
            ])
    }

    @Test func lineDiffOfEqualTextHasNoChanges() {
        let diff = LineDiff.diff(old: "x\ny", new: "x\ny")
        #expect(diff.allSatisfy { $0.kind == .same })
        #expect(diff.count == 2)
    }
}

@Suite struct ViewerTabsTests {
    @Test func openingSelectsAndDoesNotDuplicate() {
        var tabs = ViewerTabs()
        tabs.open("/w/a.md")
        tabs.open("/w/b.rs")
        tabs.open("/w/a.md")
        #expect(tabs.paths == ["/w/a.md", "/w/b.rs"])
        #expect(tabs.selected == "/w/a.md")
    }

    @Test func cyclingWrapsAround() {
        var tabs = ViewerTabs()
        tabs.open("/w/a")
        tabs.open("/w/b")
        tabs.open("/w/c")
        tabs.selectNext()
        #expect(tabs.selected == "/w/a")
        tabs.selectPrevious()
        #expect(tabs.selected == "/w/c")
    }

    @Test func closingSelectedTabSelectsNeighbour() {
        var tabs = ViewerTabs()
        tabs.open("/w/a")
        tabs.open("/w/b")
        tabs.open("/w/c")
        tabs.open("/w/b")
        tabs.close("/w/b")
        #expect(tabs.paths == ["/w/a", "/w/c"])
        #expect(tabs.selected == "/w/c")
        tabs.close("/w/c")
        tabs.close("/w/a")
        #expect(tabs.paths.isEmpty)
        #expect(tabs.selected == nil)
    }
}
