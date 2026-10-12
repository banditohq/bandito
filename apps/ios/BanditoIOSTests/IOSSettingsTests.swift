import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The iPhone settings: their defaults, persistence under `ios.` keys, and the mappings the screens rely on.
@MainActor
@Suite struct IOSSettingsTests {
    /// A UserDefaults suite of its own, emptied first, so no test sees the app's values or another test's.
    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "dev.bandito.ios.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @Test func theSafeChoicesAreTheDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSettings(defaults: defaults)
        #expect(!settings.faceIDLock)
        #expect(settings.lockTimeout == .oneMinute)
        #expect(settings.riskyNeedsFaceID)
        #expect(settings.notifyApprovals && settings.notifyAnswers && settings.notifyErrors)
        #expect(settings.theme == .system)
        #expect(settings.motion == .system)
    }

    @Test func theChoicesSurviveARelaunch() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = IOSSettings(defaults: defaults)
        first.faceIDLock = true
        first.lockTimeout = .fifteenMinutes
        first.riskyNeedsFaceID = false
        first.notifyErrors = false
        first.theme = .dark
        first.motion = .always

        let second = IOSSettings(defaults: defaults)
        #expect(second.faceIDLock)
        #expect(second.lockTimeout == .fifteenMinutes)
        #expect(!second.riskyNeedsFaceID)
        #expect(!second.notifyErrors)
        #expect(second.notifyApprovals)
        #expect(second.theme == .dark)
        #expect(second.motion == .always)
    }

    @Test func everyStoredKeyIsUnderTheIosPrefix() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IOSSettings(defaults: defaults)
        settings.faceIDLock = true
        settings.lockTimeout = .fiveMinutes
        settings.theme = .light
        settings.motion = .always
        settings.notifyAnswers = false

        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(stored.count >= 5)
        #expect(stored.keys.allSatisfy { $0.hasPrefix("ios.") })
    }

    @Test func lockTimeoutsAreOneFiveAndFifteenMinutes() {
        #expect(LockTimeout.allCases.map(\.minutes) == [1, 5, 15])
        #expect(LockTimeout.fiveMinutes.interval == 300)
    }

    @Test func themeFollowsTheSystemUnlessForced() {
        #expect(AppTheme.system.colorScheme == nil)
        #expect(AppTheme.dark.colorScheme == .dark)
        #expect(AppTheme.light.colorScheme == .light)
    }

    @Test func motionFollowsTheSystemUnlessAlways() {
        #expect(!MotionPreference.system.reducesMotion(systemSetting: false))
        #expect(MotionPreference.system.reducesMotion(systemSetting: true))
        #expect(MotionPreference.always.reducesMotion(systemSetting: false))
    }

    @Test func theTabLaunchArgumentOpensThatTab() {
        #expect(AppTab.requested(in: ["Bandito", "-tab", "settings"]) == .settings)
        #expect(AppTab.requested(in: ["Bandito", "-demo"]) == .crew)
        #expect(AppTab.requested(in: ["Bandito", "-tab", "nope"]) == .crew)
        #expect(AppTab.requested(in: ["Bandito", "-tab"]) == .crew)
    }
}
