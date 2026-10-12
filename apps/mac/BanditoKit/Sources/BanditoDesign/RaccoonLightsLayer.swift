import CoreGraphics
import Foundation
import QuartzCore

// The raccoon of points of light as Core Animation layers, shared by iPhone and Mac. The host (a UIView or an NSView)
// uses this layer as its own layer and sets the colours it resolved for dark. Each light is a disc layer with one grouped
// animation (position and opacity); the eyes are radial glows that light up last and then breathe. Nothing is drawn per
// frame, no timer runs, and after the flight the main thread is idle. Reduce Motion builds the finished figure at once.
// Geometry: `RaccoonLights` (the figure as values, the same on every platform).

public final class RaccoonLightsLayer: CALayer {
    /// The brand's signal (the fur) and cream (a few sparks), resolved for dark by the host. Needed before the layer
    /// has a size: the figure is built at the first layout that has one.
    public var signalColor: CGColor?
    public var creamColor: CGColor?
    /// Reduce Motion: the finished figure at once. Read when the figure is built.
    public var reduceMotion = false

    private var built = false
    /// The side of the figure in points, and its layers: one disc per light (in the figure's order), one glow per eye.
    private var side: CGFloat = 0
    private var discs: [CALayer] = []
    private var glows: [CAGradientLayer] = []

    public override init() {
        super.init()
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func layoutSublayers() {
        super.layoutSublayers()
        // The size is known only after layout; the figure is built once, when it has one and its colours.
        let side = min(bounds.width, bounds.height)
        guard !built, side > 0, let signal = signalColor, let cream = creamColor else { return }
        built = true
        self.side = side
        build(signal: signal, cream: cream)
    }

    /// Shows the figure as it is `elapsed` seconds after the assembly began, with the animations removed: a picture of
    /// the middle of the flight (`RaccoonLights.pose`). Reduce Motion has nothing to show: the figure is already whole.
    public func show(at elapsed: CFTimeInterval) {
        guard built, !reduceMotion else { return }
        let figure = RaccoonLights.figure
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (disc, light) in zip(discs, figure.lights) {
            let pose = RaccoonLights.pose(of: light, at: elapsed)
            disc.removeAnimation(forKey: "assemble")
            disc.position = CGPoint(x: CGFloat(pose.x) * side, y: CGFloat(pose.y) * side)
            disc.opacity = Float(pose.alpha)
        }
        for glow in glows {
            glow.removeAllAnimations()
            glow.opacity = Float(RaccoonLights.eyeGlow(at: elapsed))
        }
        CATransaction.commit()
    }

    /// A point as the animation's value: `NSValue` on both platforms, with the initialiser each one has.
    private static func value(_ point: CGPoint) -> NSValue {
        #if os(macOS)
        NSValue(point: point)
        #else
        NSValue(cgPoint: point)
        #endif
    }

    private func build(signal: CGColor, cream: CGColor) {
        let now = convertTime(CACurrentMediaTime(), from: nil)
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let figure = RaccoonLights.figure

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for light in figure.lights {
            let disc = CALayer()
            let diameter = CGFloat(light.diameter) * side
            disc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            disc.cornerRadius = diameter / 2
            disc.backgroundColor = light.tone == .signal ? signal : cream
            let rest = CGPoint(x: CGFloat(light.x) * side, y: CGFloat(light.y) * side)
            disc.position = rest
            disc.opacity = Float(light.alpha)
            if !reduceMotion {
                let start = CGPoint(x: CGFloat(light.startX) * side, y: CGFloat(light.startY) * side)
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = Self.value(start)
                move.toValue = Self.value(rest)
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
            addSublayer(disc)
            discs.append(disc)
        }

        let glowSize = side * CGFloat(RaccoonLights.eyeGlowShare)
        for eye in figure.eyeCentres {
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.colors = [signal.copy(alpha: 0.6) ?? signal, signal.copy(alpha: 0) ?? signal]
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
            addSublayer(glow)
            glows.append(glow)
        }
        CATransaction.commit()
    }
}
