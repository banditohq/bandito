import Foundation
import BanditoL10n

/// The descriptions the agent CLIs send are in English. This shows the known ones in the language of the interface,
/// and an unknown one as it is in English, or not at all in another language.
public enum ModelDescription {
    /// Known English descriptions, normalized (see `normalized`), with the L10n key of their translation. Several
    /// wordings of the same description share one key.
    static let table: [String: String] = [
        "for complex work and everyday tasks": "modelDescription.complexEveryday",
        "best for everyday, complex tasks": "modelDescription.complexEveryday",
        "opus 5.5 · best for everyday, complex tasks": "modelDescription.complexEveryday",
        "for your toughest challenges": "modelDescription.toughest",
        "most capable for your hardest and longest-running tasks": "modelDescription.toughest",
        "most efficient for simpler tasks": "modelDescription.efficient",
        "efficient for routine tasks": "modelDescription.efficient",
        "fastest for quick answers": "modelDescription.fastest",
        "latest workhorse model for coding and everyday work": "modelDescription.workhorse",
        "frontier intelligence for the most demanding work": "modelDescription.frontier",
        "fast and affordable model for easier tasks": "modelDescription.fastAffordable",
        "fast and affordable agentic coding model": "modelDescription.fastAffordable",
        "older balanced model for straightforward work": "modelDescription.olderBalanced",
        "older fast and efficient model": "modelDescription.olderFast",
        "legacy coding model": "modelDescription.legacyCoding",
        "spacexai's latest frontier model": "modelDescription.xaiLatest",
    ]

    /// The language the interface is in, as the strings are read (see `L10n.bundle`).
    public static var currentLanguageCode: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }

    /// The text of a description for `languageCode`.
    ///
    /// A known description gives its translation in that language. An unknown one is returned as it is when the
    /// language is English, and is nil in any other language, so only the model's name shows there. Nil also when
    /// there is no description at all.
    public static func localized(_ raw: String?, languageCode: String) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let key = table[normalized(raw)] {
            return translation(forKey: key, languageCode: languageCode)
        }
        return languageCode == "en" ? raw : nil
    }

    /// The form a description is matched in: trimmed, without the full stops at its end, lowercase.
    /// "For complex work and everyday tasks." and "for complex work and everyday tasks" are the same description.
    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The string of `key` in the bundle of `languageCode`. Nil when that language is not in the app.
    static func translation(forKey key: String, languageCode: String) -> String? {
        guard let bundle = LanguageBundles.shared.bundle(for: languageCode) else { return nil }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        return value == key ? nil : value
    }
}

/// The `.lproj` bundle of each language, opened once and then reused: descriptions are read in every panel and field.
final class LanguageBundles: @unchecked Sendable {
    static let shared = LanguageBundles()

    private let lock = NSLock()
    private var bundles: [String: Bundle] = [:]

    func bundle(for languageCode: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[languageCode] {
            return cached
        }
        guard let path = L10n.bundle.path(forResource: languageCode, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return nil }
        bundles[languageCode] = bundle
        return bundle
    }
}
