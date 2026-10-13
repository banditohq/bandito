import Foundation
import Testing

@testable import BanditoKit

/// The "What's new" notes: parsing, the rules every file obeys (the same ones `scripts/check_release_notes.py` holds in
/// CI), the language shown first, and when the sheet appears after an update.
@Suite struct ReleaseNotesTests {
    static let languages = ReleaseNotes.languages

    /// A valid file's JSON with `items` items; `edit` may break it.
    static func json(
        version: String = "0.1.15", date: String = "2026-10-13", items: Int = 3,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> Data {
        func words(_ prefix: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: languages.map { ($0, "\(prefix) \($0)") })
        }
        var doc: [String: Any] = [
            "version": version, "date": date,
            "items": (0..<items).map { ["icon": "sparkles", "title": words("T\($0)"), "text": words("X\($0)")] as [String: Any] },
        ]
        edit(&doc)
        return try JSONSerialization.data(withJSONObject: doc)
    }

    static func notes(_ version: String, items: Int = 3) throws -> ReleaseNotes {
        try ReleaseNotes.parse(try json(version: version, items: items), fileName: "\(version).json")
    }

    static func library(_ versions: [String]) throws -> ReleaseNotesLibrary {
        ReleaseNotesLibrary(notes: try versions.map { try notes($0) })
    }

    // MARK: files

    @Test func theNotesOfTheRepositoryAreAllValid() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let folder = root.appending(path: "release-notes")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        #expect(names.contains("0.1.15.json"))
        for name in names {
            let data = try Data(contentsOf: folder.appending(path: name))
            let parsed = try ReleaseNotes.parse(data, fileName: name)
            #expect(parsed.version + ".json" == name)
        }
        let loaded = ReleaseNotesLibrary.load(from: folder)
        #expect(loaded.notes.count == names.count, "the loader reads every valid file")
    }

    @Test func aValidFileParses() throws {
        let parsed = try Self.notes("0.1.15", items: 4)
        #expect(parsed.items.count == 4)
        #expect(parsed.lines(language: "ru")[1].title == "T1 ru")
    }

    @Test func brokenFilesAreRefused() throws {
        func refused(_ data: Data, fileName: String? = nil) -> Bool {
            (try? ReleaseNotes.parse(data, fileName: fileName)) == nil
        }
        #expect(refused(Data("not json".utf8)))
        #expect(refused(try Self.json(items: 2)), "fewer than three items")
        #expect(refused(try Self.json(items: 7)), "more than six items")
        #expect(refused(try Self.json(version: "0.1")), "not X.Y.Z")
        #expect(refused(try Self.json(date: "2026-02-30")), "not a real date")
        #expect(refused(try Self.json(date: "13.10.2026")))
        #expect(refused(try Self.json(), fileName: "0.1.16.json"), "the name must match the version")
        #expect(refused(try Self.json { doc in
            var items = doc["items"] as! [[String: Any]]
            var title = items[0]["title"] as! [String: String]
            title["ja"] = nil
            items[0]["title"] = title
            doc["items"] = items
        }), "a language is missing")
        #expect(refused(try Self.json { doc in
            var items = doc["items"] as! [[String: Any]]
            var text = items[1]["text"] as! [String: String]
            text["de"] = "   "
            items[1]["text"] = text
            doc["items"] = items
        }), "a blank text")
        #expect(refused(try Self.json { doc in
            var items = doc["items"] as! [[String: Any]]
            var text = items[1]["text"] as! [String: String]
            text["it"] = "ciao"
            items[1]["text"] = text
            doc["items"] = items
        }), "a language the app does not have")
        #expect(refused(try Self.json { doc in
            var items = doc["items"] as! [[String: Any]]
            items[0]["icon"] = ""
            doc["items"] = items
        }), "no symbol")
    }

    @Test func theLibraryLeavesBrokenFilesOut() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.json(version: "0.1.1").write(to: folder.appending(path: "0.1.1.json"))
        try Self.json(items: 1).write(to: folder.appending(path: "0.1.2.json"))
        try Data("{".utf8).write(to: folder.appending(path: "0.1.3.json"))
        try Data("x".utf8).write(to: folder.appending(path: "README.txt"))
        #expect(ReleaseNotesLibrary.load(from: folder).versions == ["0.1.1"])
        #expect(ReleaseNotesLibrary.load(from: nil).notes.isEmpty)
        #expect(ReleaseNotesLibrary.load(from: folder.appending(path: "nope")).notes.isEmpty)
    }

    // MARK: language

    @Test func theNotesOpenInTheAppLanguageOrEnglish() throws {
        let parsed = try Self.notes("0.1.15")
        #expect(parsed.defaultLanguage(preferred: ["ru", "en"]) == "ru")
        #expect(parsed.defaultLanguage(preferred: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(parsed.defaultLanguage(preferred: ["pt-PT"]) == "pt-BR")
        #expect(parsed.defaultLanguage(preferred: ["de-AT"]) == "de")
        #expect(parsed.defaultLanguage(preferred: ["it", "nl"]) == "en", "a language the app does not ship")
        #expect(parsed.defaultLanguage(preferred: []) == "en")
        #expect(parsed.defaultLanguage(preferred: ["zh-Hant"]) == "en", "traditional Chinese is not Simplified")
    }

    @Test func aLanguageMissingFromTheNotesFallsBackToEnglishPerField() throws {
        let raw = try Self.json { doc in
            var items = doc["items"] as! [[String: Any]]
            var title = items[0]["title"] as! [String: String]
            title["ko"] = nil
            items[0]["title"] = title
            doc["items"] = items
        }
        // Decoded without the check: a file like this cannot ship, but a reader must not crash on one.
        let decoded = try JSONDecoder().decode(ReleaseNotes.self, from: raw)
        #expect(decoded.lines(language: "ko")[0].title == "T0 en")
        #expect(decoded.lines(language: "ko")[1].title == "T1 ko")
        #expect(!decoded.hasLanguage("ko"))
        #expect(decoded.defaultLanguage(preferred: ["ko"]) == "en")
        #expect(decoded.lines(language: "xx")[2].text == "X2 en")
    }

    @Test func theDateIsReadAsACalendarDay() {
        #expect(ReleaseNotes.parseDate("2026-10-13") != nil)
        #expect(ReleaseNotes.parseDate("2026-13-01") == nil)
        #expect(ReleaseNotes.parseDate("2026-1-01") == nil)
        #expect(ReleaseNotes.parseDate("") == nil)
    }

    // MARK: when the sheet appears

    private func decide(
        current: String = "0.1.15", seen: String?, versions: [String] = ["0.1.15"], doneAtLaunch: Bool = true,
        introduction: Bool = false, dialog: Bool = false
    ) throws -> WhatsNewRules.Decision {
        WhatsNewRules.decide(
            current: current, lastSeen: seen, library: try Self.library(versions), wasDoneAtLaunch: doneAtLaunch,
            introductionActive: introduction, otherDialogOpen: dialog)
    }

    @Test func anUpdateShowsTheCurrentVersion() throws {
        #expect(try decide(seen: "0.1.14") == .show(skipped: []))
    }

    @Test func theSameOrALaterVersionShowsNothing() throws {
        #expect(try decide(seen: "0.1.15") == .nothing)
        #expect(try decide(seen: "0.1.16") == .nothing, "after a downgrade")
    }

    @Test func aNewPersonSeesNothingButTheVersionIsRemembered() throws {
        #expect(try decide(seen: nil, doneAtLaunch: false) == .remember)
        #expect(try decide(seen: nil, doneAtLaunch: false, introduction: true) == .remember)
    }

    @Test func someoneWhoUpdatesFromBeforeTheFeatureSeesTheCurrentVersionOnly() throws {
        #expect(try decide(seen: nil, versions: ["0.1.14", "0.1.15"]) == .show(skipped: []))
    }

    @Test func skippedVersionsAreListedNewestFirstAndOnlyThoseWithNotes() throws {
        let versions = ["0.1.11", "0.1.13", "0.1.14", "0.1.15", "0.1.16"]
        #expect(try decide(seen: "0.1.12", versions: versions) == .show(skipped: ["0.1.14", "0.1.13"]))
        #expect(try decide(seen: "0.1.13", versions: versions) == .show(skipped: ["0.1.14"]))
        #expect(try decide(seen: "0.1.14", versions: versions) == .show(skipped: []))
    }

    @Test func aVersionWithoutNotesIsRememberedSilently() throws {
        #expect(try decide(current: "0.1.16", seen: "0.1.15", versions: ["0.1.15"]) == .remember)
    }

    @Test func nothingCoversTheIntroductionOrADialog() throws {
        #expect(try decide(seen: "0.1.14", introduction: true) == .wait)
        #expect(try decide(seen: "0.1.14", dialog: true) == .wait)
        #expect(try decide(seen: "0.1.14", introduction: true, dialog: true) == .wait)
        // Waiting remembers nothing: once the dialog is answered, the same call shows the sheet.
        #expect(try decide(seen: "0.1.14") == .show(skipped: []))
    }

    @Test func prereleasesAndBadValuesAreHandled() throws {
        #expect(try decide(current: "0.1.15", seen: "0.1.15-beta.2") == .show(skipped: []))
        #expect(try decide(current: "0.1.15-beta.1", seen: "0.1.14", versions: ["0.1.15-beta.1"]) == .show(skipped: []))
        #expect(try decide(current: "garbage", seen: "0.1.14") == .nothing)
        #expect(try decide(seen: "garbage") == .show(skipped: []), "an unreadable stored value counts as stored nothing")
    }
}
