import BanditoDesign
@testable import BanditoUI
import Foundation
import Testing

struct AvatarScheduleTests {
    private func frames(_ mood: AvatarMood, seconds: Double, phase: Double = 0) -> [Date] {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let schedule = AvatarSchedule(mood: mood, phase: phase, paused: false)
        var out: [Date] = []
        for date in schedule.entries(from: start, mode: .normal) {
            if date.timeIntervalSince(start) > seconds { break }
            out.append(date)
        }
        return out
    }

    @Test func idleIsDrawnOnlyAroundTheBlink() {
        // 20 s of an idle raccoon: four blinks of 0.35 s plus the frame after each, not 400 frames.
        let count = frames(.idle, seconds: 20).count
        #expect(count < 60)
        #expect(count >= 4 * 6)
    }

    @Test func idleComesBackToOpenEyesAfterEachBlink() {
        let all = frames(.idle, seconds: 20)
        // The last frame of every blink run is at rest (eyes open).
        var runs: [[Date]] = []
        for date in all {
            if let last = runs.last?.last, date.timeIntervalSince(last) <= AvatarSchedule.frameInterval + 0.001 {
                runs[runs.count - 1].append(date)
            } else {
                runs.append([date])
            }
        }
        // The first run may start mid-blink and the last one is cut by the 20 s window.
        for run in runs.dropFirst().dropLast() {
            let pose = AvatarPose.make(mood: .idle, time: run.last!.timeIntervalSinceReferenceDate, phase: 0)
            #expect(pose.eyeScaleY == 1)
        }
    }

    @Test func workingMovesAllTheTime() {
        #expect(frames(.working, seconds: 2).count >= 40)
    }

    @Test func pausedDrawsOnce() {
        let schedule = AvatarSchedule(mood: .working, phase: 0, paused: true)
        #expect(Array(schedule.entries(from: Date(), mode: .normal)).count == 1)
    }

    @Test func sleepingIsDrawnAtMostTwelveTimesASecond() {
        // The "z" of a sleeping raccoon rises all the time, slowly: it gets fewer frames than a mood that moves fast.
        let count = frames(.sleeping, seconds: 10).count
        #expect(count <= 10 * 12 + 1)
        #expect(count >= 10 * 8)
        #expect(AvatarSchedule.interval(for: .sleeping) >= 1.0 / 12 - 0.0001)
        #expect(AvatarSchedule.interval(for: .working) == AvatarSchedule.frameInterval)
    }

    @Test func aMovingMoodGetsThirtyFramesASecond() {
        #expect(abs(AvatarSchedule.frameInterval - 1.0 / 30) < 0.0001)
        let count = frames(.working, seconds: 10).count
        #expect(count >= 10 * 29)
        #expect(count <= 10 * 31 + 1)
    }

    @Test func anAvatarAsksForNoFramesOnlyWhenNobodySeesIt() {
        // A sleeper in a list now animates like any other; it rests only out of view, or in a window that is not active.
        #expect(!AvatarSleepPolicy.paused(mood: .sleeping, still: false, onScreen: true, windowActive: true))
        #expect(AvatarSleepPolicy.paused(mood: .sleeping, still: false, onScreen: false, windowActive: true))
        #expect(AvatarSleepPolicy.paused(mood: .working, still: false, onScreen: false, windowActive: true))
        #expect(AvatarSleepPolicy.paused(mood: .sleeping, still: false, onScreen: true, windowActive: false))
        #expect(!AvatarSleepPolicy.paused(mood: .working, still: false, onScreen: true, windowActive: false))
        #expect(AvatarSleepPolicy.paused(mood: .idle, still: true, onScreen: true, windowActive: true))
    }

    @Test func aPictureTileMovesWithTheMoodAndRestsWithoutMotion() {
        let working = AvatarPose.make(mood: .working, time: 0.6, phase: 0)
        #expect(TileMotion.scale(working) != 1)
        #expect(abs(TileMotion.scale(working) - 1) <= 0.03 + 0.0001)
        let rest = AvatarPose.make(mood: .working, time: 0.6, phase: 0, reduceMotion: true)
        #expect(TileMotion.scale(rest) == 1)
        let hop = AvatarPose.make(mood: .needsYou, time: 1.4, phase: 0)
        #expect(hop.bodyOffsetY < 0)
    }

    @Test func aRestingSleeperDrawsOnceAndShowsNoZ() {
        let schedule = AvatarSchedule(mood: .sleeping, phase: 0, paused: true)
        #expect(Array(schedule.entries(from: Date(), mode: .normal)).count == 1)
        let pose = AvatarPose.make(mood: .sleeping, time: 5, phase: 0, reduceMotion: true)
        #expect(pose.showsDashEyes && !pose.showsZ)
    }
}
