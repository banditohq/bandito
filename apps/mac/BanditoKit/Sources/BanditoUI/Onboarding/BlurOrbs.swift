import BanditoDesign
import SwiftUI

/// Background of the first-run screens: three soft colored blobs drifting slowly over a faint grid.
/// With motion reduced (system Reduce Motion or Settings → Appearance → Off) the blobs stay where they start.
struct BlurOrbs: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private var reduced: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduced)) { context in
            let t = reduced ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.Bandito.bg
                grid
                orb(color: Color.Bandito.signal, size: 620, period: 18, phase: 0, travel: CGSize(width: 120, height: 60), t: t)
                    .offset(x: -300, y: -330)
                orb(color: AvatarColor.sky.color, size: 700, period: 22, phase: 0.3, travel: CGSize(width: -140, height: -40), t: t)
                    .offset(x: 400, y: -20)
                orb(color: AvatarColor.lilac.color, size: 640, period: 20, phase: 0.6, travel: CGSize(width: 60, height: -90), t: t)
                    .offset(x: -60, y: 300)
            }
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private func orb(
        color: Color, size: CGFloat, period: Double, phase: Double, travel: CGSize, t: TimeInterval
    ) -> some View {
        // 0 → 1 → 0 over one period, like the design's ease-in-out keyframes.
        let k = (1 - cos(2 * Double.pi * (t / period + phase))) / 2
        return Circle()
            .fill(RadialGradient(colors: [color.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: size / 2 * 0.65))
            .frame(width: size, height: size)
            .blur(radius: 20)
            .offset(x: travel.width * k, y: travel.height * k)
    }

    private var grid: some View {
        Canvas { context, size in
            let step: CGFloat = 44
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(Color.Bandito.text.opacity(0.04)), lineWidth: 1)
        }
    }
}
