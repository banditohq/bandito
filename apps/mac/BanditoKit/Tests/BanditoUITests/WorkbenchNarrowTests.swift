import SwiftUI
import Testing

@testable import BanditoL10n
@testable import BanditoUI

/// The workbench panel at its narrowest width (`WorkbenchLayout.minWidth`) shows all of its content: nothing asks for more
/// width than the panel has and nothing is drawn outside it, in the languages with the longest words, the widest letters
/// and the CJK glyphs. Pictures go to `LAYOUT_AUDIT_DIR` when it is set.
@MainActor
@Suite(.serialized) struct WorkbenchNarrowTests {
    private static let languages = ["en", "de", "ru", "ja"]

    @Test func panelContentFitsTheNarrowestPanel() {
        var problems: [String] = []
        for language in Self.languages {
            L10n.withLanguageForTests(language) {
                for item in ScreenWorkSuites.LayoutAuditSnapshots.inspectorPanels {
                    let finding = LayoutAudit.audit(item, language: language, into: LayoutAudit.outputDirectory)
                    if finding.isProblem { problems.append(finding.description) }
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
