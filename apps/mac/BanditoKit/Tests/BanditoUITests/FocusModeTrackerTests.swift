import Testing

@testable import BanditoUI

@MainActor
@Suite struct FocusModeTrackerTests {
    @Test func startsInPointerMode() {
        #expect(FocusModeTracker().mode == .pointer)
    }

    @Test func navigationKeySwitchesToKeyboard() {
        let tracker = FocusModeTracker()
        tracker.note(.navigationKey)
        #expect(tracker.mode == .keyboard)
    }

    @Test func clickSwitchesBackToPointer() {
        let tracker = FocusModeTracker()
        tracker.note(.navigationKey)
        tracker.note(.pointerPress)
        #expect(tracker.mode == .pointer)
    }

    @Test func otherKeysKeepTheCurrentMode() {
        let tracker = FocusModeTracker()
        tracker.note(.other)
        #expect(tracker.mode == .pointer)
        tracker.note(.navigationKey)
        tracker.note(.other)
        #expect(tracker.mode == .keyboard)
    }

    @Test func tabAndArrowKeysAreNavigation() {
        #expect(FocusModeTracker.input(forKeyCode: 48) == .navigationKey)
        for code: UInt16 in [123, 124, 125, 126] {
            #expect(FocusModeTracker.input(forKeyCode: code) == .navigationKey)
        }
    }

    @Test func typingKeysAreNotNavigation() {
        // 0 is "a", 36 is Return, 53 is Escape.
        #expect(FocusModeTracker.input(forKeyCode: 0) == .other)
        #expect(FocusModeTracker.input(forKeyCode: 36) == .other)
        #expect(FocusModeTracker.input(forKeyCode: 53) == .other)
    }

    @Test func modeAfterInputIsPure() {
        #expect(FocusModeTracker.mode(after: .pointer, input: .navigationKey) == .keyboard)
        #expect(FocusModeTracker.mode(after: .keyboard, input: .pointerPress) == .pointer)
        #expect(FocusModeTracker.mode(after: .keyboard, input: .other) == .keyboard)
        #expect(FocusModeTracker.mode(after: .pointer, input: .other) == .pointer)
    }
}
