import BanditoDesign
import SwiftUI

// Repeating decorative motion (an avatar's mood, a pulsing ring, a breathing dot, a loading sweep, the typing dots) is
// drawn by Core Animation, not by SwiftUI. A SwiftUI animation, a `repeatForever` or a `TimelineView`, makes the main
// thread update the view graph of its window on every frame: in the main window that was about 5 ms a frame for the
// avatars and dots of the sidebar alone, at rest, all the time they were on screen. A Core Animation layer with a
// repeating animation is moved by the render server; the main thread does nothing until the animation is changed.
//
// The shapes keep their SwiftUI definitions (`RaccoonMask`, `RaccoonFaceStrokes`, …); their paths are handed to shape
// layers, and the poses come from the same pure functions (`AvatarPose.make`), sampled into keyframes.

#if os(macOS)
import AppKit
import QuartzCore

/// Keyframes of a periodic value, sampled from the function that defines it.
enum MotionKeyframes {
    /// Frames per second the curve is sampled at; the render server interpolates between them.
    static let rate: Double = 60

    /// A repeating animation of `keyPath` over one `period`, starting at `start` (seconds, the epoch of `value`).
    static func animation(
        _ keyPath: String, period: Double, start: Double, value: (Double) -> Double
    ) -> CAKeyframeAnimation {
        let count = max(2, Int((period * rate).rounded()))
        let values = (0...count).map { NSNumber(value: value(start + period * Double($0) / Double(count))) }
        return repeating(keyPath, values: values, period: period)
    }

    /// The same for a point (`position`).
    static func points(_ keyPath: String, period: Double, start: Double, value: (Double) -> CGPoint)
        -> CAKeyframeAnimation
    {
        let count = max(2, Int((period * rate).rounded()))
        let values = (0...count).map { NSValue(point: value(start + period * Double($0) / Double(count))) }
        return repeating(keyPath, values: values, period: period)
    }

    private static func repeating(_ keyPath: String, values: [Any], period: Double) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = period
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Seconds now, on the clock `AvatarPose` uses.
    static var now: Double { Date().timeIntervalSinceReferenceDate }
}


/// The view under a layer motion: draws nothing itself, takes no clicks, and says when it is in a window (so the
/// SwiftUI drawing it stands in for can step back; without a window, in a rendered picture, that drawing stays).
class MotionLayerView: NSView {
    /// Called with true when the view is in a window and its layers show, false when it leaves.
    var onShown: ((Bool) -> Void)?
    /// The layer the motion draws in: top-left origin, like SwiftUI paths.
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        root.isGeometryFlipped = true
        root.masksToBounds = false
        layer?.masksToBounds = false
        layer?.addSublayer(root)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        layoutLayers()
        CATransaction.commit()
    }

    /// Places the sublayers of `root` for `bounds`. The motion's own layers override it.
    func layoutLayers() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let shown = window != nil
        if shown { startMotion() }
        // The callback writes view state: not in the middle of an update of the views.
        let callback = onShown
        DispatchQueue.main.async { callback?(shown) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(apply)
        }
        apply(root)
    }

    /// Adds the repeating animations. Animations stay on their layers while the view is out of a window and come back
    /// with it; this is called again after a change of what is drawn.
    func startMotion() {}

    /// A layer without implicit animations: a change of a value shows at once.
    static func still<L: CALayer>(_ layer: L) -> L {
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "transform": NSNull(),
                         "path": NSNull(), "contents": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
        return layer
    }
}

// MARK: - avatar

/// What an avatar's motion draws: the raccoon from its parts, or a tile that is a finished picture (a photo or an
/// emoji), and the mood that moves it.
struct AvatarMotionSpec: Equatable {
    enum Body: Equatable {
        case raccoon(ResolvedAvatar)
        /// A picture of the tile, drawn once (`key` names it: the same key, the same picture).
        case tile(key: String)
    }

    var body: Body
    /// Names the tint (a palette name or a hex value): equal keys, equal colours.
    var tintKey: String
    var size: CGFloat
    var mood: AvatarMood
    var phase: Double
}

/// An avatar whose mood moves: the layers of `AvatarMotionView` in SwiftUI.
struct AvatarMotion: NSViewRepresentable {
    let spec: AvatarMotionSpec
    let tint: Color
    /// The picture of a tile body; nil for the raccoon.
    let picture: CGImage?
    var onShown: (Bool) -> Void

    func makeNSView(context: Context) -> AvatarMotionView {
        let view = AvatarMotionView(frame: NSRect(x: 0, y: 0, width: spec.size, height: spec.size))
        view.onShown = onShown
        view.configure(spec: spec, tint: NSColor(tint).cgColor, picture: picture)
        return view
    }

    func updateNSView(_ view: AvatarMotionView, context: Context) {
        view.onShown = onShown
        view.configure(spec: spec, tint: NSColor(tint).cgColor, picture: picture)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AvatarMotionView, context: Context) -> CGSize? {
        CGSize(width: spec.size, height: spec.size)
    }
}

/// The layers of a moving avatar: the body (tile, mask, eyes) that hops and shakes, the eyes that blink and scan, the
/// dots of a thinking agent, the rising "z" of a sleeping one.
final class AvatarMotionView: MotionLayerView {
    private var spec: AvatarMotionSpec?
    private let body = MotionLayerView.still(CALayer())
    private let tile = MotionLayerView.still(CALayer())
    private let mask = MotionLayerView.still(CAShapeLayer())
    /// Moves the eyes sideways; `eyes` inside it squeezes them.
    private let eyeShift = MotionLayerView.still(CALayer())
    private let eyes = MotionLayerView.still(CALayer())
    private let eyeDots = MotionLayerView.still(CAShapeLayer())
    private let eyeStrokes = MotionLayerView.still(CAShapeLayer())
    private let dots = (0..<3).map { _ in MotionLayerView.still(CAShapeLayer()) }
    private let zs = (0..<2).map { _ in MotionLayerView.still(CATextLayer()) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.addSublayer(body)
        body.addSublayer(tile)
        body.addSublayer(mask)
        body.addSublayer(eyeShift)
        eyeShift.addSublayer(eyes)
        eyes.addSublayer(eyeDots)
        eyes.addSublayer(eyeStrokes)
        dots.forEach(root.addSublayer)
        zs.forEach(root.addSublayer)
    }

    func configure(spec next: AvatarMotionSpec, tint: CGColor, picture: CGImage?) {
        guard next != spec else { return }
        spec = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw(next, tint: tint, picture: picture)
        CATransaction.commit()
        if window != nil { startMotion() }
    }

    override func layoutLayers() {
        guard let spec else { return }
        let rect = CGRect(x: 0, y: 0, width: spec.size, height: spec.size)
        for layer in [body, tile, mask, eyeShift, eyes, eyeDots, eyeStrokes] { layer.frame = rect }
    }

    private func draw(_ spec: AvatarMotionSpec, tint: CGColor, picture: CGImage?) {
        let size = spec.size
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let unit = size / DesignGrid.edge
        let resting = AvatarPose.make(mood: spec.mood, time: MotionKeyframes.now, phase: spec.phase)
        for layer in [body, tile, mask, eyeShift, eyes, eyeDots, eyeStrokes] { layer.frame = rect }
        body.opacity = Float(resting.opacity)
        switch spec.body {
        case .raccoon(let resolved):
            tile.contents = nil
            tile.backgroundColor = tint
            tile.cornerRadius = size * 17 / DesignGrid.edge
            tile.cornerCurve = .continuous
            tile.masksToBounds = true
            mask.isHidden = false
            mask.path = RaccoonMask().path(in: rect).cgPath
            mask.fillColor = NSColor(BanditoPalette.avatarMask).cgColor
            eyeShift.isHidden = false
            let stroke = size * 2.4 / DesignGrid.edge
            if resting.showsDashEyes {
                eyeDots.path = nil
                eyeStrokes.path = RaccoonDashEyes().path(in: rect).cgPath
            } else {
                eyeDots.path = RaccoonFaceDots(face: resolved.face).path(in: rect).cgPath
                eyeStrokes.path = RaccoonFaceStrokes(face: resolved.face).path(in: rect).cgPath
            }
            eyeDots.fillColor = tint
            eyeStrokes.fillColor = nil
            eyeStrokes.strokeColor = tint
            eyeStrokes.lineWidth = stroke
            eyeStrokes.lineCap = .round
            eyeStrokes.lineJoin = .round
        case .tile:
            tile.backgroundColor = nil
            tile.cornerRadius = 0
            tile.masksToBounds = false
            tile.contents = picture
            tile.contentsGravity = .resize
            mask.isHidden = true
            eyeShift.isHidden = true
        }
        // The marks: three dots over the head, two letters "z".
        for (index, dot) in dots.enumerated() {
            let diameter = 2.6 * 2 * unit
            dot.frame = CGRect(
                x: (20 + Double(index) * 6) * unit - diameter / 2, y: 7 * unit - diameter / 2, width: diameter,
                height: diameter)
            dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
            dot.fillColor = tint
            dot.isHidden = !resting.showsDots
            dot.opacity = Float(resting.dotOpacities[index])
        }
        for (index, letter) in zs.enumerated() {
            let fontSize = size * (index == 0 ? 0.3 : 0.24)
            letter.string = "z"
            letter.font = BanditoFont.ctFont(family: BanditoFont.textFamily, size: fontSize, weight: 700)
            letter.fontSize = fontSize
            letter.foregroundColor = NSColor(Color.Bandito.info).cgColor
            letter.alignmentMode = .center
            letter.bounds = CGRect(x: 0, y: 0, width: fontSize * 1.2, height: fontSize * 1.4)
            letter.isHidden = !resting.showsZ
            letter.position = Self.zPoint(progress: resting.zProgresses[index], size: size)
            letter.opacity = Float(AvatarMarks.zOpacity(resting.zProgresses[index]))
        }
        let scale = window?.backingScaleFactor ?? 2
        for layer in [tile, mask, eyeDots, eyeStrokes] + dots + zs as [CALayer] { layer.contentsScale = scale }
    }

    /// Where a "z" is at `progress`: it rises up and to the right from beside the head.
    static func zPoint(progress: Double, size: CGFloat) -> CGPoint {
        CGPoint(x: size / 2 + size * 0.36 + size * 0.2 * progress, y: size / 2 - size * 0.36 - size * 0.42 * progress)
    }

    override func startMotion() {
        guard let spec else { return }
        for layer in [body, eyeShift, eyes] + dots + zs as [CALayer] { layer.removeAllAnimations() }
        let start = MotionKeyframes.now
        let unit = spec.size / DesignGrid.edge
        let mood = spec.mood
        let phase = spec.phase
        func pose(_ time: Double) -> AvatarPose { AvatarPose.make(mood: mood, time: time, phase: phase) }
        switch mood {
        case .idle:
            eyes.add(
                MotionKeyframes.animation("transform.scale.y", period: 5, start: start) { pose($0).eyeScaleY },
                forKey: "mood")
        case .working:
            if case .tile = spec.body {
                body.add(
                    MotionKeyframes.animation("transform.scale", period: 2.4, start: start) {
                        TileMotion.scale(pose($0))
                    }, forKey: "mood")
            } else {
                eyeShift.add(
                    MotionKeyframes.animation("transform.translation.x", period: 2.4, start: start) {
                        pose($0).eyeOffsetX * unit
                    }, forKey: "mood")
            }
        case .needsYou:
            body.add(
                MotionKeyframes.animation("transform.translation.y", period: 2, start: start) {
                    pose($0).bodyOffsetY * unit
                }, forKey: "mood")
        case .thinking:
            eyes.add(
                MotionKeyframes.animation("transform.scale.y", period: 2.6, start: start) { pose($0).eyeScaleY },
                forKey: "mood")
            for (index, dot) in dots.enumerated() {
                dot.add(
                    MotionKeyframes.animation("opacity", period: 1.2, start: start) {
                        pose($0).dotOpacities[index]
                    }, forKey: "mood")
            }
        case .error:
            body.add(
                MotionKeyframes.animation("transform.translation.x", period: 3, start: start) {
                    pose($0).shakeX * unit
                }, forKey: "mood")
        case .sleeping:
            let size = spec.size
            for (index, letter) in zs.enumerated() {
                letter.add(
                    MotionKeyframes.points("position", period: 2.6, start: start) {
                        Self.zPoint(progress: pose($0).zProgresses[index], size: size)
                    }, forKey: "rise")
                letter.add(
                    MotionKeyframes.animation("opacity", period: 2.6, start: start) {
                        AvatarMarks.zOpacity(pose($0).zProgresses[index])
                    }, forKey: "fade")
            }
        }
    }
}

// MARK: - small motions

/// A ring that grows from the dot and fades, again and again (the "needs you" dot).
struct PulseRingMotion: NSViewRepresentable {
    let size: CGFloat
    let color: Color
    var onShown: (Bool) -> Void

    func makeNSView(context: Context) -> PulseRingMotionView {
        let view = PulseRingMotionView(frame: .zero)
        view.onShown = onShown
        view.configure(size: size, color: NSColor(color).cgColor)
        return view
    }

    func updateNSView(_ view: PulseRingMotionView, context: Context) {
        view.onShown = onShown
        view.configure(size: size, color: NSColor(color).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseRingMotionView, context: Context) -> CGSize? {
        CGSize(width: size + 4, height: size + 4)
    }
}

final class PulseRingMotionView: MotionLayerView {
    private let ring = MotionLayerView.still(CAShapeLayer())
    private var size: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.addSublayer(ring)
    }

    func configure(size next: CGFloat, color: CGColor) {
        ring.strokeColor = color
        ring.fillColor = nil
        ring.lineWidth = 2
        guard next != size else { return }
        size = next
        needsLayout = true
    }

    override func layoutLayers() {
        let base = size + 4
        ring.frame = CGRect(x: 0, y: 0, width: base, height: base)
        ring.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: base - 2, height: base - 2), transform: nil)
        ring.opacity = 0.55
    }

    override func startMotion() {
        ring.removeAllAnimations()
        let base = size + 4
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = (size + 14) / max(base, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.8
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "pulse")
    }
}

/// A dot that breathes: swells a quarter and dims, back and forth (a terminal that waits for input).
struct BreathingDotMotion: NSViewRepresentable {
    let size: CGFloat
    let color: Color
    var onShown: (Bool) -> Void

    func makeNSView(context: Context) -> BreathingDotMotionView {
        let view = BreathingDotMotionView(frame: .zero)
        view.onShown = onShown
        view.configure(size: size, color: NSColor(color).cgColor)
        return view
    }

    func updateNSView(_ view: BreathingDotMotionView, context: Context) {
        view.onShown = onShown
        view.configure(size: size, color: NSColor(color).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BreathingDotMotionView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class BreathingDotMotionView: MotionLayerView {
    private let dot = MotionLayerView.still(CAShapeLayer())
    private var size: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.addSublayer(dot)
    }

    func configure(size next: CGFloat, color: CGColor) {
        dot.fillColor = color
        dot.shadowColor = color
        dot.shadowOpacity = 0.7
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        guard next != size else { return }
        size = next
        needsLayout = true
    }

    override func layoutLayers() {
        dot.frame = CGRect(x: 0, y: 0, width: size, height: size)
        dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
    }

    override func startMotion() {
        dot.removeAllAnimations()
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.25
        let dim = CABasicAnimation(keyPath: "opacity")
        dim.fromValue = 1
        dim.toValue = 0.75
        let group = CAAnimationGroup()
        group.animations = [grow, dim]
        group.duration = 1.2
        group.autoreverses = true
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        dot.add(group, forKey: "breath")
    }
}

/// A short bright segment that runs across a thin bar, again and again (a page that loads).
struct SweepMotion: NSViewRepresentable {
    let color: Color
    var onShown: (Bool) -> Void

    func makeNSView(context: Context) -> SweepMotionView {
        let view = SweepMotionView(frame: .zero)
        view.onShown = onShown
        view.configure(color: NSColor(color).cgColor)
        return view
    }

    func updateNSView(_ view: SweepMotionView, context: Context) {
        view.onShown = onShown
        view.configure(color: NSColor(color).cgColor)
    }
}

final class SweepMotionView: MotionLayerView {
    private let segment = MotionLayerView.still(CAGradientLayer())
    private var width: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.masksToBounds = true
        root.addSublayer(segment)
    }

    func configure(color: CGColor) {
        segment.colors = [NSColor.clear.cgColor, color, NSColor.clear.cgColor]
        segment.startPoint = CGPoint(x: 0, y: 0.5)
        segment.endPoint = CGPoint(x: 1, y: 0.5)
    }

    override func layoutLayers() {
        guard bounds.width != width else { return }
        width = bounds.width
        segment.frame = CGRect(x: 0, y: 0, width: width * 0.25, height: bounds.height)
        if window != nil { startMotion() }
    }

    override func startMotion() {
        segment.removeAllAnimations()
        guard width > 0 else { return }
        let run = CABasicAnimation(keyPath: "position.x")
        // From a quarter of the width left of the bar to its right end, as the SwiftUI sweep ran (-0.3 … 1).
        run.fromValue = width * -0.3 + width * 0.125
        run.toValue = width * 1 + width * 0.125
        run.duration = 1.6
        run.repeatCount = .infinity
        run.isRemovedOnCompletion = false
        segment.add(run, forKey: "sweep")
    }
}

/// Three dots that rise and brighten one after another (an agent writes its reply).
struct TypingDotsMotion: NSViewRepresentable {
    let color: Color
    var onShown: (Bool) -> Void

    func makeNSView(context: Context) -> TypingDotsMotionView {
        let view = TypingDotsMotionView(frame: .zero)
        view.onShown = onShown
        view.configure(color: NSColor(color).cgColor)
        return view
    }

    func updateNSView(_ view: TypingDotsMotionView, context: Context) {
        view.onShown = onShown
        view.configure(color: NSColor(color).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TypingDotsMotionView, context: Context) -> CGSize? {
        TypingDotsMotionView.size
    }
}

final class TypingDotsMotionView: MotionLayerView {
    /// Three dots of 6 pt, 4 pt apart.
    static let size = CGSize(width: 26, height: 6)
    private let dots = (0..<3).map { _ in MotionLayerView.still(CAShapeLayer()) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        dots.forEach(root.addSublayer)
    }

    func configure(color: CGColor) {
        for dot in dots { dot.fillColor = color }
    }

    override func layoutLayers() {
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(x: CGFloat(index) * 10, y: 0, width: 6, height: 6)
            dot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 6, height: 6), transform: nil)
        }
    }

    override func startMotion() {
        let start = MotionKeyframes.now
        for (index, dot) in dots.enumerated() {
            dot.removeAllAnimations()
            dot.add(
                MotionKeyframes.animation("opacity", period: 1.2, start: start) {
                    TypingIndicator.opacity(time: $0, index: index, still: false)
                }, forKey: "beat")
            dot.add(
                MotionKeyframes.animation("transform.translation.y", period: 1.2, start: start) {
                    TypingIndicator.lift(time: $0, index: index, still: false)
                }, forKey: "lift")
        }
    }
}
#endif
