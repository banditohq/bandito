import Testing

@testable import BanditoUI

@Suite struct ModelDescriptionTests {
    static let languages = ["en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"]

    @Test func aKnownDescriptionIsTranslated() {
        #expect(ModelDescription.localized("For complex work and everyday tasks", languageCode: "ru")
            == "Для сложной и повседневной работы")
    }

    @Test func caseAndTrailingDotDoNotMatter() {
        #expect(ModelDescription.localized("  FOR COMPLEX WORK AND EVERYDAY TASKS.  ", languageCode: "ru")
            == "Для сложной и повседневной работы")
        #expect(ModelDescription.localized("Opus 5.5 · Best for everyday, complex tasks", languageCode: "ru")
            == "Для сложной и повседневной работы")
    }

    @Test func everyWordingOfADescriptionGivesTheSameText() {
        #expect(ModelDescription.localized("most efficient for simpler tasks", languageCode: "ru")
            == "Экономно для простых задач")
        #expect(ModelDescription.localized("efficient for routine tasks.", languageCode: "ru")
            == "Экономно для простых задач")
        #expect(ModelDescription.localized("spacexai's latest frontier model", languageCode: "ru")
            == "Новейшая модель xAI")
    }

    @Test func aKnownDescriptionIsItsEnglishTextInEnglish() {
        #expect(ModelDescription.localized("fastest for quick answers", languageCode: "en")
            == "Fastest for quick answers")
    }

    @Test func anUnknownDescriptionIsShownAsItIsInEnglish() {
        #expect(ModelDescription.localized("Some new model description", languageCode: "en")
            == "Some new model description")
    }

    @Test func anUnknownDescriptionIsNilInOtherLanguages() {
        #expect(ModelDescription.localized("Some new model description", languageCode: "ru") == nil)
        #expect(ModelDescription.localized("Some new model description", languageCode: "zh-Hans") == nil)
    }

    @Test func noDescriptionIsNil() {
        #expect(ModelDescription.localized(nil, languageCode: "en") == nil)
        #expect(ModelDescription.localized("   ", languageCode: "en") == nil)
    }

    @Test func aLanguageTheAppDoesNotHaveGivesNilForAKnownDescription() {
        #expect(ModelDescription.localized("legacy coding model", languageCode: "xx") == nil)
    }

    @Test func everyKnownDescriptionHasATranslationInEveryLanguage() {
        let samples = [
            "for complex work and everyday tasks", "for your toughest challenges",
            "most efficient for simpler tasks", "fastest for quick answers",
            "latest workhorse model for coding and everyday work",
            "frontier intelligence for the most demanding work",
            "fast and affordable model for easier tasks", "older balanced model for straightforward work",
            "older fast and efficient model", "legacy coding model", "spacexai's latest frontier model",
        ]
        for language in Self.languages {
            for sample in samples {
                let text = ModelDescription.localized(sample, languageCode: language)
                #expect(text != nil, "\(sample) in \(language)")
                #expect(text != sample, "\(sample) in \(language) is translated")
            }
        }
    }

    @Test func normalizedFormDropsTheDotAndLowercases() {
        #expect(ModelDescription.normalized("For Complex Work.") == "for complex work")
        #expect(ModelDescription.normalized(" legacy coding model.. ") == "legacy coding model")
    }
}
