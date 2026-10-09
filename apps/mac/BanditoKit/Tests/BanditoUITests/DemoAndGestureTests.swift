import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct DemoStoreTests {
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bandito.demo-tests.\(UUID().uuidString)")!
    }

    @Test func sampleDataFromTheCanvasIsPresent() {
        let demo = DemoStore(defaults: isolatedDefaults())
        #expect(demo.agents.map(\.name) == ["Forge", "Scout", "Watch", "Night Owl", "Quill", "Atlas"])
        #expect(demo.usage.map(\.name).contains("Claude"))
        #expect(demo.usage.first { $0.name == "Grok" }?.windows.first?.remaining == 0)
        #expect(!demo.files.isEmpty)
        #expect(!demo.terminals.isEmpty)
        #expect(!demo.workplaces.isEmpty)
    }

    @Test func demoIsOffByDefaultAndPersists() {
        let defaults = isolatedDefaults()
        let first = DemoStore(defaults: defaults)
        #expect(!first.enabled)

        first.enabled = true
        let second = DemoStore(defaults: defaults)
        #expect(second.enabled)
    }
}

@MainActor
@Suite struct GestureSettingsTests {
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bandito.gesture-tests.\(UUID().uuidString)")!
    }

    @Test func defaultsEnableFiveGesturesAndKeepDoubleTapOff() {
        let settings = GestureSettings(defaults: isolatedDefaults())
        #expect(Gesture.allCases.count == 6)
        #expect(settings.isEnabled(.twoFingerSwipe))
        #expect(settings.isEnabled(.forcePress))
        #expect(!settings.isEnabled(.doubleTapTwoFingers))
        #expect(settings.swipeSensitivity == 0.5)
    }

    @Test func togglesAndSensitivityPersist() {
        let defaults = isolatedDefaults()
        let first = GestureSettings(defaults: defaults)
        first.setEnabled(.pinch, false)
        first.setEnabled(.doubleTapTwoFingers, true)
        first.swipeSensitivity = 0.9

        let second = GestureSettings(defaults: defaults)
        #expect(!second.isEnabled(.pinch))
        #expect(second.isEnabled(.doubleTapTwoFingers))
        #expect(second.swipeSensitivity == 0.9)
    }

    @Test func sensitivityIsClampedToUnitRange() {
        let settings = GestureSettings(defaults: isolatedDefaults())
        settings.swipeSensitivity = 4
        #expect(settings.swipeSensitivity == 1)
        settings.swipeSensitivity = -1
        #expect(settings.swipeSensitivity == 0)
    }
}
