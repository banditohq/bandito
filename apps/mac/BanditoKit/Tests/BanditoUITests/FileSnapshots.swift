import BanditoDesign
import Foundation
import AppKit
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

    // Widths the toolbar must fit: the browser beside the 296 pt sidebar in a 900 pt window (604), the same in
    // a 1056 pt window (760), the usual 1440 pt window with the details panel docked (824), and a wide 1100 pt.

    /// The toolbar's ideal size in a given width is its chosen layout: it must not be wider than the width, or
    /// the items would run over the edge of the window.
    @Test(arguments: [604.0, 760.0, 824.0, 1100.0])
    func toolbarFitsItsWidth(_ width: Double) {
        let controller = NSHostingController(rootView: Self.toolbar(path: Self.deepPath))
        let size = controller.sizeThatFits(in: CGSize(width: CGFloat(width), height: 52))
        #expect(size.width <= CGFloat(width), "toolbar needs \(size.width) pt in \(width) pt")
        #expect(size.height == 52)
    }

    @Test(arguments: [604.0, 760.0, 824.0, 1100.0])
    func toolbarRenders(_ width: Double) throws {
        let url = try SnapshotSupport.render(
            Self.toolbar(path: Self.deepPath).frame(width: CGFloat(width), alignment: .leading),
            "files-toolbar-\(Int(width))", size: CGSize(width: CGFloat(width), height: 52))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    static let deepPath = "/Users/dev/work/platform/apps/mac/BanditoKit/Sources/BanditoUI"

    private static func toolbar(path: String) -> some View {
        FilesToolbar(
            model: FolderModel(),
            crumbs: FilePath.crumbs(for: path, home: "/Users/dev"),
            current: path,
            canGoBack: true,
            canGoForward: false,
            showsTerminal: true,
            detailsShown: true,
            onBack: {},
            onForward: {},
            onCrumb: { _ in },
            onCopyPath: { _ in },
            onSearchChange: {},
            onTerminal: {},
            onCreate: { _ in },
            onToggleDetails: {}
        )
        .background(Color.Bandito.bg)
    }
}
