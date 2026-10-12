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

    /// Three agents wait for the person: the small widget names two and counts one more.
    private var team: WidgetSnapshot {
        let waiting = [agent("Forge", .needsYou, .needsYou), agent("Watch", .needsYou, .needsYou), agent("Scout", .needsYou, .needsYou)]
        return WidgetSnapshot(
            generatedAt: now, pending: 3,
            agents: waiting + [agent("Quill", .working, .working)],
            waiting: waiting)
    }

    private var quiet: WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, pending: 0, agents: [agent("Forge", .idle, .sleeping)])
    }

    /// Draws `content` at the given size and writes it as `file` (a PNG in the `widget-previews` folder). The small
    /// widget stands on its glow backdrop, as on the home screen; the others on the plain ground.
    private func render<V: View>(
        _ file: String, width: CGFloat, height: CGFloat, dark: Bool, language: String, glow: Bool = false, _ content: V
    ) throws {
        try L10n.withLanguageForTests(language) {
            let scheme: ColorScheme = dark ? .dark : .light
            let ground: AnyView = glow ? AnyView(WidgetBackdrop()) : AnyView(Color.Bandito.bg)
            let view = content
                .frame(width: width, height: height)
                .background(ground)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            let data = try #require(image.pngData())
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("widget-previews", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(file).png"))
            #expect(image.size.width == width)
        }
    }

    @Test func smallWidgetRendersTheWaitingAndTheQuietRaccoon() throws {
        try render("s7b-small-dark-ru", width: 170, height: 170, dark: true, language: "ru", glow: true, InboxWidgetView(snapshot: team, family: .systemSmall))
        try render("s7b-small-light-en", width: 170, height: 170, dark: false, language: "en", glow: true, InboxWidgetView(snapshot: team, family: .systemSmall))
        try render("s7b-small-empty", width: 170, height: 170, dark: true, language: "ru", glow: true, InboxWidgetView(snapshot: quiet, family: .systemSmall))
        try render("s7b-small-placeholder", width: 170, height: 170, dark: true, language: "en", glow: true, InboxWidgetView(snapshot: nil, family: .systemSmall))
    }

    @Test func lockScreenWidgetsRenderTheCountAndTheWorkingAgent() throws {
        try render("s7b-lock-circular-dark-en", width: 76, height: 76, dark: true, language: "en", InboxWidgetView(snapshot: team, family: .accessoryCircular))
        try render("s7b-lock-rectangular-dark-ru", width: 170, height: 76, dark: true, language: "ru", InboxWidgetView(snapshot: team, family: .accessoryRectangular))
        try render("s7b-lock-rectangular-light-en", width: 170, height: 76, dark: false, language: "en", InboxWidgetView(snapshot: quiet, family: .accessoryRectangular))
    }

    @Test func crewWidgetRendersUpToFourAgentsAndTheEmptyTeam() throws {
        try render("s7b-crew-medium-dark-ru", width: 364, height: 170, dark: true, language: "ru", CrewWidgetView(snapshot: team))
        try render("s7b-crew-medium-light-en", width: 364, height: 170, dark: false, language: "en", CrewWidgetView(snapshot: team))
        try render("s7b-crew-medium-empty-dark-en", width: 364, height: 170, dark: true, language: "en", CrewWidgetView(snapshot: WidgetSnapshot(generatedAt: now, pending: 0, agents: [])))
    }
}
