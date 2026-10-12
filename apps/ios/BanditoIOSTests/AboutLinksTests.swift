import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The links of the About section: the terms page follows the language of the app's strings.
@Suite struct AboutLinksTests {
    @Test func englishGoesToTheRootTermsPage() {
        #expect(AboutLinks.terms(forLanguage: "en").absoluteString == "https://bandito.dev/terms/")
    }

    @Test func otherLanguagesGoToTheirOwnTermsPage() {
        #expect(AboutLinks.terms(forLanguage: "ru").absoluteString == "https://bandito.dev/ru/terms/")
        #expect(AboutLinks.terms(forLanguage: "pt-BR").absoluteString == "https://bandito.dev/pt-BR/terms/")
        #expect(AboutLinks.terms(forLanguage: "zh-Hans").absoluteString == "https://bandito.dev/zh-Hans/terms/")
    }

    @Test func anUnknownLanguageGoesToEnglish() {
        #expect(AboutLinks.terms(forLanguage: "xx").absoluteString == "https://bandito.dev/terms/")
        #expect(AboutLinks.terms(forLanguage: "").absoluteString == "https://bandito.dev/terms/")
    }

    @Test func everyLanguageOfTheAppHasATermsPage() {
        // The nine codes of i18n/languages.json: English at the root, the other eight under their code.
        let codes = ["en", "ru", "ja", "zh-Hans", "ko", "es", "pt-BR", "de", "fr"]
        let urls = codes.map { AboutLinks.terms(forLanguage: $0).absoluteString }
        #expect(Set(urls).count == codes.count)
    }
}
