import BanditoL10n

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
