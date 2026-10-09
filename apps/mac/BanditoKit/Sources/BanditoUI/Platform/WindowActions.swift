#if os(macOS)
import AppKit

/// Window-level actions that SwiftUI has no call for: show the main window, open Settings.
@MainActor
enum WindowActions {
    static func showMainWindow() {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && !$0.isMiniaturized }?.makeKeyAndOrderFront(nil)
    }

    /// Opens the Settings scene, the way the standard ⌘, item does.
    static func showSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
#else
enum WindowActions {
    @MainActor static func showMainWindow() {}
    @MainActor static func showSettings() {}
}
#endif
