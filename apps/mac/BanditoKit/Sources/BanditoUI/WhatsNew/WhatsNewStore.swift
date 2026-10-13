import BanditoKit
import BanditoL10n
import Foundation

/// What the sheet needs from the outside: this app's version, the version it was last shown at, and the notes folder.
enum WhatsNewStore {
    static let lastSeenKey = "whatsNew.lastSeenVersion"

    /// The version of this app (`CFBundleShortVersionString`); nil in a test host without one.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func lastSeen(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: lastSeenKey)
    }

    static func remember(_ version: String, _ defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: lastSeenKey) != version else { return }
        defaults.set(version, forKey: lastSeenKey)
    }

    /// The app's languages in order, as the bundle resolved them (the interface language first).
    static var preferredLanguages: [String] { L10n.bundle.preferredLocalizations }
}

/// Reads the notes folder once, off the main thread, and keeps the result for the sheet.
actor WhatsNewLibraryStore {
    static let shared = WhatsNewLibraryStore()
    private var cached: ReleaseNotesLibrary?

    func library() -> ReleaseNotesLibrary {
        if let cached { return cached }
        let loaded = ReleaseNotesLibrary.load(from: ReleaseNotesLibrary.bundledFolder())
        cached = loaded
        return loaded
    }
}
