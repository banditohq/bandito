import Foundation

#if os(macOS)
import AppKit
#endif

/// Whether a tool that reads the screen to the person (VoiceOver, Switch Control) is on. Things that only such a tool
/// uses are built only then.
enum AccessibilityState {
    @MainActor
    static var assistiveToolOn: Bool {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        return workspace.isVoiceOverEnabled || workspace.isSwitchControlEnabled
        #else
        true
        #endif
    }
}
