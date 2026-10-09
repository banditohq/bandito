import Foundation
import Testing

@testable import BanditoKit

@Suite struct AppUpdatePreferencesTests {
    /// A throwaway defaults domain, so the tests never touch the app's real settings.
    static func freshDefaults() -> UserDefaults {
        let name = "bandito.tests.appupdate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func automaticChecksAreOnUnlessTurnedOff() {
        let defaults = Self.freshDefaults()
        #expect(AppUpdatePreferences.automaticChecks(in: defaults))
        defaults.set(false, forKey: AppUpdatePreferences.automaticChecksKey)
        #expect(!AppUpdatePreferences.automaticChecks(in: defaults))
    }

    @Test func channelIsStableUnlessBetaIsPicked() {
        let defaults = Self.freshDefaults()
        #expect(AppUpdatePreferences.channel(in: defaults) == .stable)
        defaults.set("beta", forKey: AppUpdatePreferences.channelKey)
        #expect(AppUpdatePreferences.channel(in: defaults) == .beta)
        defaults.set("nightly", forKey: AppUpdatePreferences.channelKey)
        #expect(AppUpdatePreferences.channel(in: defaults) == .stable)
    }

    @Test func sparkleSharesTheAutomaticChecksKey() {
        // Sparkle reads this key from UserDefaults; the switch in Settings must write the same one.
        #expect(AppUpdatePreferences.automaticChecksKey == "SUEnableAutomaticChecks")
    }
}
