import AppKit
import Testing

@testable import BanditoUI
@testable import BanditoL10n

@Suite struct InterfaceLanguageChoiceTests {
    @Test func nothingStoredMeansSystem() {
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: nil) == "system")
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: []) == "system")
    }

    @Test func storedCodeSelectsItsOwnRow() {
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: ["ru"]) == "ru")
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: ["pt-BR"]) == "pt-BR")
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: ["zh-Hans"]) == "zh-Hans")
    }

    /// The system's own list has regions and matches no row. It used to leave the picker with an empty value.
    @Test func systemListWithRegionIsNotAnExplicitChoice() {
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: ["ru-RU", "en-US"]) == "system")
    }

    @Test func unknownCodeFallsBackToSystem() {
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: ["xx"]) == "system")
        #expect(InterfaceLanguageChoice.pickerTag(storedLanguages: [""]) == "system")
    }

    @Test func everyResultIsAPickerRow() {
        let rows = Set(InterfaceLanguageChoice.pickerTags)
        #expect(rows.count == L10n.languages.count + 1)
        #expect(InterfaceLanguageChoice.pickerTags.first == InterfaceLanguageChoice.systemTag)
        for entry in L10n.languages {
            #expect(rows.contains(InterfaceLanguageChoice.pickerTag(storedLanguages: [entry.code])))
        }
        for stored in [nil, ["ru-RU"], ["xx"], ["ja"]] as [[String]?] {
            #expect(rows.contains(InterfaceLanguageChoice.pickerTag(storedLanguages: stored)))
        }
    }
}

/// Round trip through a scratch defaults suite, so the test never touches the app's real preferences.
@Suite struct InterfaceLanguageStoreTests {
    private func scratch() -> (defaults: UserDefaults, domain: String) {
        let domain = "bandito.tests.language.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }

    @Test func everyCodeWrittenIsReadBack() {
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        for entry in L10n.languages {
            InterfaceLanguageStore.write(entry.code, to: defaults)
            #expect(InterfaceLanguageStore.read(from: defaults, domain: domain) == entry.code)
        }
    }

    @Test func systemRemovesTheEntryAndReadsBackAsSystem() {
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        InterfaceLanguageStore.write("ru", to: defaults)
        InterfaceLanguageStore.write(InterfaceLanguageChoice.systemTag, to: defaults)
        #expect(defaults.persistentDomain(forName: domain)?[InterfaceLanguageStore.languageKey] == nil)
        #expect(InterfaceLanguageStore.read(from: defaults, domain: domain) == "system")
    }

    @Test func nothingWrittenReadsAsSystem() {
        let (defaults, domain) = scratch()
        defer { defaults.removePersistentDomain(forName: domain) }
        #expect(InterfaceLanguageStore.read(from: defaults, domain: domain) == "system")
    }
}

@Suite struct SettingsSectionTests {
    @Test func navigationHasThirteenSectionsAndNoSeparateLanguage() {
        #expect(SettingsSection.allCases.count == 13)
        #expect(!SettingsSection.allCases.map(\.rawValue).contains("language"))
    }

    @Test func everySectionHasAValidSymbol() {
        for section in SettingsSection.allCases {
            #expect(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil) != nil, "\(section.symbol)")
        }
    }

    @Test func badgeSymbolsAreUnique() {
        let symbols = SettingsSection.allCases.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
    }
}
