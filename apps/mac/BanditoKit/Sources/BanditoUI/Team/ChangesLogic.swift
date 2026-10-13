import BanditoKit
import BanditoL10n
import Foundation

// The parts of the changes logic that need the views' types; the rest is in BanditoKit (`ChangesLogic.swift`).

/// Footer of the changes panel. Wide: one row (two quiet buttons, the hint, the main button). Narrow: the main
/// button on top, full width, and the two others side by side under it.
enum ChangesFooterLayout {
    /// Below this width the row does not fit with the longest translations and the hint.
    static let rowMinWidth: CGFloat = 680

    static func isStacked(width: CGFloat) -> Bool {
        width < rowMinWidth
    }
}

/// The icon of a changed file: the kind of the file, from its name, as the Files mode draws it.
enum ChangedFileKind {
    static func category(path: String) -> FileCategory {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return FileTypes.category(name: name, ext: URL(fileURLWithPath: name).pathExtension, kind: .file)
    }
}

/// What the window shows after a rollback: how many files came back, and the checkpoint that undoes it.
struct RollbackNotice: Identifiable {
    let id = UUID()
    let server: ServerModel
    let agentID: String
    let count: Int
    let undoCheckpointID: String
}
