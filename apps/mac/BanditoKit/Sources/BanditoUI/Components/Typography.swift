import BanditoDesign
import SwiftUI

/// Brand text styles. Sizes and weights come from `BanditoType`; the faces from `BanditoFont`
/// (display Unbounded, text Onest, mono JetBrains Mono).
public enum BanditoTextStyle: CaseIterable, Sendable {
    case title, heading, body, small, mono, label
}

public extension Font {
    /// Brand font for a text style. Tracking and uppercase are applied by the view that uses the style.
    /// `title` and `heading` are display (Unbounded), `mono` is JetBrains Mono, the rest is Onest.
    static func bandito(_ style: BanditoTextStyle) -> Font {
        let metrics = style.metrics
        switch style {
        case .title, .heading: return BanditoFont.display(size: metrics.size, weight: metrics.weight)
        case .mono: return BanditoFont.mono(size: metrics.size, weight: metrics.weight)
        case .body, .small, .label: return BanditoFont.text(size: metrics.size, weight: metrics.weight)
        }
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
