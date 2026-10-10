import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// The system save and open panels, for keymap files.
@MainActor
enum FilePanels {
    /// Where to save a JSON file, or `nil` if the user cancelled.
    static func saveURL(suggestedName: String) -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    /// Any files to attach, in the order the panel returns them. Empty when the user cancelled.
    static func attachmentURLs() -> [URL] {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
        #else
        return []
        #endif
    }

    /// A JSON file to open, or `nil` if the user cancelled.
    static func openURL() -> URL? {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }
}
