import BanditoDesign
import SwiftUI

/// Background of the first-run screens: three soft colored blobs drifting slowly over a faint grid.
/// With motion reduced (system Reduce Motion or Settings → Appearance → Off) the blobs stay where they start.
struct BlurOrbs: View {
    /// Whether the blobs move. Off: see `DriftingOrb.drift()`.
    static let drifts = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private var reduced: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
    }

    var body: some View {
        // Each blob drifts by a repeating Core Animation animation, not by redrawing every frame: the window stays
        // cheap while the first-run screens are open. The grid is drawn once.
        ZStack {
            Color.Bandito.bg
            grid
            DriftingOrb(color: Color.Bandito.signal, size: 620, period: 18, travel: CGSize(width: 120, height: 60), still: reduced)
                .offset(x: -300, y: -330)
            DriftingOrb(color: AvatarColor.sky.color, size: 700, period: 22, travel: CGSize(width: -140, height: -40), still: reduced)
                .offset(x: 400, y: -20)
            DriftingOrb(color: AvatarColor.lilac.color, size: 640, period: 20, travel: CGSize(width: 60, height: -90), still: reduced)
                .offset(x: -60, y: 300)
        }
        .clipped()
        .accessibilityHidden(true)
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

/// One soft blob that drifts by `travel` and back over `period` seconds. The radial gradient is already soft, so no
/// blur filter is needed.
private struct DriftingOrb: View {
    let color: Color
    let size: CGFloat
    let period: Double
    let travel: CGSize
    let still: Bool

    @State private var away = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.3), .clear], center: .center, startRadius: 0, endRadius: size / 2 * 0.72))
            .frame(width: size, height: size)
            .offset(x: away ? travel.width : 0, y: away ? travel.height : 0)
            .onAppear { drift() }
            .onChange(of: still) { drift() }
            // Flattened into one layer, so the drift moves a bitmap instead of re-rendering the gradient.
            .drawingGroup()
    }

    private func drift() {
        // The drift is off: animating three window-sized layers kept the main thread busy (about half a core in a
        // debug build) for a background nobody watches. The blobs keep their place; `still` stays for later tuning.
        guard !still, BlurOrbs.drifts else {
            away = false
            return
        }
        withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) { away = true }
    }
}
