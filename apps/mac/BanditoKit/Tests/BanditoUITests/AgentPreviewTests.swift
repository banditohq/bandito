import Testing

@testable import BanditoUI

/// The last message of an agent as one plain line in a list row.
@Suite struct AgentPreviewTests {
    @Test func linkKeepsItsTextAndDropsTheAddress() {
        #expect(AgentPreview.plainLine("см. [доку](https://example.com/a?b=1) сейчас") == "см. доку сейчас")
        #expect(AgentPreview.plainLine("![схема](https://example.com/x.png)") == "схема")
    }

    @Test func boldAndStrikeMarksGo() {
        #expect(AgentPreview.plainLine("**важно** сделать __срочно__ и ~~не~~ надо") == "важно сделать срочно и не надо")
    }

    @Test func codeMarksGoAndTheCodeStays() {
        #expect(AgentPreview.plainLine("запусти `swift test` и `ls -la`") == "запусти swift test и ls -la")
        #expect(AgentPreview.plainLine("```\nlet a = 1\n```") == "let a = 1")
    }

    @Test func listMarkersGo() {
        #expect(AgentPreview.plainLine("- первое\n* второе\n+ третье\n1. четвёртое\n2) пятое") == "первое второе третье четвёртое пятое")
    }

    @Test func headingsAndQuotesGo() {
        #expect(AgentPreview.plainLine("## Итог\n> всё ок") == "Итог всё ок")
    }

    @Test func multilineBecomesOneLine() {
        #expect(AgentPreview.plainLine("Готово.\n\nДальше:\n  \n  пункт") == "Готово. Дальше: пункт")
    }

    @Test func hashInsideTextIsKept() {
        #expect(AgentPreview.plainLine("см. issue #65 и 2 * 3") == "см. issue #65 и 2 * 3")
    }

    @Test func emptyOrBlankGivesNothing() {
        #expect(AgentPreview.plainLine("") == nil)
        #expect(AgentPreview.plainLine(" \n\t\n ") == nil)
        #expect(AgentPreview.plainLine("**") == nil)
    }
}
