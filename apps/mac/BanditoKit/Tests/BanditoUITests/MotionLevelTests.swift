import Testing

@testable import BanditoUI

@Suite struct MotionLevelTests {
    @Test func offAlwaysReducesMotion() {
        #expect(MotionLevel.off.reducesMotion(systemReduceMotion: false))
        #expect(MotionLevel.off.reducesMotion(systemReduceMotion: true))
    }

    @Test func fullFollowsTheSystemSetting() {
        #expect(!MotionLevel.full.reducesMotion(systemReduceMotion: false))
        #expect(MotionLevel.full.reducesMotion(systemReduceMotion: true))
    }

    @Test func unknownStoredValueMeansFull() {
        #expect(MotionLevel(stored: "garbage") == .full)
        #expect(MotionLevel(stored: "off") == .off)
    }
}
