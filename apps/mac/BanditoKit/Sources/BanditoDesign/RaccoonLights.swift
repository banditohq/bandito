import CoreGraphics
import Foundation

// The raccoon of points of light: the first screen of onboarding on iPhone and Mac. About two thousand small lights fly
// from a ring around the figure to their rests on the head of the logo (`RaccoonHead`: the head with its ears, as on the
// site), in about 1.6 s. The lights sit on one grid over the head; the two eyes (the logo's chevron and dash) are grids
// of their own and light up last. This file is the figure as pure values: the layers that show it are `RaccoonLightsLayer`.

/// The tone of a light: the fur's orange or a cream spark.
public enum RaccoonLightTone: Sendable, Equatable {
    case signal
    case cream
}

/// Where a light belongs to the raccoon: the head, or an eye.
public enum RaccoonRegion: Sendable, Equatable {
    case fur
    case eye
}

/// A point of the figure's square: 0...1 on each side, y down.
public struct FigurePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
}

/// One light: its rest in the figure's square, its look, and its flight (start point, delay, duration). Pure values.
public struct RaccoonLight: Equatable, Sendable {
    public let region: RaccoonRegion
    public let x: Double
    public let y: Double
    public let startX: Double
    public let startY: Double
    /// Diameter as a share of the square's side.
    public let diameter: Double
    /// Brightness, 0 to 1.
    public let alpha: Double
    public let tone: RaccoonLightTone
    /// Seconds after the assembly starts, and how long the flight takes. `delay + duration` is at most the assembly.
    public let delay: Double
    public let duration: Double
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
public enum RaccoonLights {
    /// Seconds from the first light leaving its ring to the last one arriving.
    public static let assemblyDuration: Double = 1.6
    /// Share of the fur lights that are cream instead of signal.
    static let creamShare: Double = 0.1
    /// The head fills the square less this margin on each side (a share of the square).
    static let margin: Double = 0.05
    /// The eyes' glow, a share of the square's side.
    public static let eyeGlowShare: Double = 0.24

    /// The figure, built once: its lights and the centres of its two eyes.
    public static let figure: Figure = make()

    public struct Figure: Equatable, Sendable {
        public let lights: [RaccoonLight]
        public let eyeCentres: [FigurePoint]
    }

    /// The whole figure, in a fixed order: the same logo always gives the same lights.
    public static func make() -> Figure {
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
    public static func noise(_ seed: Int, _ salt: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(seed)) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// The flight and the glow as they are at a moment, by the same curves and times as the layers' animations. A picture
/// needs them: an offscreen render runs no animation, so `RaccoonLightsLayer.show(at:)` sets the values itself.
extension RaccoonLights {
    /// Core Animation's `CAMediaTimingFunction` with control points (x1, y1) and (x2, y2), at `fraction` of the duration.
    static func timing(_ fraction: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = min(max(fraction, 0), 1)
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var low = 0.0
        var high = 1.0
        for _ in 0..<50 {
            let middle = (low + high) / 2
            if bezier(middle, x1, x2) < x { low = middle } else { high = middle }
        }
        return bezier((low + high) / 2, y1, y2)
    }

    /// The flight's curve (the layers use it for every light) and the eyes' breathing curve.
    static func flightCurve(_ fraction: Double) -> Double { timing(fraction, 0.2, 0.8, 0.2, 1) }

    static func breathCurve(_ fraction: Double) -> Double { timing(fraction, 0.42, 0, 0.58, 1) }

    /// A light's place (in the figure's square) and brightness `elapsed` seconds after the assembly began: before its
    /// delay it sits at its start, faded out (the fill of its animation), then it flies to its rest.
    static func pose(of light: RaccoonLight, at elapsed: Double) -> (x: Double, y: Double, alpha: Double) {
        let progress = progress(of: light, at: elapsed)
        return (
            x: light.startX + (light.x - light.startX) * progress,
            y: light.startY + (light.y - light.startY) * progress,
            alpha: light.alpha * progress)
    }

    /// How far a light's flight has come at `elapsed`, from 0 (at its start) to 1 (at its rest), on the flight's curve.
    static func progress(of light: RaccoonLight, at elapsed: Double) -> Double {
        flightCurve(min(max((elapsed - light.delay) / light.duration, 0), 1))
    }

    /// The eyes' glow at `elapsed`: it lights up from 1.0 s to 1.5 s, is dark for the tenth of a second before the
    /// breathing starts at 1.6 s (the layers do not fill that animation forwards), then breathes between 0.8 and 0.45.
    static func eyeGlow(at elapsed: Double) -> Double {
        if elapsed < 1.0 { return 0 }
        if elapsed < 1.5 { return 0.8 * flightCurve((elapsed - 1.0) / 0.5) }
        if elapsed < 1.6 { return 0 }
        let phase = (elapsed - 1.6).truncatingRemainder(dividingBy: 4.8)
        if phase < 2.4 {
            return 0.8 + (0.45 - 0.8) * breathCurve(phase / 2.4)
        }
        return 0.45 + (0.8 - 0.45) * breathCurve((phase - 2.4) / 2.4)
    }
}
