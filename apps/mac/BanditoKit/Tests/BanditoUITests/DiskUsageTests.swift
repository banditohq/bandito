import Foundation
import Testing

@testable import BanditoUI

@Suite struct DiskUsageTests {
    /// 236.1 decimal GB, which is what Finder and the Files sidebar showed; it is 220 binary GiB.
    static let freeBytes: Int64 = 236_100_000_000

    @Test func diskSpaceUsesDecimalUnits() {
        let text = HostFormat.diskBytes(Self.freeBytes)
        #expect(text.contains("236"))
        #expect(!text.contains("220"))
    }

    @Test func usedAndTotalUseTheSameDecimalUnits() {
        let usage = HostFormat.diskUsage(used: 692_000_000_000, total: 994_000_000_000)
        #expect(usage.used.contains("692"))
        #expect(usage.total.contains("994"))
        #expect(usage.total == HostFormat.diskBytes(994_000_000_000))
    }

    @Test func emptyDiskDoesNotDivideByZero() {
        let usage = HostFormat.diskUsage(used: 0, total: 0)
        #expect(usage.used.contains("0"))
    }
}
