import BanditoKit
import Foundation

/// One piece of the path trail: a folder button, or a menu that holds the folders folded away.
enum CrumbTrailItem: Equatable {
    /// The segment at this index of the trail.
    case crumb(Int)
    /// The folders at these indices, folded into a `…` menu.
    case overflow([Int])
}

/// The path trail in three widths, from the full trail to the narrowest. The toolbar shows the first one that
/// fits (`ViewThatFits`), so a long path folds from the middle and keeps its start and its end.
enum CrumbTrail {
    /// Three layouts for a trail of `count` segments: full, middle folded, and only the last segment with the
    /// rest in a menu. A trail of up to three segments does not fold until the last layout.
    static func layouts(count: Int) -> [[CrumbTrailItem]] {
        guard count > 0 else { return [[], [], []] }
        let full = (0..<count).map { CrumbTrailItem.crumb($0) }
        guard count > 3 else { return [full, full, [.crumb(count - 1)]] }
        let middle: [CrumbTrailItem] = [
            .crumb(0), .overflow(Array(1..<(count - 2))), .crumb(count - 2), .crumb(count - 1),
        ]
        let narrowest: [CrumbTrailItem] = [.overflow(Array(0..<(count - 1))), .crumb(count - 1)]
        return [full, middle, narrowest]
    }
}

/// Which columns the list shows. Columns that have nothing to show are left out, not drawn with dashes.
enum FileColumns {
    /// Minimum width of the date column. Grows with its content.
    static let changedMinWidth: CGFloat = 120
    /// Minimum width of the size column. Grows with its content.
    static let sizeMinWidth: CGFloat = 72

    /// The size column shows when some entry is a file. Folders have no size, so a folder-only list has none.
    static func showsSize(_ entries: [FsEntry]) -> Bool {
        entries.contains { $0.kind == .file }
    }
}

/// Widths of the Files browser at which parts of it change. The window is at least 900 × 600.
enum FileBrowserLayout {
    /// The window from this width on keeps the details panel beside the list. Narrower, the panel opens over it.
    static let dockedPanelMinWindowWidth: CGFloat = 1180
    /// The tallest preview of a file (text or picture) in the details panel.
    static let previewMaxHeight: CGFloat = 260

    static func isPanelDocked(windowWidth: CGFloat) -> Bool {
        windowWidth >= dockedPanelMinWindowWidth
    }

    /// Whether the details panel is on screen: beside the list when docked (`previewVisible`), over it otherwise
    /// (`overlayOpen`).
    static func panelShown(docked: Bool, previewVisible: Bool, overlayOpen: Bool) -> Bool {
        docked ? previewVisible : overlayOpen
    }

    /// The flags after the panel's close button: the one that shows the panel in the mode on screen goes off; the
    /// other mode's flag is kept as it was.
    static func closed(docked: Bool, previewVisible: Bool, overlayOpen: Bool) -> (previewVisible: Bool, overlayOpen: Bool) {
        docked ? (false, overlayOpen) : (previewVisible, false)
    }
}
