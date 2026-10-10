import AppKit
import BanditoL10n
import CoreGraphics
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The numbers of the avatar editor. Pure, so the layout rules are tested.
enum AvatarEditorLayout {
    /// The editor popover is 360 wide with 16 on each side.
    static let width: CGFloat = 360
    static let inset: CGFloat = 16
    static var contentWidth: CGFloat { width - 2 * inset }
    /// The square a picture is framed in. Small enough that the popover, anchored under the avatar, keeps its buttons on
    /// a 900-point screen.
    static let cropSide: CGFloat = 200

    static let emojiColumns = 8
    static let emojiCell: CGFloat = 36
    static let emojiSpacing: CGFloat = 4
    static let emojiMaxRows = 5

    /// The height of the emoji grid: all its rows up to `maxRows`, beyond that the grid scrolls. Zero without items.
    static func gridHeight(
        count: Int, columns: Int = emojiColumns, cell: CGFloat = emojiCell, spacing: CGFloat = emojiSpacing,
        maxRows: Int = emojiMaxRows
    ) -> CGFloat {
        guard count > 0, columns > 0 else { return 0 }
        let rows = min((count + columns - 1) / columns, max(maxRows, 1))
        return CGFloat(rows) * cell + CGFloat(rows - 1) * spacing
    }
}

/// The profile sheet's measures. The photo is framed inside the sheet, under the avatar, never in a popover that could
/// run past the sheet's edge, so the frame must fit the sheet's content width.
enum ProfileSheetLayout {
    static let width: CGFloat = 460
    static let padding: CGFloat = 24
    static let groupSpacing: CGFloat = 16
    static let avatarSize: CGFloat = 88
    static var contentWidth: CGFloat { width - 2 * padding }
    /// The square the photo is framed in: as wide as the content, but not larger than 280.
    static var cropSide: CGFloat { min(contentWidth, 280) }

    /// Whether a block of `blockWidth` fits the sheet's content area.
    static func fits(_ blockWidth: CGFloat) -> Bool { blockWidth <= contentWidth }
}

/// The state of the avatar editor that must outlive its popover. A popover closes when another window takes the focus,
/// and choosing a file opens one (the file panel): a `@State` of the editor view would be gone by the time the file
/// is read. The owner (the inspector, the new-agent sheet) keeps this model, shows the popover again when a file has
/// been read, and the editor opens on the picture tab with the file ready to frame.
@MainActor
@Observable
final class AvatarEditorModel {
    var tab: AvatarEditor.Tab = .face
    /// A picture read from disk and not yet saved.
    var framing: CGImage?
    var error: UserFacingMessage?
    /// Counts the pictures read so far. The owner watches it to show the editor again.
    private(set) var loadedCount = 0
    @ObservationIgnored private var generation = 0

    /// Opens the file panel. The panel does not block: the popover may close while it is up, and the result lands here.
    func chooseFile() {
        AvatarFilePanel.choose(message: L10n.Avatar.pickerMessage) { [weak self] url in
            if let url { self?.load(url) }
        }
    }

    /// Reads the file (off the main thread) and, when it is a picture, offers it for framing on the picture tab.
    func load(_ url: URL) {
        generation += 1
        let mine = generation
        Task {
            let image = await Task.detached(operation: { AvatarImageFile.load(url) }).value
            // A newer pick replaces this one; nothing stale is shown.
            guard mine == generation else { return }
            guard let image else {
                error = UserFacingMessage(text: L10n.Avatar.pictureUnreadable)
                return
            }
            error = nil
            framing = image
            tab = .picture
            loadedCount += 1
        }
    }

    /// Takes the first dropped file. Returns whether the drop carried one.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
            Task { @MainActor in
                guard let self else { return }
                if let url {
                    self.load(url)
                } else {
                    self.error = UserFacingMessage(text: L10n.Avatar.pictureUnreadable)
                }
            }
        }
        return true
    }

    /// Forgets a picture waiting to be framed (the framing was cancelled or saved, or the agent changed).
    func reset() {
        generation += 1
        framing = nil
        error = nil
    }
}

/// The system file panel for an image.
@MainActor
enum AvatarFilePanel {
    /// Shows the panel without blocking the caller; `completion` gets the chosen file, or nothing when cancelled.
    static func choose(message: String, completion: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            Task { @MainActor in completion(url) }
        }
    }
}
