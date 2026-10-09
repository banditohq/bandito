import BanditoDesign
import SwiftUI

/// The one place where the brand typeface is chosen.
/// `nil` means the system font (SF Pro / SF Mono). When Geist is bundled, set the family names here.
public enum BanditoFont {
    public static let sansName: String? = nil
    public static let monoName: String? = nil

    /// Font for an explicit size and numeric weight (400, 500, 600, 700).
    static func font(size: CGFloat, weight: Int, mono: Bool = false) -> Font {
        let fontWeight = fontWeight(weight)
        if mono {
            if let monoName {
                return .custom(monoName, size: size).weight(fontWeight)
            }
            return .system(size: size, weight: fontWeight, design: .monospaced)
        }
        if let sansName {
            return .custom(sansName, size: size).weight(fontWeight)
        }
        return .system(size: size, weight: fontWeight, design: .default)
    }

    static func fontWeight(_ weight: Int) -> Font.Weight {
        switch weight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }
}

/// Brand text styles. Sizes and weights come from `BanditoType`.
public enum BanditoTextStyle: CaseIterable, Sendable {
    case title, heading, body, small, mono, label
}

public extension Font {
    /// Brand font for a text style. Tracking and uppercase are applied by the view that uses the style.
    static func bandito(_ style: BanditoTextStyle) -> Font {
        let metrics = style.metrics
        return BanditoFont.font(size: metrics.size, weight: metrics.weight, mono: style == .mono)
    }
}

extension BanditoTextStyle {
    var metrics: (size: CGFloat, weight: Int) {
        switch self {
        case .title: (BanditoType.title.size, BanditoType.title.weight)
        case .heading: (BanditoType.heading.size, BanditoType.heading.weight)
        case .body: (BanditoType.body.size, BanditoType.body.weight)
        case .small: (BanditoType.small.size, BanditoType.small.weight)
        case .mono: (BanditoType.mono.size, BanditoType.mono.weight)
        case .label: (BanditoType.label.size, BanditoType.label.weight)
        }
    }
}
