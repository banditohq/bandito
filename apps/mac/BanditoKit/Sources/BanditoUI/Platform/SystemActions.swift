import Foundation

#if os(macOS)
import AppKit
#endif

/// Pasteboard and browser access for the sign-in screens. Lives here, not in the models, so the models stay testable.
public enum SystemActions {
    /// Puts `text` on the general pasteboard as plain text.
    public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Opens `url` in the default browser.
    public static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}
