import SwiftUI
import Testing
import UIKit
import WidgetKit

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito
@testable import BanditoL10n

/// The widgets' pictures, drawn with `ImageRenderer`: each one renders, and a PNG of it goes to the test host's
/// `widget-previews` folder (the app's container: `xcrun simctl get_app_container <udid> dev.bandito.ios data`), so the
/// small, medium and lock screen pictures can be looked at in dark and light, Russian and English.
@MainActor
@Suite struct WidgetRenderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func agent(_ name: String, _ status: WidgetStatus, _ mood: WidgetMood) -> WidgetSnapshot.Agent {
        WidgetSnapshot.Agent(server: "S1", id: name.lowercased(), name: name, status: status, mood: mood)
    }

    private var team: WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now, pending: 2,
            agents: [
                agent("Forge", .working, .working),
                agent("Watch", .needsYou, .needsYou),
                agent("Scout", .idle, .idle),
                agent("Quill", .error, .error),
            ])
    }

    private var quiet: WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, pending: 0, agents: [agent("Forge", .idle, .sleeping)])
    }

    private func render<V: View>(
        _ name: String, width: CGFloat, height: CGFloat, dark: Bool, language: String, _ content: V
    ) throws {
        try L10n.withLanguageForTests(language) {
            let scheme: ColorScheme = dark ? .dark : .light
            let view = content
                .frame(width: width, height: height)
                .background(Color.Bandito.bg)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            let data = try #require(image.pngData())
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-previews", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(language).png"))
            #expect(image.size.width == width)
        }
    }

    @Test func smallWidgetRendersWaitingCountAndTheQuietRaccoon() throws {
        try render("inbox-small", width: 170, height: 170, dark: true, language: "ru", InboxWidgetView(snapshot: team, family: .systemSmall))
        try render("inbox-small", width: 170, height: 170, dark: false, language: "en", InboxWidgetView(snapshot: quiet, family: .systemSmall))
        try render("inbox-small-placeholder", width: 170, height: 170, dark: true, language: "en", InboxWidgetView(snapshot: nil, family: .systemSmall))
    }

    @Test func lockScreenWidgetsRenderTheCountAndTheWorkingAgent() throws {
        try render("inbox-lock-circular", width: 76, height: 76, dark: true, language: "en", InboxWidgetView(snapshot: team, family: .accessoryCircular))
        try render("inbox-lock-rectangular", width: 170, height: 76, dark: true, language: "ru", InboxWidgetView(snapshot: team, family: .accessoryRectangular))
        try render("inbox-lock-rectangular", width: 170, height: 76, dark: false, language: "en", InboxWidgetView(snapshot: quiet, family: .accessoryRectangular))
    }

    @Test func crewWidgetRendersUpToFourAgentsAndTheEmptyTeam() throws {
        try render("crew-medium", width: 364, height: 170, dark: true, language: "ru", CrewWidgetView(snapshot: team))
        try render("crew-medium", width: 364, height: 170, dark: false, language: "en", CrewWidgetView(snapshot: team))
        try render("crew-medium-empty", width: 364, height: 170, dark: true, language: "en", CrewWidgetView(snapshot: WidgetSnapshot(generatedAt: now, pending: 0, agents: [])))
    }
}
