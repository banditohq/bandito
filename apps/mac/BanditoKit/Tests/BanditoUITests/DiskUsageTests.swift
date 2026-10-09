import Foundation
import Testing

@testable import BanditoUI

@Suite struct DiskUsageTests {
    static let units = HostFormat.Units(
        byte: "Б", kilobyte: "КБ", megabyte: "МБ", gigabyte: "ГБ", terabyte: "ТБ", perSecond: "/с")
    static let gib: Int64 = 1_073_741_824

    @Test func usedAndTotalShareOneUnit() {
        let usage = HostFormat.diskUsage(used: 692 * Self.gib, total: 994 * Self.gib, locale: Locale(identifier: "ru_RU"), units: Self.units)
        #expect(usage.used == "692")
        #expect(usage.total == "994 ГБ")
    }

    @Test func emptyDiskDoesNotDivideByZero() {
        let usage = HostFormat.diskUsage(used: 0, total: 0, locale: Locale(identifier: "en_US"), units: Self.units)
        #expect(usage.used == "0")
    }
}
