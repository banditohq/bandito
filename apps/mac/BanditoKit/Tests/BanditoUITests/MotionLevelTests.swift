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

@Suite struct MotionLessTests {
    @Test func lessHalvesDurations() {
        #expect(MotionLevel.less.scaled(0.4) == 0.2)
        #expect(MotionLevel.less.scaled(1.2) == 0.6)
        #expect(MotionLevel.full.scaled(0.4) == 0.4)
        #expect(MotionLevel.off.scaled(0.4) == 0.4)
    }

    @Test func lessAndOffDropRepeatingMotion() {
        #expect(MotionLevel.full.allowsRepeatingMotion)
        #expect(!MotionLevel.less.allowsRepeatingMotion)
        #expect(!MotionLevel.off.allowsRepeatingMotion)
    }
}
