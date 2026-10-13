import Testing

@testable import BanditoKit

@Suite struct ChatGroupingTests {
    let minute: Int64 = 60_000

    @Test func messagesOfOneSenderCloseInTimeFormAGroup() {
        let a = ChatGrouping.Kind.mine(ts: 0), b = ChatGrouping.Kind.mine(ts: 4 * minute)
        #expect(ChatGrouping.sameGroup(a, b))
        #expect(!ChatGrouping.sameGroup(a, .mine(ts: 6 * minute)))
        #expect(!ChatGrouping.sameGroup(a, .theirs(from: nil, ts: 0)))
        #expect(!ChatGrouping.sameGroup(.theirs(from: "Scout", ts: 0), .theirs(from: nil, ts: 0)))
    }

    @Test func theTimeIsShownUnderTheLastMessageOfAGroup() {
        let first = ChatGrouping.Kind.theirs(from: nil, ts: 0)
        #expect(!ChatGrouping.showsTime(first, next: .theirs(from: nil, ts: minute)))
        #expect(ChatGrouping.showsTime(first, next: .mine(ts: minute)))
        #expect(ChatGrouping.showsTime(first, next: .line))
        #expect(ChatGrouping.showsTime(first, next: nil))
    }

    @Test func aGroupIsTighterThanTwoSenders() {
        let tight = ChatGrouping.spacing(before: .mine(ts: 0), after: .mine(ts: minute))
        let loose = ChatGrouping.spacing(before: .mine(ts: 0), after: .theirs(from: nil, ts: minute))
        #expect(tight < loose)
        #expect(ChatGrouping.spacing(before: nil, after: .line) == 0)
        #expect(ChatGrouping.spacing(before: .line, after: .divider) > ChatGrouping.spacing(before: .divider, after: .line))
    }

    @Test func aMessageWithoutATimeJoinsTheMessageBeforeIt() {
        #expect(ChatGrouping.sameGroup(.theirs(from: nil, ts: nil), .theirs(from: nil, ts: 99 * minute)))
    }
}
