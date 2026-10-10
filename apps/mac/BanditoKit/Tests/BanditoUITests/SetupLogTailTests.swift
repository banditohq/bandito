import Testing

@testable import BanditoUI

@Suite struct SetupLogTailTests {
    @Test func keepsTheNewestLines() {
        let log = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let tail = ServerFeaturesCard.logTail(log, lines: 3)
        #expect(tail == "line 28\nline 29\nline 30")
    }

    @Test func shortLogComesBackWhole() {
        #expect(ServerFeaturesCard.logTail("one\ntwo", lines: 12) == "one\ntwo")
        #expect(ServerFeaturesCard.logTail("", lines: 12) == "")
    }

    /// The newline that ends the log is not a line, so the count matches what the person reads.
    @Test func trailingNewlineIsNotALine() {
        #expect(ServerFeaturesCard.logLines("a\nb\n").count == 2)
        #expect(ServerFeaturesCard.logLines("a\n\nb").count == 3)
        #expect(ServerFeaturesCard.logLines("").count == 1)
    }
}
