@testable import BanditoKit
import Foundation
import Testing

/// When the limits count as stale: asked again when a surface opens (over two minutes old).
@Suite struct UsageFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(received secondsAgo: TimeInterval) -> UsageEntry {
        UsageEntry(
            runtime: "claude", windows: [], updatedAt: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000))
    }

    @Test func noLimitsAtAllAreStale() {
        #expect(UsageFreshness.isStale([], now: now, after: UsageFreshness.staleAfter))
    }

    @Test func limitsReceivedJustNowAreFresh() {
        #expect(!UsageFreshness.isStale([entry(received: 30)], now: now, after: UsageFreshness.staleAfter))
    }

    @Test func limitsExactlyTwoMinutesOldAreStillFresh() {
        #expect(!UsageFreshness.isStale([entry(received: 120)], now: now, after: UsageFreshness.staleAfter))
    }

    @Test func limitsOlderThanTwoMinutesAreStale() {
        #expect(UsageFreshness.isStale([entry(received: 121)], now: now, after: UsageFreshness.staleAfter))
    }

    /// The newest entry decides: one runtime answered a moment ago, so the set is fresh.
    @Test func theNewestEntryDecides() {
        let entries = [entry(received: 900), entry(received: 10)]
        #expect(!UsageFreshness.isStale(entries, now: now, after: UsageFreshness.staleAfter))
    }
}
