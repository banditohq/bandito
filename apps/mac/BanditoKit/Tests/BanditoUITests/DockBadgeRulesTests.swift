import Foundation
import Testing

@testable import BanditoUI

/// The Dock icon's badge: the sum of the connected servers' unread counts, its text, and the switch.
@Suite struct DockBadgeRulesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "test.dock.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theTotalIsTheSumOfTheCountsAndNothingBelowZero() {
        #expect(DockBadgeRules.total([2, 0, 5]) == 7)
        #expect(DockBadgeRules.total([]) == 0)
        #expect(DockBadgeRules.total([-3, 4]) == 4)
    }

    @Test func noBadgeWhenNothingIsUnreadOrTheSwitchIsOff() {
        #expect(DockBadgeRules.label(total: 0, enabled: true) == nil)
        #expect(DockBadgeRules.label(total: 5, enabled: false) == nil)
        #expect(DockBadgeRules.label(total: 0, enabled: false) == nil)
    }

    @Test func theBadgeShowsTheTotalUpTo99AndAPlusAbove() {
        #expect(DockBadgeRules.label(total: 4, enabled: true) == "4")
        #expect(DockBadgeRules.label(total: 99, enabled: true) == "99")
        #expect(DockBadgeRules.label(total: 100, enabled: true) == "99+")
        #expect(DockBadgeRules.label(total: 2400, enabled: true) == "99+")
    }

    @Test func theSwitchIsOnByDefaultAndKeepsItsValue() {
        let defaults = freshDefaults()
        #expect(DockBadgeRules.isOn(defaults))
        defaults.set(false, forKey: DockBadgeRules.defaultsKey)
        #expect(!DockBadgeRules.isOn(defaults))
        defaults.set(true, forKey: DockBadgeRules.defaultsKey)
        #expect(DockBadgeRules.isOn(defaults))
    }
}
