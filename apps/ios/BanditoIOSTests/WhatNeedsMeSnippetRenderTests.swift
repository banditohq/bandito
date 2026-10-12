import SwiftUI
import Testing
import UIKit

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito
@testable import BanditoL10n

/// The snippet of "What needs me" drawn with `ImageRenderer`: it renders, and a PNG goes to the test host's
/// `snippet-previews` folder (the app's container), to look at in dark and light, Russian and English.
@MainActor
@Suite struct WhatNeedsMeSnippetRenderTests {
    private func render(_ file: String, dark: Bool, language: String, snapshot: WidgetSnapshot?) throws {
        try L10n.withLanguageForTests(language) {
            let view = WhatNeedsMeSnippet(snapshot: snapshot)
                .frame(width: 230)
                .background(Color.Bandito.bg)
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            let data = try #require(image.pngData())
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-previews", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(file).png"))
            #expect(image.size.width > 0)
        }
    }

    @Test func theSnippetRendersInEachTheme() throws {
        let watch = WidgetSnapshot.Agent(server: "S1", id: "watch", name: "Watch", status: .needsYou, mood: .needsYou)
        let forge = WidgetSnapshot.Agent(server: "S1", id: "forge", name: "Forge", status: .needsYou, mood: .needsYou)
        let waiting = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), pending: 2,
            agents: [watch, forge], waiting: [watch, forge], waitingCount: 2)
        try render("s8-whatneedsme-dark-ru", dark: true, language: "ru", snapshot: waiting)
        try render("s8-whatneedsme-light-en", dark: false, language: "en", snapshot: waiting)
        try render("s8-whatneedsme-quiet-ru", dark: true, language: "ru", snapshot: nil)
    }
}
