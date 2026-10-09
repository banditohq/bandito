import BanditoDesign
import BanditoL10n
import SwiftUI

/// The left side of the account step: a Mac and an iPhone floating, a dashed link between them with two dots
/// travelling along it, and the one-team caption. Static with motion reduced.
struct AccountIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private var reduced: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { context in
                let t = reduced ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Canvas { canvas, _ in
                        drawLink(canvas, t: t)
                    }
                    mac(t: t)
                        .offset(x: -40, y: -50)
                    phone(t: t)
                        .offset(x: 70, y: 60)
                }
                .frame(width: 380, height: 420)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Onboarding.Account.heroTitle)
                    .font(BanditoFont.font(size: 22, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Onboarding.Account.heroText)
                    .font(BanditoFont.font(size: 14.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
            }
            .padding(.leading, 48)
            .padding(.trailing, 28)
            .padding(.top, 24)
        }
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RadialGradient(
                colors: [Color.Bandito.signal.opacity(0.14), .clear],
                center: UnitPoint(x: 0.45, y: 0.45), startRadius: 0, endRadius: 300)
        )
        .background(Color.Bandito.surface1.opacity(0.5))
        .accessibilityHidden(true)
    }

    private func mac(t: TimeInterval) -> some View {
        // Floats: 6 s cycle, 8 pt up and back.
        let lift = reduced ? 0 : (1 - cos(2 * Double.pi * t / 6)) / 2 * 8
        return HStack(spacing: 0) {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7).fill(Color.Bandito.signal.opacity(0.25)).frame(height: 22)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 7).fill(Color.Bandito.text.opacity(0.07)).frame(height: 22)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 26)
            .padding(.horizontal, 10)
            .frame(width: 110)
            .background(Color(red: 0.10, green: 0.09, blue: 0.08))
            VStack(alignment: .trailing, spacing: 10) {
                RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.17, green: 0.15, blue: 0.13))
                    .frame(width: 130, height: 22)
                RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.13, green: 0.11, blue: 0.10))
                    .frame(width: 200, height: 34)
                RoundedRectangle(cornerRadius: 12).stroke(Color.Bandito.signal.opacity(0.45))
                    .frame(width: 220, height: 70)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 30)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 400, height: 260)
        .background(Color(red: 0.12, green: 0.11, blue: 0.09), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.Bandito.text.opacity(0.12)))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 24)
        .scaleEffect(0.6)
        .frame(width: 240, height: 156)
        .offset(y: -lift)
    }

    private func phone(t: TimeInterval) -> some View {
        // Floats: 7 s cycle with a 1 s delay, a slight tilt.
        let k = reduced ? 0 : (1 - cos(2 * Double.pi * (t - 1) / 7)) / 2
        let pulse = reduced ? 0 : (t.truncatingRemainder(dividingBy: 2.2)) / 2.2
        return VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.14, green: 0.12, blue: 0.09))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.signal.opacity(0.5 * (1 - pulse))))
                .frame(height: 64)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 7).fill(Color.Bandito.text.opacity(0.07)).frame(height: 18)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 30)
        .padding(.horizontal, 12)
        .frame(width: 120, height: 240)
        .background(Color(red: 0.11, green: 0.10, blue: 0.09), in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.Bandito.text.opacity(0.14)))
        .shadow(color: .black.opacity(0.7), radius: 40, y: 20)
        .offset(y: -12 * k)
        .rotationEffect(.degrees(4 - 1 * k))
    }

    /// Dashed curve between the two devices and two dots moving along it in opposite directions.
    private func drawLink(_ canvas: GraphicsContext, t: TimeInterval) {
        // Coordinates are in the 380 x 420 frame; the devices sit around its center.
        let start = CGPoint(x: 200, y: 215)
        let control = CGPoint(x: 232, y: 232)
        let end = CGPoint(x: 240, y: 262)
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        canvas.stroke(path, with: .color(Color.Bandito.signal.opacity(0.7)),
                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 5], dashPhase: CGFloat(-t * 36).truncatingRemainder(dividingBy: 9)))
        guard !reduced else { return }
        let u = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
        for (fraction, color) in [(u, Color.Bandito.signal), (1 - u, AvatarColor.sage.color)] {
            let p = Self.point(on: (start, control, end), at: fraction)
            let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            canvas.fill(Path(ellipseIn: dot), with: .color(color))
        }
    }

    /// Point on a quadratic curve at `u` in 0...1.
    static func point(on curve: (CGPoint, CGPoint, CGPoint), at u: Double) -> CGPoint {
        let (p0, p1, p2) = curve
        let a = (1 - u) * (1 - u)
        let b = 2 * (1 - u) * u
        let c = u * u
        return CGPoint(
            x: a * p0.x + b * p1.x + c * p2.x,
            y: a * p0.y + b * p1.y + c * p2.y)
    }
}
