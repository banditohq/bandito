import Testing

@testable import BanditoL10n
@testable import BanditoUI

/// Pure formats of the changes header and file list: the stats line, the footer layout and the icon of a changed file.
@Suite struct ChangesSummaryTests {
    @Test func chipsCarrySignAndCount() {
        #expect(ChangesChips.additions(0) == "+0")
        #expect(ChangesChips.additions(412) == "+412")
        #expect(ChangesChips.deletions(0) == "−0")
        #expect(ChangesChips.deletions(18) == "−18")
    }

    @Test func statsLineIsFilesThenLines() {
        #expect(
            ChangesSummaryLine.stats(files: 6, additions: 412, deletions: 18)
                == "\(L10n.Changes.fileCount(count: 6)) · +412 −18")
        #expect(
            ChangesSummaryLine.stats(files: 1, additions: 0, deletions: 0)
                == "\(L10n.Changes.fileCount(count: 1)) · +0 −0")
    }

    @Test func footerStacksBelowTheRowWidth() {
        // The narrow workbench panel (about 320 to 360 pt) always stacks.
        #expect(ChangesFooterLayout.isStacked(width: 320))
        #expect(ChangesFooterLayout.isStacked(width: 360))
        #expect(ChangesFooterLayout.isStacked(width: ChangesFooterLayout.rowMinWidth - 1))
        // From the row width on, one row: the two quiet buttons, the hint, the main button.
        #expect(!ChangesFooterLayout.isStacked(width: ChangesFooterLayout.rowMinWidth))
        #expect(!ChangesFooterLayout.isStacked(width: 900))
    }

    @Test func fileIconFollowsTheFileKind() {
        #expect(ChangedFileKind.category(path: "docs/README.md") == .markdown)
        #expect(ChangedFileKind.category(path: "src/app/main.swift") == .code)
        #expect(ChangedFileKind.category(path: "assets/logo.PNG") == .image)
        #expect(ChangedFileKind.category(path: "Makefile") == .other)
    }
}
