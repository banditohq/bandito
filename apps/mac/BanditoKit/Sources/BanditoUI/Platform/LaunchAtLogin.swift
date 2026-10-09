import Foundation
#if os(macOS)
import ServiceManagement
#endif

/// Whether Bandito starts when the user logs in (macOS 13+ login item).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        #if os(macOS)
        SMAppService.mainApp.status == .enabled
        #else
        false
        #endif
    }

    static func set(_ on: Bool) throws {
        #if os(macOS)
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        #endif
    }
}
