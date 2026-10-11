import Foundation

/// How the bot and skill catalogs pick a language. English and Russian have their own fields (`*_en`, `*_ru`); the
/// other seven languages are keys of `l10n`. The same rule is used by the daemon for the prompts of a schedule.
public enum CatalogLanguage {
    /// The languages the catalogs are written in, as the daemon keys them.
    public static let supported = ["en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"]

    public static func isRussian(_ languageCode: String) -> Bool {
        normalized(languageCode).hasPrefix("ru")
    }

    /// A language code in the form the catalogs compare: `pt_BR` and `pt-br` are `pt-br`.
    public static func normalized(_ languageCode: String) -> String {
        languageCode.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func primary(_ normalizedCode: String) -> String {
        normalizedCode.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalizedCode
    }

    /// The key of `l10n` that holds the texts for `languageCode`: an exact match, else the key of the same language
    /// (`zh-Hant` finds `zh-Hans`, `de-AT` finds `de`). Nil for Russian and English, which have their own fields, and
    /// for a language the catalog does not have: the texts then read in English.
    public static func translationKey(in keys: some Collection<String>, languageCode: String) -> String? {
        if isRussian(languageCode) { return nil }
        let wanted = normalized(languageCode)
        if let exact = keys.first(where: { normalized($0) == wanted }) { return exact }
        let language = primary(wanted)
        if language == "en" { return nil }
        return keys.sorted().first { primary(normalized($0)) == language }
    }

    /// The tag sent as `language` to `agents.create_from_template`: the app's language as the daemon knows it
    /// (`ru`, `en`, `pt-BR`, `zh-Hans`, …), and `en` for any other.
    public static func requestCode(_ languageCode: String) -> String {
        let wanted = normalized(languageCode)
        if let exact = supported.first(where: { normalized($0) == wanted }) { return exact }
        let language = primary(wanted)
        return supported.first { primary(normalized($0)) == language } ?? "en"
    }
}
