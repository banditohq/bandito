import Foundation
import Testing

@testable import BanditoKit

@Suite struct ReadAloudPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "dev.bandito.test.readaloud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func offByDefault() {
        #expect(ReadAloud.isOn(agentID: "a1", defaults: freshDefaults()) == false)
    }

    @Test func keptPerAgent() {
        let defaults = freshDefaults()
        ReadAloud.set(true, agentID: "a1", defaults: defaults)
        #expect(ReadAloud.isOn(agentID: "a1", defaults: defaults))
        #expect(ReadAloud.isOn(agentID: "a2", defaults: defaults) == false)
        ReadAloud.set(false, agentID: "a1", defaults: defaults)
        #expect(ReadAloud.isOn(agentID: "a1", defaults: defaults) == false)
    }
}
