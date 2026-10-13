#if os(macOS) && DEBUG
import AppKit
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// Pictures of every step of the first-run flow for review: dark in Russian and light in English, drawn from the real
/// flow on an in-memory demo daemon. Written to `$BANDITO_SNAPSHOTS` as `onb2-<step>-<dark|light>-<language>.png`
/// (see `SnapshotSupport`). The window is borderless, off every screen, transparent, and never shown.
extension ScreenWorkSuites {
    @MainActor @Suite(.serialized) struct OnboardingSnapshots {
        private func shoot(
            _ step: OnboardingStep, card: Int = 0, name: String, dark: Bool, language: String, hired: Bool = false
        ) async throws {
            let world = OnboardingWorld(step: step, card: card, dark: dark)
            await world.prepare(readServerSteps: step.needsServer)
            if hired { try await world.hireForge() }
            // From here nothing waits: the flow is drawn in this test's own turn.
            world.show()
            let url = try world.png("onb2-\(name)-\(dark ? "dark" : "light")-\(language)")
            #expect(FileManager.default.fileExists(atPath: url.path))
            await world.stop()
        }

        @Test(.language("ru")) func welcomeDarkRussian() async throws {
            try await shoot(.welcome, name: "1-welcome", dark: true, language: "ru")
        }
        @Test(.language("en")) func welcomeLightEnglish() async throws {
            try await shoot(.welcome, name: "1-welcome", dark: false, language: "en")
        }

        @Test(.language("ru")) func featuresDarkRussian() async throws {
            for card in 0..<OnboardingRules.cardCount {
                try await shoot(.features, card: card, name: "2-features-\(card + 1)", dark: true, language: "ru")
            }
        }
        @Test(.language("en")) func featuresLightEnglish() async throws {
            for card in 0..<OnboardingRules.cardCount {
                try await shoot(.features, card: card, name: "2-features-\(card + 1)", dark: false, language: "en")
            }
        }

        @Test(.language("ru")) func serverDarkRussian() async throws {
            try await shoot(.server, name: "4-server", dark: true, language: "ru")
        }
        @Test(.language("en")) func serverLightEnglish() async throws {
            try await shoot(.server, name: "4-server", dark: false, language: "en")
        }

        @Test(.language("ru")) func runtimesDarkRussian() async throws {
            try await shoot(.runtimes, name: "5-runtimes", dark: true, language: "ru")
        }
        @Test(.language("en")) func runtimesLightEnglish() async throws {
            try await shoot(.runtimes, name: "5-runtimes", dark: false, language: "en")
        }

        @Test(.language("ru")) func teamDarkRussian() async throws {
            try await shoot(.team, name: "6-team", dark: true, language: "ru")
        }
        @Test(.language("en")) func teamLightEnglish() async throws {
            try await shoot(.team, name: "6-team", dark: false, language: "en")
        }
        @Test(.language("de")) func teamDarkGerman() async throws {
            try await shoot(.team, name: "6-team", dark: true, language: "de")
        }

        @Test(.language("ru")) func taskDarkRussian() async throws {
            try await shoot(.task, name: "7-task", dark: true, language: "ru", hired: true)
        }
        @Test(.language("en")) func taskLightEnglish() async throws {
            try await shoot(.task, name: "7-task", dark: false, language: "en", hired: true)
        }
    }
}
#endif
