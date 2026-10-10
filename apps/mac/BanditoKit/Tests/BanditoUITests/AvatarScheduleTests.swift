import Foundation
import Testing
@testable import BanditoUI

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

    @Test func sleepingIsDrawnAtMostTenTimesASecond() {
        // The "z" of a sleeping raccoon rises all the time. Frames (= redraws of the avatar) in ten seconds: it used to
        // be 200 (20 per second), now 80 (8 per second).
        let count = frames(.sleeping, seconds: 10).count
        #expect(count <= 10 * 10 + 1)
        #expect(count >= 10 * 6)
        #expect(AvatarSchedule.interval(for: .sleeping) >= 0.1)
        #expect(AvatarSchedule.interval(for: .working) == AvatarSchedule.frameInterval)
    }

    @Test func aSleepingAvatarInAListOrInAnInactiveWindowDoesNotAnimate() {
        #expect(AvatarSleepPolicy.rests(mood: .sleeping, listed: true))
        #expect(!AvatarSleepPolicy.rests(mood: .sleeping, listed: false))
        #expect(!AvatarSleepPolicy.rests(mood: .working, listed: true))
        #expect(AvatarSleepPolicy.pausesWhenInactive(mood: .sleeping, active: false))
        #expect(!AvatarSleepPolicy.pausesWhenInactive(mood: .sleeping, active: true))
        #expect(!AvatarSleepPolicy.pausesWhenInactive(mood: .idle, active: false))
    }

    @Test func aRestingSleeperDrawsOnceAndShowsNoZ() {
        let schedule = AvatarSchedule(mood: .sleeping, phase: 0, paused: true)
        #expect(Array(schedule.entries(from: Date(), mode: .normal)).count == 1)
        let pose = AvatarPose.make(mood: .sleeping, time: 5, phase: 0, reduceMotion: true)
        #expect(pose.showsDashEyes && !pose.showsZ)
    }
}
