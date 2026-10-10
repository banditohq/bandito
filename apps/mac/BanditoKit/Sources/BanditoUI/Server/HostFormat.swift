import BanditoL10n
import Foundation

/// Numbers on the Server screens: sizes, rates and percentages, and a series cut down for a chart.
public enum HostFormat {
    /// Unit names. The app uses the translated ones; tests pass their own.
    public struct Units: Sendable, Hashable {
        public var byte: String
        public var kilobyte: String
        public var megabyte: String
        public var gigabyte: String
        public var terabyte: String
        /// Suffix of a rate, such as "/s" or "/с".
        public var perSecond: String

        public init(
            byte: String, kilobyte: String, megabyte: String, gigabyte: String, terabyte: String, perSecond: String
        ) {
            self.byte = byte
            self.kilobyte = kilobyte
            self.megabyte = megabyte
            self.gigabyte = gigabyte
            self.terabyte = terabyte
            self.perSecond = perSecond
        }

        public static var app: Units {
            Units(
                byte: L10n.Server.Units.byte, kilobyte: L10n.Server.Units.kilobyte,
                megabyte: L10n.Server.Units.megabyte, gigabyte: L10n.Server.Units.gigabyte,
                terabyte: L10n.Server.Units.terabyte, perSecond: L10n.Server.Units.perSecond)
        }
    }

    static let base = 1024.0

    /// A size such as "5,1 ГБ" or "122 ГБ": one decimal below 10, whole numbers above.
    public static func bytes(_ count: Int64, locale: Locale = .current, units: Units = .app) -> String {
        let (value, unit) = scale(Double(count), units)
        return "\(number(value, locale: locale)) \(unit)"
    }

    /// A rate such as "1,9 МБ/с".
    public static func rate(_ bytesPerSecond: Int64, locale: Locale = .current, units: Units = .app) -> String {
        let (value, unit) = scale(Double(bytesPerSecond), units)
        return "\(number(value, locale: locale)) \(unit)\(units.perSecond)"
    }

    /// Whole percent, such as "38%".
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Averages neighbouring values so that at most `count` remain. Shorter series come back unchanged.
    public static func downsample(_ values: [Double], to count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard values.count > count else { return values }
        let size = Double(values.count) / Double(count)
        return (0..<count).map { index in
            let lower = Int((Double(index) * size).rounded(.down))
            let upper = index == count - 1 ? values.count : Int((Double(index + 1) * size).rounded(.down))
            let slice = values[lower..<Swift.max(upper, lower + 1)]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }

    static func scale(_ value: Double, _ units: Units) -> (Double, String) {
        let names = [units.byte, units.kilobyte, units.megabyte, units.gigabyte, units.terabyte]
        var scaled = value
        var index = 0
        while scaled >= base && index < names.count - 1 {
            scaled /= base
            index += 1
        }
        return (scaled, names[index])
    }

    /// Disk space the way Finder writes it: decimal units (1 GB = 1000 MB), from ByteCountFormatter like file
    /// sizes. Every disk figure in the app goes through here, so the same space reads the same everywhere.
    public static func diskBytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    /// Used and total space of a disk, such as ("692 ГБ", "994 ГБ"), both in decimal units (see `diskBytes`).
    public static func diskUsage(used: Int64, total: Int64) -> (used: String, total: String) {
        (diskBytes(used), diskBytes(total))
    }

    static func number(_ value: Double, locale: Locale) -> String {
        let separator = locale.decimalSeparator ?? "."
        if value == 0 { return "0" }
        if value < 9.95 {
            return String(format: "%.1f", value).replacingOccurrences(of: ".", with: separator)
        }
        return String(format: "%.0f", value)
    }
}
