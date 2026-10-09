import Foundation
import Testing

@testable import BanditoUI

@Suite struct HostFormatTests {
    static let ru = Locale(identifier: "ru_RU")
    static let units = HostFormat.Units(
        byte: "Б", kilobyte: "КБ", megabyte: "МБ", gigabyte: "ГБ", terabyte: "ТБ", perSecond: "/с")

    @Test func bytesUseOneDecimalBelowTenAndWholeNumbersAbove() {
        let gib = 1_073_741_824.0
        #expect(HostFormat.bytes(Int64(5.1 * gib), locale: Self.ru, units: Self.units) == "5,1 ГБ")
        #expect(HostFormat.bytes(Int64(122 * gib), locale: Self.ru, units: Self.units) == "122 ГБ")
        #expect(HostFormat.bytes(0, locale: Self.ru, units: Self.units) == "0 Б")
    }

    @Test func rateIsFormattedWithTheRussianDecimalComma() {
        #expect(HostFormat.rate(Int64(1.9 * 1_048_576), locale: Self.ru, units: Self.units) == "1,9 МБ/с")
        #expect(HostFormat.rate(Int64(512 * 1024), locale: Self.ru, units: Self.units) == "512 КБ/с")
    }

    @Test func percentRoundsToWholePercent() {
        #expect(HostFormat.percent(38.4) == "38%")
        #expect(HostFormat.percent(38.6) == "39%")
    }

    @Test func downsampleAveragesBucketsAndKeepsShortSeriesAsIs() {
        #expect(HostFormat.downsample([1, 2, 3, 4, 5, 6], to: 3) == [1.5, 3.5, 5.5])
        #expect(HostFormat.downsample([1, 2], to: 10) == [1, 2])
        #expect(HostFormat.downsample([], to: 4).isEmpty)
        #expect(HostFormat.downsample([1, 2, 3, 4, 5], to: 2).count == 2)
    }
}
