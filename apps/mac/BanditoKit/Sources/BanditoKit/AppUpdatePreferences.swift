import Foundation

/// Settings of the Mac app's own updates (Sparkle 2), stored on this Mac. Settings → General writes them with
/// `@AppStorage` under these keys; the app target reads them to configure Sparkle (`AppUpdater`).
public enum AppUpdatePreferences {
    /// Sparkle's own key for automatic checks, so the switch and Sparkle read the same value.
    /// Without a stored value, the Info.plist default decides (on).
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    public static let channelKey = "updates.channel"

    /// The release channel. Stable is the default. Beta also gets the appcast items marked with the `beta` channel.
    public enum Channel: String, CaseIterable, Sendable {
        case stable
        case beta
    }

    /// Whether the app checks for updates on a schedule (once a day, Sparkle's default). On unless turned off.
    public static func automaticChecks(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticChecksKey) as? Bool ?? true
    }

    /// The channel the user picked. An unknown stored value means stable.
    public static func channel(in defaults: UserDefaults = .standard) -> Channel {
        defaults.string(forKey: channelKey).flatMap(Channel.init(rawValue:)) ?? .stable
    }
}
