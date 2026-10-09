import Testing

@testable import BanditoUI
@testable import BanditoL10n

@Suite struct InterfaceLanguageTests {
    @Test func codesMapToTheirOwnNames() {
        #expect(InterfaceLanguage.nativeName(code: "en") == "English")
        #expect(InterfaceLanguage.nativeName(code: "ru") == "Русский")
        #expect(InterfaceLanguage.nativeName(code: "ja") == "日本語")
        #expect(InterfaceLanguage.nativeName(code: "zh-Hans") == "简体中文")
        #expect(InterfaceLanguage.nativeName(code: "ko") == "한국어")
        #expect(InterfaceLanguage.nativeName(code: "es") == "Español")
        #expect(InterfaceLanguage.nativeName(code: "pt-BR") == "Português (Brasil)")
        #expect(InterfaceLanguage.nativeName(code: "de") == "Deutsch")
        #expect(InterfaceLanguage.nativeName(code: "fr") == "Français")
    }

    @Test func everyBundledLanguageHasAName() {
        for entry in L10n.languages {
            #expect(InterfaceLanguage.nativeName(code: entry.code) == entry.native)
        }
    }

    @Test func unknownCodeFallsBackToEnglish() {
        #expect(InterfaceLanguage.nativeName(code: "system") == "English")
        #expect(InterfaceLanguage.nativeName(code: "") == "English")
        #expect(InterfaceLanguage.nativeName(code: "xx-YY") == "English")
    }

    @Test func currentFollowsTheResolvedLocalization() {
        let code = L10n.bundle.preferredLocalizations.first ?? "en"
        #expect(InterfaceLanguage.current == InterfaceLanguage.nativeName(code: code))
    }
}
