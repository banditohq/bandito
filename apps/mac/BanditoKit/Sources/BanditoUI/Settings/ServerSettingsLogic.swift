import BanditoKit
import Foundation

/// The ranges of the server settings the app offers. The daemon checks the same ranges (`daemon/src/server_settings.rs`);
/// the controls stay inside them, and `ServerSettingChange.patch` refuses a value outside them, so a value the daemon
/// would refuse is never sent.
enum ServerSettingLimits {
    static let screenIdleMinutes = 5...240
    static let screenIdleStep = 5
    /// `max_running_agents`: 0 means no limit, otherwise 1 to 50. Together that is exactly 0 to 50.
    static let maxRunningAgents = 0...50
    static let backupEveryHours = [6, 12, 24, 48, 168]
    static let backupKeep = 3...60
}

/// One change a control makes. It becomes a `server.settings_set` patch with that one field.
enum ServerSettingChange: Equatable {
    case autoUpdate(AutoUpdateMode)
    case screenIdleMinutes(Int)
    case maxRunningAgents(Int)
    case backupEveryHours(Int)
    case backupKeep(Int)
    case defaultApprovalMode(ApprovalMode)
    case phoneAccess(PhoneAccessMode)

    /// The patch with this one field, or nil when the value is outside the daemon's range (nothing is sent then).
    var patch: ServerSettingsPatch? {
        switch self {
        case .autoUpdate(let mode):
            ServerSettingsPatch(autoUpdate: mode)
        case .screenIdleMinutes(let minutes):
            ServerSettingLimits.screenIdleMinutes.contains(minutes) ? ServerSettingsPatch(screenIdleMinutes: minutes) : nil
        case .maxRunningAgents(let count):
            ServerSettingLimits.maxRunningAgents.contains(count) ? ServerSettingsPatch(maxRunningAgents: count) : nil
        case .backupEveryHours(let hours):
            ServerSettingLimits.backupEveryHours.contains(hours) ? ServerSettingsPatch(backupEveryHours: hours) : nil
        case .backupKeep(let count):
            ServerSettingLimits.backupKeep.contains(count) ? ServerSettingsPatch(backupKeep: count) : nil
        case .defaultApprovalMode(let mode):
            ServerSettingsPatch(defaultApprovalMode: mode)
        case .phoneAccess(let mode):
            ServerSettingsPatch(phoneAccess: mode)
        }
    }

    /// The values after this change, as the page shows them while the daemon answers.
    func applied(to current: ServerSettingValues) -> ServerSettingValues {
        var next = current
        switch self {
        case .autoUpdate(let mode): next.autoUpdate = mode
        case .screenIdleMinutes(let minutes): next.screenIdleMinutes = minutes
        case .maxRunningAgents(let count): next.maxRunningAgents = count
        case .backupEveryHours(let hours): next.backupEveryHours = hours
        case .backupKeep(let count): next.backupKeep = count
        case .defaultApprovalMode(let mode): next.defaultApprovalMode = mode
        case .phoneAccess(let mode): next.phoneAccess = mode
        }
        return next
    }

    /// Whether the change moves the value away from `current`. A control that picks the value already set sends nothing.
    func differs(from current: ServerSettingValues) -> Bool {
        switch self {
        case .autoUpdate(let mode): mode != current.autoUpdate
        case .screenIdleMinutes(let minutes): minutes != current.screenIdleMinutes
        case .maxRunningAgents(let count): count != current.maxRunningAgents
        case .backupEveryHours(let hours): hours != current.backupEveryHours
        case .backupKeep(let count): count != current.backupKeep
        case .defaultApprovalMode(let mode): mode != current.defaultApprovalMode
        case .phoneAccess(let mode): mode != current.phoneAccess
        }
    }
}
