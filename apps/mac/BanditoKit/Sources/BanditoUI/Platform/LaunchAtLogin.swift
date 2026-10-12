import Foundation
#if os(macOS)
import ServiceManagement
#endif

/// Whether Bandito starts when the user logs in (macOS 13+ login item).
enum LaunchAtLogin {
    /// The status as last asked of the system. Asking is a call into the service manager (a few milliseconds), and the
    /// General section's `@State` asked it at every build of the section, not only when it was made.
    nonisolated(unsafe) private static var known: Bool?

    static var isEnabled: Bool {
        if let known { return known }
        let value = currentStatus()
        known = value
        return value
    }

    private static func currentStatus() -> Bool {
        #if os(macOS)
        SMAppService.mainApp.status == .enabled
        #else
        false
        #endif
    }

    static func set(_ on: Bool) throws {
        defer { known = currentStatus() }
        #if os(macOS)
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        #endif
    }
}
