import BanditoDesign
import SwiftUI

/// One paper piece of a confetti burst, relative to the burst's center.
struct ConfettiPiece: Equatable, Sendable {
    var dx: CGFloat
    var dy: CGFloat
    var width: CGFloat
    var height: CGFloat
    var colorIndex: Int
}

/// The burst layout. Deterministic, so the same count always looks the same.
enum ConfettiPlan {
    static let colorCount = 7
    /// Seconds one piece takes to fly out and fade.
    static let duration: TimeInterval = 1.4

    static func pieces(count: Int) -> [ConfettiPiece] {
        guard count > 0 else { return [] }
        return (0..<count).map { k in
            let angle = Double(k) / Double(count) * 2 * .pi
            let dx = (cos(angle) * (90 + Double(k % 3) * 30)).rounded()
            let dy = (sin(angle) * (70 + Double(k % 4) * 20)).rounded() - 40
            return ConfettiPiece(
                dx: CGFloat(dx), dy: CGFloat(dy),
                width: k % 2 == 1 ? 6 : 8, height: k % 2 == 1 ? 10 : 6,
                colorIndex: k % colorCount)
        }
    }
}

/// A confetti burst drawn at `elapsed` seconds after it started. The caller drives time (a TimelineView).
struct ConfettiView: View {
    var elapsed: TimeInterval
    var count: Int = 14

    private static let colors: [Color] = [
        Color.Bandito.signal, AvatarColor.peach.color, AvatarColor.sage.color, AvatarColor.sky.color,
        AvatarColor.lilac.color, Color.Bandito.text, AvatarColor.rose.color,
    ]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for (k, piece) in ConfettiPlan.pieces(count: count).enumerated() {
                // Each piece starts a little after the previous one, as in the design.
                let p = min(max((elapsed - Double(k % 5) * 0.03) / ConfettiPlan.duration, 0), 1)
                guard p > 0 else { continue }
                let eased = 1 - pow(1 - p, 3)
                let opacity = p < 0.1 ? p / 0.1 : 1 - (p - 0.1) / 0.9
                var layer = context
                layer.opacity = opacity
                layer.translateBy(
                    x: center.x + piece.dx * CGFloat(eased), y: center.y + piece.dy * CGFloat(eased))
                layer.rotate(by: .degrees(260 * p))
                let rect = CGRect(x: -piece.width / 2, y: -piece.height / 2, width: piece.width, height: piece.height)
                layer.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Self.colors[piece.colorIndex]))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
