import BanditoL10n
import Foundation
import Testing

@Suite struct L10nTests {
    @Test func plainAndPlaceholderStrings() {
        #expect(L10n.Approval.approve == "Approve")
        #expect(L10n.Thread.placeholder == "Write a task or a question…")
    }

    @Test func pluralCategories() {
        #expect(L10n.Thread.ranCommands(count: 1) == "Ran 1 command")
        #expect(L10n.Thread.ranCommands(count: 3) == "Ran 3 commands")
    }

    @Test func russianLprojCarriesTranslation() throws {
        let path = try #require(L10n.bundle.path(forResource: "ru", ofType: "lproj"))
        let ru = try #require(Bundle(path: path))
        #expect(ru.localizedString(forKey: "approval.approve", value: nil, table: "Localizable") == "Разрешить")
    }
}
