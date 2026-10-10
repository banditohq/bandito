import Testing

@testable import BanditoUI

/// Pure formats of the changes header and file list: the summary chips and the icon of a changed file.
@Suite struct ChangesSummaryTests {
    @Test func chipsCarrySignAndCount() {
        #expect(ChangesChips.additions(0) == "+0")
        #expect(ChangesChips.additions(412) == "+412")
        #expect(ChangesChips.deletions(0) == "−0")
        #expect(ChangesChips.deletions(18) == "−18")
    }

    @Test func fileIconFollowsTheFileKind() {
        #expect(ChangedFileKind.category(path: "docs/README.md") == .markdown)
        #expect(ChangedFileKind.category(path: "src/app/main.swift") == .code)
        #expect(ChangedFileKind.category(path: "assets/logo.PNG") == .image)
        #expect(ChangedFileKind.category(path: "Makefile") == .other)
    }
}
