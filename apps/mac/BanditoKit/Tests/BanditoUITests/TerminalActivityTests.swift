import Foundation
import Testing

@testable import BanditoUI

@Suite struct TerminalActivityTests {
    static let t0 = Date(timeIntervalSince1970: 1_000)

    static func bytes(_ text: String) -> Data { Data(text.utf8) }

    @Test func countsBytesAndLines() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("one\ntwo\n"), at: Self.t0)
        activity.record(Self.bytes("three"), at: Self.t0)
        #expect(activity.lines == 2)
        #expect(activity.bytes == 13)
    }

    @Test func waitingForInputNeedsAQuietTailOfTwoSeconds() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("Continue? [y/N]"), at: Self.t0)
        #expect(!activity.isWaitingForInput(now: Self.t0.addingTimeInterval(2)))
        #expect(activity.isWaitingForInput(now: Self.t0.addingTimeInterval(2.1)))
    }

    @Test func promptEndingsAreDetected() {
        for prompt in ["Password:", "ready?", "[y/N]", "deploy [staging]"] {
            var activity = TerminalActivity()
            activity.record(Self.bytes(prompt), at: Self.t0)
            #expect(activity.isWaitingForInput(now: Self.t0.addingTimeInterval(5)), "\(prompt)")
        }
    }

    @Test func aLineEndingInANewlineIsNotAPrompt() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("question?\n"), at: Self.t0)
        #expect(!activity.isWaitingForInput(now: Self.t0.addingTimeInterval(10)))
    }

    @Test func plainPromptWithoutTheSignCharactersIsNotWaiting() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("deploy@tokyo ~ $ "), at: Self.t0)
        #expect(!activity.isWaitingForInput(now: Self.t0.addingTimeInterval(10)))
    }

    @Test func escapeSequencesDoNotHideThePrompt() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("\u{1B}[1;33mPassword:\u{1B}[0m"), at: Self.t0)
        #expect(activity.tail == "Password:")
        #expect(activity.isWaitingForInput(now: Self.t0.addingTimeInterval(5)))
    }

    @Test func newOutputAfterThePromptClearsTheWait() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("Continue?"), at: Self.t0)
        activity.record(Self.bytes(" yes\n"), at: Self.t0.addingTimeInterval(3))
        #expect(!activity.isWaitingForInput(now: Self.t0.addingTimeInterval(10)))
    }

    @Test func sparklineBucketsAreFiveSecondsAndCoverOneMinute() {
        var activity = TerminalActivity()
        // Buckets are aligned to 5 s. Bucket of t0 (1000 s) is 200.
        activity.record(Self.bytes("aaaa"), at: Self.t0)  // 1000.0
        activity.record(Self.bytes("bb"), at: Self.t0.addingTimeInterval(4.9))  // same bucket
        activity.record(Self.bytes("c"), at: Self.t0.addingTimeInterval(5))  // next bucket

        let line = activity.sparkline(now: Self.t0.addingTimeInterval(5))
        #expect(line.count == 12)
        #expect(line.last == 1)
        #expect(line[line.count - 2] == 6)
        #expect(line.dropLast(2).allSatisfy { $0 == 0 })
    }

    @Test func sparklineForgetsBucketsOlderThanAMinute() {
        var activity = TerminalActivity()
        activity.record(Self.bytes("old"), at: Self.t0)
        let later = Self.t0.addingTimeInterval(61)
        #expect(activity.sparkline(now: later).allSatisfy { $0 == 0 })
    }
}
