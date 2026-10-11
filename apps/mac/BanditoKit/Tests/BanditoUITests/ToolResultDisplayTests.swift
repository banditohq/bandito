import Foundation
import Testing

@testable import BanditoUI

/// "Try": the text of an answer is shown as indented JSON when it is a JSON object or array, and as it came otherwise.
@Suite struct ToolResultDisplayTests {
    @Test func objectIsIndentedByTwoSpacesWithKeysSorted() {
        let shown = ToolResultText.display(#"{"b":1,"a":{"x":[1,2]}}"#)
        let expected = [
            "{",
            "  \"a\" : {",
            "    \"x\" : [",
            "      1,",
            "      2",
            "    ]",
            "  },",
            "  \"b\" : 1",
            "}",
        ].joined(separator: "\n")
        #expect(shown == expected)
    }

    @Test func arrayOfObjectsIsIndented() {
        let shown = ToolResultText.display(#"[{"id":"t1"}]"#)
        let expected = [
            "[",
            "  {",
            "    \"id\" : \"t1\"",
            "  }",
            "]",
        ].joined(separator: "\n")
        #expect(shown == expected)
    }

    @Test func slashesInsideStringsAreNotEscaped() {
        let shown = ToolResultText.display(#"{"url":"https://example.com/a"}"#)
        #expect(shown.contains("\"https://example.com/a\""))
    }

    @Test func plainTextIsLeftAsItIs() {
        let text = "Done: 3 files changed\n\nsecond part"
        #expect(ToolResultText.display(text) == text)
    }

    @Test func invalidJSONIsLeftAsItIs() {
        let text = "{not json, the tool said so"
        #expect(ToolResultText.display(text) == text)
    }

    @Test func scalarJSONIsLeftAsItIs() {
        // A number or a quoted string is valid JSON too; reformatting it would rewrite what the tool said.
        #expect(ToolResultText.display("1.0") == "1.0")
        #expect(ToolResultText.display("\"quoted\"") == "\"quoted\"")
    }
}
