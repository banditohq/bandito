import BanditoL10n
import Foundation
import NaturalLanguage

/// Which language a spoken or dictated text is in. Pure functions, apart from the app's own language.
enum SpeechLanguage {
    /// The app's languages, as BCP-47 tags for the speech synthesiser and recogniser.
    static let tags: [String: String] = [
        "en": "en-US", "ru": "ru-RU", "ja": "ja-JP", "zh-Hans": "zh-CN", "ko": "ko-KR",
        "es": "es-ES", "pt-BR": "pt-BR", "de": "de-DE", "fr": "fr-FR",
    ]

    /// The language the app runs in (its strings), as a code from `tags`.
    static var appLanguage: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }

    /// The voice for `text`: its dominant language when it is one of the app's languages, else the app's language.
    static func voiceTag(for text: String, appLanguage: String) -> String {
        if let detected = NLLanguageRecognizer.dominantLanguage(for: text), let tag = tag(forRecognized: detected.rawValue) {
            return tag
        }
        return tags[appLanguage] ?? "en-US"
    }

    /// The recogniser's locale for dictation: the app's language.
    static func dictationTag(appLanguage: String) -> String {
        tags[appLanguage] ?? "en-US"
    }

    /// `NLLanguage` raw values to a tag: Portuguese is read as Brazilian, the only Portuguese the app ships.
    static func tag(forRecognized code: String) -> String? {
        switch code {
        case "pt": return tags["pt-BR"]
        default: return tags[code]
        }
    }
}
