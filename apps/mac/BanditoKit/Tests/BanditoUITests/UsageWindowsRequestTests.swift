import BanditoKit
import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct UsageWindowsRequestTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let window = LimitWindow(name: "five_hour", utilization: 0.2, resetsAt: nil)

    private func entry(plan: Plan?, windows: [LimitWindow]) -> UsageEntry {
        UsageEntry(runtime: "claude", windows: windows, updatedAt: 0, plan: plan)
    }

    @Test func aSubscriptionWithoutWindowsIsAskedFor() {
        let entries = [entry(plan: Plan(id: "max_20x", label: "Max ×20"), windows: [])]
        #expect(UsageWindowsRequest.isDue(entries: entries, lastAsked: nil, now: now))
    }

    @Test func noPlanOrWindowsMeansNothingToAsk() {
        #expect(!UsageWindowsRequest.isDue(entries: [entry(plan: nil, windows: [])], lastAsked: nil, now: now))
        let withWindows = [entry(plan: Plan(id: "max_20x", label: "Max ×20"), windows: [window])]
        #expect(!UsageWindowsRequest.isDue(entries: withWindows, lastAsked: nil, now: now))
    }

    @Test func aRequestIsNotRepeatedWithinTwoMinutes() {
        let entries = [entry(plan: Plan(id: "max_20x", label: "Max ×20"), windows: [])]
        #expect(!UsageWindowsRequest.isDue(
            entries: entries, lastAsked: now.addingTimeInterval(-119), now: now))
        #expect(UsageWindowsRequest.isDue(
            entries: entries, lastAsked: now.addingTimeInterval(-120), now: now))
    }
}
