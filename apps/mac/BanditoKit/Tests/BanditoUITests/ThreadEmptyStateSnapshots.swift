import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import Testing

@testable import BanditoUI

/// The empty thread of a new agent, wide and narrow. The file name carries the language the strings came in, which is the
/// system's language (a run in another language needs the global `AppleLanguages` set for that run).
@MainActor
@Suite struct ThreadEmptyStateSnapshots {
    private var language: String { L10n.bundle.preferredLocalizations.first ?? "en" }

    private var agent: Agent {
        Agent(
            id: "a1", name: "Ada", role: "Ищет и проверяет факты в интернете", runtime: .claude, cwd: "/work",
            capabilities: ["terminal", "files", "browser", "team"])
    }

    @Test func theEmptyThreadWide() throws {
        let size = CGSize(width: 720, height: 560)
        let view = ThreadEmptyState(agent: agent, server: nil, onPick: { _ in })
            .background(Color.Bandito.bg)
        let url = try SnapshotSupport.render(view, "thread-empty-wide-\(language)", size: size)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theEmptyThreadNarrow() throws {
        let size = CGSize(width: 380, height: 620)
        let view = ThreadEmptyState(agent: agent, server: nil, onPick: { _ in })
            .background(Color.Bandito.bg)
        let url = try SnapshotSupport.render(view, "thread-empty-narrow-\(language)", size: size)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
