import AppKit
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoDesign
@testable import BanditoL10n
@testable import BanditoUI

/// Pictures of the "What's new" sheet for review: dark Russian, light English, Japanese, and German (the longest words)
/// with an earlier version folded under the current one. Written to `$BANDITO_SNAPSHOTS` (see `SnapshotSupport`).
/// The window is borderless, off every screen, transparent and never shown; the picture comes from `cacheDisplay`.
@MainActor
@Suite(.serialized) struct WhatsNewSnapshots {
    static func notes(_ version: String) throws -> ReleaseNotes {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appending(path: "release-notes/0.1.15.json"))
        let base = try ReleaseNotes.parse(data, fileName: "0.1.15.json")
        guard version != base.version else { return base }
        // An earlier version for the folded list: the same lines under another number.
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"0.1.15\"", with: "\"\(version)\"")
        return try ReleaseNotes.parse(Data(text.utf8), fileName: "\(version).json")
    }

    @Test(.language("ru")) func darkRussian() throws {
        _ = try render("whatsnew-dark-ru", dark: true, languages: ["ru"])
    }

    @Test(.language("en")) func lightEnglish() throws {
        _ = try render("whatsnew-light-en", dark: false, languages: ["en"])
    }

    @Test(.language("ja")) func darkJapanese() throws {
        _ = try render("whatsnew-dark-ja", dark: true, languages: ["ja"])
    }

    @Test(.language("ja")) func lightJapanese() throws {
        _ = try render("whatsnew-light-ja", dark: false, languages: ["ja"])
    }

    @Test(.language("de")) func darkGermanWithEarlierVersions() throws {
        _ = try render("whatsnew-dark-de-older", dark: true, languages: ["de"], older: ["0.1.14", "0.1.13"])
    }

    @Test(.language("en")) func noNotesForTheVersion() throws {
        _ = try render("whatsnew-dark-en-empty", dark: true, languages: ["en"], empty: true)
    }

    private func render(
        _ name: String, dark: Bool, languages: [String], older: [String] = [], empty: Bool = false
    ) throws -> URL {
        _ = BanditoFont.registerBundledFonts()
        let size = CGSize(width: WhatsNewContent.width, height: WhatsNewContent.height)
        let content = WhatsNewContent(
            notes: empty ? nil : try Self.notes("0.1.15"), version: "0.1.15",
            older: try older.map { try Self.notes($0) }, preferredLanguages: languages, still: true)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // The raccoon is a layer view: show its finished figure.
        if let raccoon = Self.findRaccoon(in: hosting), let lights = raccoon.layer as? RaccoonLightsLayer {
            lights.layoutIfNeeded()
            lights.show(at: 3)
        }
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds), "a bitmap for \(name)")
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        let png = try #require(rep.representation(using: .png, properties: [:]), "a PNG for \(name)")
        let url = SnapshotSupport.outDir.appending(path: "\(name).png")
        try png.write(to: url)
        return url
    }

    private static func findRaccoon(in view: NSView) -> RaccoonLightsNSView? {
        if let raccoon = view as? RaccoonLightsNSView { return raccoon }
        for child in view.subviews {
            if let found = findRaccoon(in: child) { return found }
        }
        return nil
    }
}
