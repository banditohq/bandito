import BanditoDesign
import QuartzCore
import SwiftUI
import UIKit

// The raccoon of points of light: the first screen of onboarding. About two thousand small lights fly from a ring around
// the figure to their rests on the raccoon's 52-point design grid (the same grid as the avatars), in about 1.6 s. The
// figure is the avatar's tile (a rounded square) made of lights, with the avatar's own mask (`RaccoonMask`) left open
// and two signal eyes in it, lighting up last. Each light is one Core Animation layer with one grouped animation; after
// the flight nothing moves, so the main thread is idle. Reduce Motion draws the finished figure at once.

/// The tone of a light: the fur's orange or a cream spark.
enum RaccoonLightTone: Sendable, Equatable {
    case signal
    case cream
}

/// Where a point of the design grid belongs to the raccoon.
enum RaccoonRegion: Sendable, Equatable {
    case outside
    case fur
    case mask
    case eye
}

/// One light: its rest on the grid, its look, and its flight (start point, delay, duration). Pure values.
struct RaccoonLight: Equatable, Sendable {
    let region: RaccoonRegion
    let x: Double
    let y: Double
    let startX: Double
    let startY: Double
    /// Diameter in points.
    let diameter: Double
    /// Brightness, 0 to 1.
    let alpha: Double
    let tone: RaccoonLightTone
    /// Seconds after the assembly starts, and how long the flight takes. `delay + duration` is at most the assembly.
    let delay: Double
    let duration: Double
}

/// The figure and its flight as pure functions of the design grid, so the layout is tested without a screen.
enum RaccoonLights {
    /// Seconds from the first light leaving its ring to the last one arriving.
    static let assemblyDuration: Double = 1.6
    static let gridEdge: Double = 52
    /// The two eyes on the design grid, and their radius.
    static let eyeCentres: [(x: Double, y: Double)] = [(18, 26), (34, 26)]
    static let eyeRadius: Double = 3.4
    static let furCount = 1900
    static let eyeLightsPerEye = 70
    /// The avatar tile on the grid: a rounded square inset by 3, with the avatar's corner radius (17 on 52, less the inset).
    static let tileInset: Double = 3
    static let tileCornerRadius: Double = 16
    /// Share of the fur lights that are cream instead of signal.
    static let creamShare: Double = 0.1

    /// Where `(x, y)` on the grid belongs to the raccoon. The mask is open (`.mask`), the eyes sit in it.
    static func region(x: Double, y: Double) -> RaccoonRegion {
        for eye in eyeCentres where hypot(x - eye.x, y - eye.y) <= eyeRadius {
            return .eye
        }
        if inMask(x: x, y: y) {
            return .mask
        }
        return inTile(x: x, y: y) ? .fur : .outside
    }

    /// The avatar's mask, the very shape `RaccoonMask` draws on every avatar.
    static func inMask(x: Double, y: Double) -> Bool {
        RaccoonMask().path(in: CGRect(x: 0, y: 0, width: gridEdge, height: gridEdge)).contains(CGPoint(x: x, y: y))
    }

    /// The rounded tile under the mask.
    static func inTile(x: Double, y: Double) -> Bool {
        let low = tileInset
        let high = gridEdge - tileInset
        guard x >= low, x <= high, y >= low, y <= high else { return false }
        let cx = min(max(x, low + tileCornerRadius), high - tileCornerRadius)
        let cy = min(max(y, low + tileCornerRadius), high - tileCornerRadius)
        return hypot(x - cx, y - cy) <= tileCornerRadius
    }

    /// The whole figure, in a fixed order: the same input always gives the same lights.
    static func make() -> [RaccoonLight] {
        var lights: [RaccoonLight] = []
        lights.reserveCapacity(furCount + 2 * eyeLightsPerEye)

        // Fur: a low-discrepancy (Halton 2, 3) sweep of the tile's box, kept where the region is fur.
        let span = gridEdge - 2 * tileInset
        var index = 1
        var furPlaced = 0
        while furPlaced < furCount, index < 200_000 {
            let x = halton(index, base: 2) * span + tileInset
            let y = halton(index, base: 3) * span + tileInset
            index += 1
            guard region(x: x, y: y) == .fur else { continue }
            lights.append(light(region: .fur, x: x, y: y, seed: index))
            furPlaced += 1
        }

        // Eyes: a dense disc of lights in each eye, arriving last.
        for (eyeIndex, eye) in eyeCentres.enumerated() {
            for k in 1...eyeLightsPerEye {
                let radius = eyeRadius * sqrt(halton(k, base: 2))
                let angle = 2 * Double.pi * halton(k, base: 3)
                let x = eye.x + radius * cos(angle)
                let y = eye.y + radius * sin(angle)
                lights.append(light(region: .eye, x: x, y: y, seed: 100_000 + eyeIndex * 1000 + k))
            }
        }
        return lights
    }

    /// The radical inverse of `index` in `base`, in 0..<1.
    static func halton(_ index: Int, base: Int) -> Double {
        var fraction = 1.0
        var result = 0.0
        var n = index
        while n > 0 {
            fraction /= Double(base)
            result += fraction * Double(n % base)
            n /= base
        }
        return result
    }

    /// One light's look and flight. The noise is a hash of the seed, so the figure does not change between launches.
    private static func light(region: RaccoonRegion, x: Double, y: Double, seed: Int) -> RaccoonLight {
        let angle = 2 * Double.pi * noise(seed, 1)
        let ring = 24 + 8 * noise(seed, 2)
        let startX = 26 + ring * cos(angle)
        let startY = 27 + ring * sin(angle)
        switch region {
        case .eye:
            return RaccoonLight(
                region: .eye, x: x, y: y, startX: startX, startY: startY, diameter: 2.6, alpha: 1,
                tone: .signal, delay: 0.7 + 0.2 * noise(seed, 3), duration: 0.6 + 0.1 * noise(seed, 4))
        default:
            let cream = noise(seed, 7) < creamShare
            return RaccoonLight(
                region: region, x: x, y: y, startX: startX, startY: startY,
                diameter: 2.4 + 1.2 * noise(seed, 5), alpha: 0.55 + 0.4 * noise(seed, 6),
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
        let unit = side / CGFloat(RaccoonLights.gridEdge)
        let now = CACurrentMediaTime()
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let lights = RaccoonLights.make()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for light in lights {
            let disc = CALayer()
            let diameter = CGFloat(light.diameter)
            disc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            disc.cornerRadius = diameter / 2
            disc.backgroundColor = Self.color(light.tone)
            let rest = CGPoint(x: CGFloat(light.x) * unit, y: CGFloat(light.y) * unit)
            disc.position = rest
            disc.opacity = Float(light.alpha)
            if !reduceMotion {
                let start = CGPoint(x: CGFloat(light.startX) * unit, y: CGFloat(light.startY) * unit)
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

        for eye in RaccoonLights.eyeCentres {
            let glow = CAGradientLayer()
            let size: CGFloat = 64
            glow.type = .radial
            glow.colors = [Self.color(.signal, alpha: 0.6), Self.color(.signal, alpha: 0)]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            glow.position = CGPoint(x: CGFloat(eye.x) * unit, y: CGFloat(eye.y) * unit)
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
