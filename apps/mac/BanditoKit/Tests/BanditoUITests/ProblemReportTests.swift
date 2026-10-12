import Foundation
import Testing

@testable import BanditoUI

/// The text of a problem report and the link that opens it on GitHub.
@Suite struct ProblemReportTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func theReportHasTheThreeParts() {
        let text = ProblemReport.text(what: "  It froze.\nTwice.  ", expected: "It works.", diagnostics: "Bandito 0.1.14")
        #expect(text.hasPrefix("## What happened\nIt froze.\nTwice.\n\n## What I expected\nIt works.\n\n## Diagnostics\nBandito 0.1.14"))
        let parts = ProblemReport.parse(text)
        #expect(parts == ProblemReport.Parts(what: "It froze.\nTwice.", expected: "It works.", diagnostics: "Bandito 0.1.14"))
    }

    @Test func withoutDiagnosticsThereIsNoSection() {
        let text = ProblemReport.text(what: "x", expected: "", diagnostics: nil)
        #expect(!text.contains("## Diagnostics"))
        #expect(text.contains("(not described)"))
        #expect(ProblemReport.text(what: "x", expected: "y", diagnostics: "  \n").contains("## Diagnostics") == false)
    }

    @Test func editedTextIsStillReadAndOneWithoutHeadingsIsAllWhat() {
        let parts = ProblemReport.parse("Just a note.\nSecond line.")
        #expect(parts.what == "Just a note.\nSecond line.")
        #expect(parts.expected.isEmpty && parts.diagnostics.isEmpty)
        let shuffled = ProblemReport.parse("## Diagnostics\nD\n## What happened\nW")
        #expect(shuffled == ProblemReport.Parts(what: "W", expected: "", diagnostics: "D"))
    }

    @Test func theTitleIsTheFirstLineCutAtAWord() {
        #expect(ProblemReport.title(what: "") == "Problem report")
        #expect(ProblemReport.title(what: "\n\n") == "Problem report")
        #expect(ProblemReport.title(what: "The chat freezes\nafter a minute") == "The chat freezes")
        let long = String(repeating: "word ", count: 30)
        let title = ProblemReport.title(what: long)
        #expect(title.count <= 71 && title.hasSuffix("…"))
    }

    @Test func aShortReportBecomesOneLinkWithTheFormFields() throws {
        let report = ProblemReport.text(
            what: "Files & folders: 100% broken + weird = \"quotes\"", expected: "Fine", diagnostics: "v1")
        let link = try #require(ProblemReport.link(report: report))
        #expect(link.clipboard == nil)
        let url = link.url.absoluteString
        #expect(url.hasPrefix("https://github.com/banditohq/bandito/issues/new?template=bug_report.yml&title="))
        let q = query(link.url)
        #expect(q["what"] == "Files & folders: 100% broken + weird = \"quotes\"")
        #expect(q["expected"] == "Fine")
        #expect(q["diagnostics"] == "v1")
        #expect(q["title"] == "Files & folders: 100% broken + weird = \"quotes\"")
        // No raw "&", "+", "=" or space inside a value.
        let raw = url.dropFirst("https://github.com/banditohq/bandito/issues/new?".count)
        #expect(raw.split(separator: "&").count == 5)
        #expect(!url.contains(" ") && !url.contains("+"))
    }

    @Test func cyrillicIsEncodedAsUTF8() throws {
        let link = try #require(ProblemReport.link(report: ProblemReport.text(what: "Не работает", expected: "", diagnostics: nil)))
        #expect(link.url.absoluteString.contains("%D0%9D%D0%B5"))
        #expect(query(link.url)["what"] == "Не работает")
    }

    @Test func longDiagnosticsGoToTheClipboardAndTheFormSaysSo() throws {
        let diagnostics = (0..<400).map { "line \($0) of the log with some words in it" }.joined(separator: "\n")
        let report = ProblemReport.text(what: "It froze", expected: "No freeze", diagnostics: diagnostics)
        let link = try #require(ProblemReport.link(report: report))
        #expect(link.clipboard == diagnostics)
        #expect(link.url.absoluteString.count <= ProblemReport.maxURLLength)
        let q = query(link.url)
        #expect(q["diagnostics"] == ProblemReport.pasteNote)
        #expect(q["what"] == "It froze")
        #expect(q["expected"] == "No freeze")
    }

    @Test func theLimitIsAboutTheEncodedAddressNotTheCharacters() throws {
        // 1 200 Cyrillic letters are about 7 000 characters once encoded: more than the limit.
        let what = String(repeating: "я", count: 1_200)
        let link = try #require(ProblemReport.link(report: ProblemReport.text(what: what, expected: "", diagnostics: nil)))
        #expect(link.url.absoluteString.count <= ProblemReport.maxURLLength)
        #expect(link.clipboard != nil, "the whole report is on the clipboard when the answers were shortened")
        #expect(query(link.url)["what"]?.hasSuffix("…") == true)
    }

    @Test func aSmallLimitStillGivesALinkAndTheWholeReportOnTheClipboard() throws {
        let report = ProblemReport.text(what: String(repeating: "x", count: 500), expected: "y", diagnostics: "d")
        let link = try #require(ProblemReport.link(report: report, limit: 400))
        #expect(link.clipboard != nil)
    }
}
