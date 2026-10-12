import BanditoDesign
import QuartzCore
import SwiftUI
import UIKit

// The raccoon of points of light: the first screen of onboarding. About two thousand small lights fly from a ring around
// the figure to their rests on the head of the logo (`RaccoonHead`: the head with its ears, as on the site), in about
// 1.6 s. The lights sit on one grid over the head; the two eyes (the logo's chevron and dash) are grids of their own and
// light up last. Each light is one Core Animation layer with one grouped animation; after the flight nothing moves, so
// the main thread is idle. Reduce Motion draws the finished figure at once.

/// The tone of a light: the fur's orange or a cream spark.
enum RaccoonLightTone: Sendable, Equatable {
    case signal
    case cream
}

/// Where a light belongs to the raccoon: the head, or an eye.
enum RaccoonRegion: Sendable, Equatable {
    case fur
    case eye
}

/// A point of the figure's square: 0...1 on each side, y down.
struct FigurePoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

/// One light: its rest in the figure's square, its look, and its flight (start point, delay, duration). Pure values.
struct RaccoonLight: Equatable, Sendable {
    let region: RaccoonRegion
    let x: Double
    let y: Double
    let startX: Double
    let startY: Double
    /// Diameter as a share of the square's side.
    let diameter: Double
    /// Brightness, 0 to 1.
    let alpha: Double
    let tone: RaccoonLightTone
    /// Seconds after the assembly starts, and how long the flight takes. `delay + duration` is at most the assembly.
    let delay: Double
    let duration: Double
}

/// The logo's units to the figure's square: the head's box, centred and scaled to fill the square less a margin.
struct RaccoonFrame: Equatable, Sendable {
    let centreX: Double
    let centreY: Double
    /// Square units per logo unit.
    let scale: Double

    init(box: CGRect) {
        centreX = Double(box.midX)
        centreY = Double(box.midY)
        scale = (1 - 2 * RaccoonLights.margin) / Double(max(box.width, box.height))
    }

    func point(_ p: CGPoint) -> FigurePoint {
        FigurePoint(x: 0.5 + (Double(p.x) - centreX) * scale, y: 0.5 + (Double(p.y) - centreY) * scale)
    }
}

/// The figure and its flight as pure functions of the logo's head, so the layout is tested without a screen.
enum RaccoonLights {
    /// Seconds from the first light leaving its ring to the last one arriving.
    static let assemblyDuration: Double = 1.6
    /// Share of the fur lights that are cream instead of signal.
    static let creamShare: Double = 0.1
    /// The head fills the square less this margin on each side (a share of the square).
    static let margin: Double = 0.05
    /// The eyes' glow, a share of the square's side.
    static let eyeGlowShare: Double = 0.24

    /// The figure, built once: its lights and the centres of its two eyes.
    static let figure: Figure = make()

    struct Figure: Equatable, Sendable {
        let lights: [RaccoonLight]
        let eyeCentres: [FigurePoint]
    }

    /// The whole figure, in a fixed order: the same logo always gives the same lights.
    static func make() -> Figure {
        guard let sample = RaccoonHead.sample() else { return Figure(lights: [], eyeCentres: []) }
        let frame = RaccoonFrame(box: sample.box)
        let cell = Double(RaccoonHead.gridStep) * frame.scale
        var lights: [RaccoonLight] = []
        lights.reserveCapacity(sample.head.count + sample.eyes.reduce(0) { $0 + $1.count })
        for (index, point) in sample.head.enumerated() {
            lights.append(light(region: .fur, at: frame.point(point), cell: cell, seed: index + 1))
        }
        for (eyeIndex, eye) in sample.eyes.enumerated() {
            for (k, point) in eye.enumerated() {
                let seed = 100_000 + eyeIndex * 1000 + k + 1
                lights.append(light(region: .eye, at: frame.point(point), cell: cell, seed: seed))
            }
        }
        return Figure(lights: lights, eyeCentres: sample.eyeCentres.map(frame.point))
    }

    /// One light's look and flight. The noise is a hash of the seed, so the figure does not change between launches.
    private static func light(region: RaccoonRegion, at rest: FigurePoint, cell: Double, seed: Int) -> RaccoonLight {
        let angle = 2 * Double.pi * noise(seed, 1)
        let ring = 0.46 + 0.16 * noise(seed, 2)
        let startX = 0.5 + ring * cos(angle)
        let startY = 0.5 + ring * sin(angle)
        switch region {
        case .eye:
            return RaccoonLight(
                region: .eye, x: rest.x, y: rest.y, startX: startX, startY: startY, diameter: cell * 0.95, alpha: 1,
                tone: .signal, delay: 0.7 + 0.2 * noise(seed, 3), duration: 0.6 + 0.1 * noise(seed, 4))
        case .fur:
            let cream = noise(seed, 7) < creamShare
            return RaccoonLight(
                region: .fur, x: rest.x, y: rest.y, startX: startX, startY: startY,
                diameter: cell * (0.62 + 0.25 * noise(seed, 5)), alpha: 0.55 + 0.4 * noise(seed, 6),
                tone: cream ? .cream : .signal, delay: 0.3 * noise(seed, 3), duration: 1.0 + 0.3 * noise(seed, 4))
        }
    }

    /// A stable pseudo-random value in 0..<1 from a seed and a salt (SplitMix64 finalizer).
    static func noise(_ seed: Int, _ salt: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// The lights of the raccoon in a square view. Built once per appearance; Reduce Motion draws the rest at once.
struct RaccoonLightsAssembly: UIViewRepresentable {
    let reduceMotion: Bool

    func makeUIView(context: Context) -> RaccoonLightsView {
        let view = RaccoonLightsView()
        view.reduceMotion = reduceMotion
        return view
    }

    func updateUIView(_ view: RaccoonLightsView, context: Context) {
        view.reduceMotion = reduceMotion
    }
}

/// The layers of the figure. Lights are plain layers (a colored disc each), eyes get a radial glow that breathes.
final class RaccoonLightsView: UIView {
    var reduceMotion = false
    private var built = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The size is known only after layout; the figure is built once, when it has one.
        if !built, bounds.width > 0, bounds.height > 0 {
            built = true
            build()
        }
    }

    private func build() {
        let side = min(bounds.width, bounds.height)
        let now = CACurrentMediaTime()
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let figure = RaccoonLights.figure

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for light in figure.lights {
            let disc = CALayer()
            let diameter = CGFloat(light.diameter) * side
            disc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            disc.cornerRadius = diameter / 2
            disc.backgroundColor = Self.color(light.tone)
            let rest = CGPoint(x: CGFloat(light.x) * side, y: CGFloat(light.y) * side)
            disc.position = rest
            disc.opacity = Float(light.alpha)
            if !reduceMotion {
                let start = CGPoint(x: CGFloat(light.startX) * side, y: CGFloat(light.startY) * side)
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(cgPoint: start)
                move.toValue = NSValue(cgPoint: rest)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = light.alpha
                let group = CAAnimationGroup()
                group.animations = [move, fade]
                group.duration = light.duration
                group.beginTime = now + light.delay
                group.fillMode = .backwards
                group.timingFunction = curve
                disc.add(group, forKey: "assemble")
            }
            layer.addSublayer(disc)
        }

        let glowSize = side * RaccoonLights.eyeGlowShare
        for eye in figure.eyeCentres {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [Self.color(.signal, alpha: 0.6), Self.color(.signal, alpha: 0)]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
            glow.position = CGPoint(x: CGFloat(eye.x) * side, y: CGFloat(eye.y) * side)
            if reduceMotion {
                glow.opacity = 0.8
            } else {
                glow.opacity = 0
                let lit = CABasicAnimation(keyPath: "opacity")
                lit.fromValue = 0
                lit.toValue = 0.8
                lit.duration = 0.5
                lit.beginTime = now + 1.0
                lit.fillMode = .backwards
                lit.timingFunction = curve
                glow.add(lit, forKey: "light")
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 0.8
                breathe.toValue = 0.45
                breathe.duration = 2.4
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.beginTime = now + 1.6
                breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glow.add(breathe, forKey: "breathe")
            }
            layer.addSublayer(glow)
        }
        CATransaction.commit()
    }

    /// The brand's signal and cream, resolved for dark: the onboarding is always dark.
    private static func color(_ tone: RaccoonLightTone, alpha: CGFloat = 1) -> CGColor {
        let base = tone == .signal ? Color.Bandito.signal : Color.Bandito.text
        return UIColor(base)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            .withAlphaComponent(alpha)
            .cgColor
    }
}
