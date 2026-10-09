import BanditoDesign
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

/// Renders the Files screens that have no server to fetch from, to PNG for review (see `SnapshotSupport`).
@MainActor
@Suite struct FileSnapshots {
    @Test func markdownPreview() throws {
        let view = MarkdownPage(source: MarkdownTests.sample)
            .frame(width: 700, height: 470, alignment: .topLeading)
            .background(
                LinearGradient(colors: [Color(hex: 0x1C1814), Color(hex: 0x171411)], startPoint: .top, endPoint: .bottom)
            )
            .background(Color.Bandito.bg)
        let url = try SnapshotSupport.render(view, "files-markdown-preview", size: CGSize(width: 700, height: 470))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
