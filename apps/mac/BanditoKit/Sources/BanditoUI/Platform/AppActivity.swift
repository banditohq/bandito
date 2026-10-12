import Foundation

#if os(macOS)
import AppKit
#endif

/// Whether Bandito is the app the person is looking at. Polling that only feeds a screen (host numbers, ports, the
/// browser's tab list) is skipped while it is not, so a window left in the background costs no requests and no redraws;
/// the next tick after the app comes back reads again.
@MainActor
enum AppActivity {
    static var isActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }
}
