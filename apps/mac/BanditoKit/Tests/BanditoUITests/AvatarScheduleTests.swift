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
}
