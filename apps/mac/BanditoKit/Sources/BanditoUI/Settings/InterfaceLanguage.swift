import BanditoL10n
import Foundation

/// The rows of the Language picker and the row that matches the stored choice. The stored choice is the app's own
/// `AppleLanguages` entry, written by `InterfaceLanguageStore.write`. No entry means "system".
enum InterfaceLanguageChoice {
    static let systemTag = "system"

    /// Every tag the picker offers: "system" first, then the bundled language codes.
    static var pickerTags: [String] {
        [systemTag] + L10n.languages.map(\.code)
    }

    /// The picker tag for a stored list. Only an exact bundled code counts as a choice. Anything else, including the
    /// system's own list with regions ("ru-RU"), means "system", so the picker never shows an empty value.
    static func pickerTag(storedLanguages: [String]?) -> String {
        guard let first = storedLanguages?.first, L10n.languages.contains(where: { $0.code == first }) else {
            return systemTag
        }
        return first
    }
}

/// Reads and writes the interface language choice. The choice lives in the app's own `AppleLanguages` entry, which
/// the system reads at the next launch. The defaults and the app's domain are parameters, so tests use a scratch suite.
enum InterfaceLanguageStore {
    static let languageKey = "AppleLanguages"

    /// The picker tag for the choice stored in `domain` of `defaults`. The app passes its bundle identifier.
    static func read(from defaults: UserDefaults, domain: String) -> String {
        let own = defaults.persistentDomain(forName: domain)
        return InterfaceLanguageChoice.pickerTag(storedLanguages: own?[languageKey] as? [String])
    }

    /// Writes a picker tag. "system" removes the entry, so the system's own language applies again.
    static func write(_ tag: String, to defaults: UserDefaults) {
        if tag == InterfaceLanguageChoice.systemTag {
            defaults.removeObject(forKey: languageKey)
        } else {
            defaults.set([tag], forKey: languageKey)
        }
    }
}

/// Names of the interface languages, each written in its own language ("Русский", "日本語").
enum InterfaceLanguage {
    /// The name for a localization code from `i18n/languages.json`. An unknown code falls back to the source
    /// language, English, because that is the language the strings are written in.
    static func nativeName(code: String) -> String {
        L10n.languages.first { $0.code == code }?.native ?? "English"
    }

    /// The language the interface is shown in right now: the first localization the bundle resolved.
    /// This is what the Mac is actually using, not what the user picked for the next launch.
    static var current: String {
        nativeName(code: L10n.bundle.preferredLocalizations.first ?? "en")
    }
}
