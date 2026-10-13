import CoreGraphics
import Foundation
import QuartzCore

// The raccoon of points of light as Core Animation layers, shared by iPhone and Mac. The host (a UIView or an NSView)
// uses this layer as its own layer. Each light is a disc layer with one grouped animation (position and opacity); the
// eyes are radial glows that light up last and then breathe. Nothing is drawn per frame, no timer runs, and after the
// flight the main thread is idle. Reduce Motion builds the finished figure at once. Geometry: `RaccoonLights`.

public final class RaccoonLightsLayer: CALayer {
    /// The brand's signal (the fur) and cream (a few sparks), resolved by the host. Set with `configure`.
    private var signalColor: CGColor?
    private var creamColor: CGColor?
    /// The fur lights at their own brightness (dark theme, iPhone), or solid (light theme). Set with `configure`.
    private var fullStrength = false
    /// Reduce Motion: the finished figure at once. Set with `configure`.
    private var reduceMotion = false

    /// The figure is built at this side (points) and scaled to the layer's size by its container, so a resize moves
    /// the scale only: the lights are not built again, and an animation in progress goes on.
    static let referenceSide: CGFloat = 240
    /// The container of the lights: centred in the layer, scaled from `referenceSide` to the layer's side.
    let figureLayer = CALayer()
    /// Whether the layer's contents run down from its top on the screen. The figure's y runs down; on macOS a layer
    /// that is not flipped (its view is not, or it is in a window that is not) gets its y turned over. Decided when the
    /// figure is built. On iPhone the layers always run down.
    private var contentsFlipped = true
    private var discs: [CALayer] = []
    private var glows: [CAGradientLayer] = []
    /// How many times the figure was built: once per configuration, never on a resize.
    public private(set) var buildCount = 0

    public override init() {
        super.init()
        figureLayer.bounds = CGRect(x: 0, y: 0, width: Self.referenceSide, height: Self.referenceSide)
        addSublayer(figureLayer)
        Self.prewarmFigure()
    }

    /// The figure takes about 4 ms to compute (debug): it is computed off the main thread when a layer is made, so the
    /// first layout (on the main thread) finds it ready. Computing it again is never needed: `RaccoonLights.figure` is once.
    private static func prewarmFigure() {
        Task.detached(priority: .utility) { _ = RaccoonLights.figure }
    }

    public override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Sets the colours and the modes the figure is built with. Before the figure exists this only stores them; after,
    /// a change builds the figure again (the flight is shown again: a change of theme or Reduce Motion is rare).
    public func configure(signal: CGColor, cream: CGColor, fullStrength: Bool, reduceMotion: Bool) {
        signalColor = signal
        creamColor = cream
        self.fullStrength = fullStrength
        self.reduceMotion = reduceMotion
        if buildCount > 0 { rebuild() }
    }

    public override func layoutSublayers() {
        super.layoutSublayers()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        figureLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        figureLayer.transform = CATransform3DMakeScale(side / Self.referenceSide, side / Self.referenceSide, 1)
        CATransaction.commit()
        // The figure is built at the first layout with a size, once configured.
        if buildCount == 0, signalColor != nil { build() }
    }

    /// Shows the figure as it is `elapsed` seconds after the assembly began, with the animations removed: a picture of
    /// the middle of the flight (`RaccoonLights.pose`). Reduce Motion has nothing to show: the figure is already whole.
    func show(at elapsed: CFTimeInterval) {
        guard buildCount > 0, !reduceMotion else { return }
        let figure = RaccoonLights.figure
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (disc, light) in zip(discs, figure.lights) {
            let pose = RaccoonLights.pose(of: light, at: elapsed)
            let progress = RaccoonLights.progress(of: light, at: elapsed)
            disc.removeAnimation(forKey: "assemble")
            disc.position = CGPoint(x: CGFloat(pose.x) * Self.referenceSide, y: layerY(pose.y))
            disc.opacity = Float(fullStrength ? progress : pose.alpha)
        }
        for glow in glows {
            glow.removeAllAnimations()
            glow.opacity = Float(RaccoonLights.eyeGlow(at: elapsed))
        }
        CATransaction.commit()
    }

    /// The container's y of a point of the figure (`fraction` of the side, y down): as it is when the contents run down,
    /// turned over when they run up.
    private func layerY(_ fraction: Double) -> CGFloat {
        let y = CGFloat(fraction) * Self.referenceSide
        return contentsFlipped ? y : Self.referenceSide - y
    }

    /// A point as the animation's value: `NSValue` on both platforms, with the initialiser each one has.
    private static func value(_ point: CGPoint) -> NSValue {
        #if os(macOS)
        NSValue(point: point)
        #else
        NSValue(cgPoint: point)
        #endif
    }

    private func rebuild() {
        figureLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        discs = []
        glows = []
        build()
    }

    private func build() {
        guard let signal = signalColor, let cream = creamColor else { return }
        buildCount += 1
        #if os(macOS)
        contentsFlipped = contentsAreFlipped()
        #endif
        let now = convertTime(CACurrentMediaTime(), from: nil)
        let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let figure = RaccoonLights.figure
        let side = Self.referenceSide

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for light in figure.lights {
            let disc = CALayer()
            let diameter = CGFloat(light.diameter) * side
            disc.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            disc.cornerRadius = diameter / 2
            disc.backgroundColor = light.tone == .signal ? signal : cream
            let rest = CGPoint(x: CGFloat(light.x) * side, y: layerY(light.y))
            disc.position = rest
            let alpha = fullStrength ? 1 : light.alpha
            disc.opacity = Float(alpha)
            if !reduceMotion {
                let start = CGPoint(x: CGFloat(light.startX) * side, y: layerY(light.startY))
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = Self.value(start)
                move.toValue = Self.value(rest)
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = alpha
                let group = CAAnimationGroup()
                group.animations = [move, fade]
                group.duration = light.duration
                group.beginTime = now + light.delay
                group.fillMode = .backwards
                group.timingFunction = curve
                disc.add(group, forKey: "assemble")
            }
            figureLayer.addSublayer(disc)
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
            glow.position = CGPoint(x: CGFloat(eye.x) * side, y: layerY(eye.y))
            if reduceMotion {
                glow.opacity = 0.8
            } else {
                glow.opacity = 0
                let lit = CABasicAnimation(keyPath: "opacity")
                lit.fromValue = 0
                lit.toValue = 0.8
                lit.duration = 0.5
                lit.beginTime = now + 1.0
                // Held at 0.8 after it ends, until the breathing starts: the eyes do not go dark in between.
                lit.fillMode = .both
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
            figureLayer.addSublayer(glow)
            glows.append(glow)
        }
        CATransaction.commit()
    }
}
