import Foundation

/// The "What's new" notes of one release, read from `release-notes/<version>.json` (copied into the app bundle).
/// Each item has an SF Symbol and a title and a text in the app's nine languages.
public struct ReleaseNotes: Equatable, Sendable, Decodable {
    public struct Item: Equatable, Sendable, Decodable {
        public let icon: String
        public let title: [String: String]
        public let text: [String: String]
    }

    /// One item in one language: what a card shows.
    public struct Line: Equatable, Sendable, Identifiable {
        public let icon: String
        public let title: String
        public let text: String
        public let id: Int
    }

    public let version: String
    /// `YYYY-MM-DD`.
    public let date: String
    public let items: [Item]

    /// The languages of the app, as `L10n.languages` names them; every item has all of them.
    public static let languages = ["en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"]
    /// The language the notes fall back to.
    public static let fallbackLanguage = "en"
    public static let itemRange = 3...6

    /// Reads one file. Throws for bad JSON and for a file that breaks the rules (`problems`): a broken file is not shown.
    public static func parse(_ data: Data, fileName: String? = nil) throws -> ReleaseNotes {
        let notes = try JSONDecoder().decode(ReleaseNotes.self, from: data)
        var found = notes.problems()
        if let fileName, fileName != "\(notes.version).json" {
            found.append("the file name must be \(notes.version).json")
        }
        guard found.isEmpty else { throw ReleaseNotesError.invalid(found) }
        return notes
    }

    /// Everything wrong with the notes, one line each (same rules as `scripts/check_release_notes.py`).
    public func problems() -> [String] {
        var out: [String] = []
        if SemanticVersion(version) == nil { out.append("version is not X.Y.Z") }
        if Self.parseDate(date) == nil { out.append("date is not a real YYYY-MM-DD date") }
        if !Self.itemRange.contains(items.count) {
            out.append("items must be \(Self.itemRange.lowerBound) to \(Self.itemRange.upperBound), not \(items.count)")
        }
        for (index, item) in items.enumerated() {
            let number = index + 1
            if item.icon.isEmpty { out.append("item \(number): icon is empty") }
            for (field, values) in [("title", item.title), ("text", item.text)] {
                for code in Self.languages
                where values[code]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                    out.append("item \(number): \(field).\(code) is missing or empty")
                }
                for code in values.keys where !Self.languages.contains(code) {
                    out.append("item \(number): \(field).\(code) is not a language of the app")
                }
            }
        }
        return out
    }

    /// The cards in a language. A language the notes do not have falls back to English, per field.
    public func lines(language: String) -> [Line] {
        items.enumerated().map { index, item in
            Line(
                icon: item.icon,
                title: item.title[language] ?? item.title[Self.fallbackLanguage] ?? "",
                text: item.text[language] ?? item.text[Self.fallbackLanguage] ?? "",
                id: index)
        }
    }

    /// The language the notes open in: the app's own when the notes have it, else English. `preferred` is the app's
    /// languages in order (`Bundle.preferredLocalizations`); region tags ("zh-Hans-CN", "pt-PT", "en-GB") map to the
    /// nearest language of the app.
    public func defaultLanguage(preferred: [String]) -> String {
        for tag in preferred {
            if let code = Self.supportedCode(for: tag), hasLanguage(code) { return code }
        }
        return Self.fallbackLanguage
    }

    /// Whether every item has this language.
    public func hasLanguage(_ code: String) -> Bool {
        items.allSatisfy { $0.title[code] != nil && $0.text[code] != nil }
    }

    /// The app's language code a locale tag stands for, or nil.
    public static func supportedCode(for tag: String) -> String? {
        let lowered = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if let exact = languages.first(where: { $0.lowercased() == lowered }) { return exact }
        let base = lowered.split(separator: "-").first.map(String.init) ?? lowered
        switch base {
        case "pt": return "pt-BR"
        case "zh": return lowered.contains("hant") ? nil : "zh-Hans"
        default: return languages.first { $0 == base }
        }
    }

    // MARK: Date

    /// The date as a calendar date at noon UTC (no day shift in any time zone), or nil for a bad text.
    public static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day)
        else { return nil }
        return date
    }
}

public enum ReleaseNotesError: Error, Equatable {
    case invalid([String])
}

/// The notes of all versions, read once from a folder. Broken files are left out (the CI check keeps them from
/// shipping), so a bad file never blocks the app.
public struct ReleaseNotesLibrary: Equatable, Sendable {
    public let notes: [String: ReleaseNotes]

    public init(notes: [ReleaseNotes]) {
        var byVersion: [String: ReleaseNotes] = [:]
        for entry in notes { byVersion[entry.version] = entry }
        self.notes = byVersion
    }

    /// The folder of the app bundle the build copies `release-notes/` into.
    public static func bundledFolder(_ bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "release-notes", withExtension: nil)
    }

    /// Reads every `*.json` of a folder. Do this off the main thread.
    public static func load(from folder: URL?) -> ReleaseNotesLibrary {
        guard let folder,
            let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return ReleaseNotesLibrary(notes: []) }
        let parsed = names.filter { $0.hasSuffix(".json") }.compactMap { name -> ReleaseNotes? in
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return try? ReleaseNotes.parse(data, fileName: name)
        }
        return ReleaseNotesLibrary(notes: parsed)
    }

    public func notes(for version: String) -> ReleaseNotes? { notes[version] }

    /// The versions that have notes, newest first.
    public var versions: [String] {
        notes.keys.compactMap { key in SemanticVersion(key).map { (key, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The versions with notes after `seen` and before `current`, newest first: what a person skipped.
    public func skipped(after seen: String, before current: String) -> [String] {
        guard let low = SemanticVersion(seen), let high = SemanticVersion(current) else { return [] }
        return versions.filter { key in
            guard let version = SemanticVersion(key) else { return false }
            return version > low && version < high
        }
    }
}
