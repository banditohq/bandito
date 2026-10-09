#if os(macOS)
import AppKit

/// Window-level actions that SwiftUI has no call for: show the main window, open Settings.
@MainActor
enum WindowActions {
    static func showMainWindow() {
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && !$0.isMiniaturized }?.makeKeyAndOrderFront(nil)
    }

    /// SwiftUI's own way to open the Settings scene, handed over by the root view (`SettingsOpenerBridge`).
    static var openSettingsAction: (() -> Void)?

    /// Opens the Settings scene, the way the standard ⌘, item does.
    static func showSettings() {
        NSApp.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    /// Closes the key window (⇧⌘W). ⌘W is the focused terminal's close in the Terminals mode.
    static func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }
}

import SwiftUI

/// Gives `WindowActions` the `openSettings` action of the environment. Put it once in the main window.
struct SettingsOpenerBridge: ViewModifier {
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear { WindowActions.openSettingsAction = { openSettings() } }
    }
}
#else
enum WindowActions {
    @MainActor static func showMainWindow() {}
    @MainActor static func showSettings() {}
    @MainActor static func closeKeyWindow() {}
}
#endif
