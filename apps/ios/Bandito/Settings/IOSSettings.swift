import Foundation
import Observation
import SwiftUI

/// The appearance the person picked. System follows the iPhone; the other two apply to Bandito only.
enum AppTheme: String, CaseIterable, Sendable {
    case system
    case dark
    case light

    /// The scheme forced on the app, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// Whether Bandito reduces motion: follow the system's Reduce Motion setting, or always.
enum MotionPreference: String, CaseIterable, Sendable {
    case system
    case always

    func reducesMotion(systemSetting: Bool) -> Bool {
        switch self {
        case .system: systemSetting
        case .always: true
        }
    }
}

/// How long Bandito may stay in the background before the Face ID lock asks again.
enum LockTimeout: Int, CaseIterable, Sendable {
    case oneMinute = 1
    case fiveMinutes = 5
    case fifteenMinutes = 15

    var minutes: Int { rawValue }

    var interval: TimeInterval { TimeInterval(rawValue * 60) }
}

/// The settings of the iPhone app, kept in UserDefaults under keys that start with `ios.`. Nothing here leaves the
/// phone; the servers and their tokens are in `ServerSession`.
@MainActor
@Observable
final class IOSSettings {
    enum Key {
        static let faceIDLock = "ios.security.faceIDLock"
        static let lockTimeout = "ios.security.lockTimeoutMinutes"
        static let riskyNeedsFaceID = "ios.security.riskyNeedsFaceID"
        static let notifyApprovals = "ios.notifications.approvals"
        static let notifyAnswers = "ios.notifications.answers"
        static let notifyErrors = "ios.notifications.errors"
        static let liveActivities = "ios.notifications.liveActivities"
        static let theme = "ios.appearance.theme"
        static let motion = "ios.appearance.motion"
    }

    private let defaults: UserDefaults

    var faceIDLock: Bool {
        didSet { defaults.set(faceIDLock, forKey: Key.faceIDLock) }
    }

    var lockTimeout: LockTimeout {
        didSet { defaults.set(lockTimeout.minutes, forKey: Key.lockTimeout) }
    }

    var riskyNeedsFaceID: Bool {
        didSet { defaults.set(riskyNeedsFaceID, forKey: Key.riskyNeedsFaceID) }
    }

    var notifyApprovals: Bool {
        didSet { defaults.set(notifyApprovals, forKey: Key.notifyApprovals) }
    }

    var notifyAnswers: Bool {
        didSet { defaults.set(notifyAnswers, forKey: Key.notifyAnswers) }
    }

    var notifyErrors: Bool {
        didSet { defaults.set(notifyErrors, forKey: Key.notifyErrors) }
    }

    /// The Live Activity of a long turn on the lock screen and in the Dynamic Island (on unless the person turns it off).
    var liveActivities: Bool {
        didSet { defaults.set(liveActivities, forKey: Key.liveActivities) }
    }

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    var motion: MotionPreference {
        didSet { defaults.set(motion.rawValue, forKey: Key.motion) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        faceIDLock = defaults.object(forKey: Key.faceIDLock) as? Bool ?? false
        lockTimeout = LockTimeout(rawValue: defaults.object(forKey: Key.lockTimeout) as? Int ?? 1) ?? .oneMinute
        riskyNeedsFaceID = defaults.object(forKey: Key.riskyNeedsFaceID) as? Bool ?? true
        notifyApprovals = defaults.object(forKey: Key.notifyApprovals) as? Bool ?? true
        notifyAnswers = defaults.object(forKey: Key.notifyAnswers) as? Bool ?? true
        notifyErrors = defaults.object(forKey: Key.notifyErrors) as? Bool ?? true
        liveActivities = defaults.object(forKey: Key.liveActivities) as? Bool ?? true
        theme = defaults.string(forKey: Key.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        motion = defaults.string(forKey: Key.motion).flatMap(MotionPreference.init(rawValue:)) ?? .system
    }
}
