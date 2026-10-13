import BanditoDesign
import QuartzCore
import SwiftUI
import UIKit

// A raccoon avatar on iPhone. Its geometry is the shared `RaccoonFace` / `RaccoonMask` in BanditoDesign; its moods are
// Core Animation layers (`RaccoonMotionView`), never a SwiftUI repeating animation: the render server moves them, the
// main thread does nothing until a value changes. With Reduce Motion the avatar stands still in its rest pose.

/// A raccoon avatar with its mood. Decorative: the agent's name is always shown next to it.
struct CrewAvatar: View {
    let name: String
    let look: CrewLook
    let mood: AvatarMood
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let resolved = ResolvedAvatar(color: look.color, face: look.face)
        let phase = AvatarPose.phase(for: name)
        ZStack {
            if reduceMotion {
                RaccoonFace(
                    resolved: resolved, tint: look.tint,
                    pose: AvatarPose.make(mood: mood, time: 0, phase: phase, reduceMotion: true), size: size)
            } else {
                RaccoonMotion(
                    spec: RaccoonMotionSpec(
                        resolved: resolved, tint: UIColor(look.tint), mood: mood, phase: phase, size: size))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// What the layers of one avatar draw: equal specs draw equal pictures, so an unchanged avatar is not drawn again.
struct RaccoonMotionSpec: Equatable {
    let resolved: ResolvedAvatar
    /// The tile color (a custom one or the palette's), as UIKit has it.
    let tint: UIColor
    let mood: AvatarMood
    let phase: Double
    let size: CGFloat

    static func == (lhs: RaccoonMotionSpec, rhs: RaccoonMotionSpec) -> Bool {
        lhs.resolved == rhs.resolved && lhs.tint.isEqual(rhs.tint) && lhs.mood == rhs.mood && lhs.phase == rhs.phase
            && lhs.size == rhs.size
    }
}

/// The moving raccoon: a SwiftUI wrapper around `RaccoonMotionView`.
struct RaccoonMotion: UIViewRepresentable {
    let spec: RaccoonMotionSpec

    func makeUIView(context: Context) -> RaccoonMotionView {
        let view = RaccoonMotionView()
        view.configure(spec)
        return view
    }

    func updateUIView(_ view: RaccoonMotionView, context: Context) {
        view.configure(spec)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RaccoonMotionView, context: Context) -> CGSize? {
        CGSize(width: spec.size, height: spec.size)
    }
}

/// The layers of a moving raccoon: the body (tile, mask, eyes) that hops and shakes, the eyes that blink and scan, the
/// dots of a thinking agent and the rising "z" of a sleeping one. The moods' timing is `AvatarPose`, sampled into
/// keyframes by `MotionKeyframes`, as on the Mac.
final class RaccoonMotionView: UIView {
    private var spec: RaccoonMotionSpec?
    private let body = CALayer()
    private let tile = CALayer()
    private let maskLayer = CAShapeLayer()
    /// Moves the eyes sideways; `eyes` inside it squeezes them.
    private let eyeShift = CALayer()
    private let eyes = CALayer()
    private let eyeDots = CAShapeLayer()
    private let eyeStrokes = CAShapeLayer()
    private let dots = (0..<3).map { _ in CAShapeLayer() }
    private let zs = (0..<2).map { _ in CATextLayer() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = false
        layer.addSublayer(body)
        body.addSublayer(tile)
        body.addSublayer(maskLayer)
        body.addSublayer(eyeShift)
        eyeShift.addSublayer(eyes)
        eyes.addSublayer(eyeDots)
        eyes.addSublayer(eyeStrokes)
        dots.forEach(layer.addSublayer)
        zs.forEach(layer.addSublayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Draws `next` and starts its mood. Equal specs change nothing.
    func configure(_ next: RaccoonMotionSpec) {
        guard next != spec else { return }
        spec = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draw(next)
        CATransaction.commit()
        restartMotion()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The layers are drawn at the screen's scale; they are set again when the view gets a window.
        let scale = window?.screen.scale ?? 3
        applyScale(scale, to: layer)
        restartMotion()
    }

    private func applyScale(_ scale: CGFloat, to root: CALayer) {
        root.contentsScale = scale
        root.sublayers?.forEach { applyScale(scale, to: $0) }
    }

    private func draw(_ spec: RaccoonMotionSpec) {
        let size = spec.size
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let unit = size / DesignGrid.edge
        let tint = spec.tint.cgColor
        // The rest pose (open eyes, no hop); the animations move from it.
        let resting = AvatarPose.make(mood: spec.mood, time: MotionKeyframes.now, phase: spec.phase, reduceMotion: true)
        for layer in [body, tile, maskLayer, eyeShift, eyes, eyeDots, eyeStrokes] as [CALayer] { layer.frame = rect }
        body.opacity = Float(resting.opacity)

        tile.backgroundColor = tint
        tile.cornerRadius = size * 17 / DesignGrid.edge
        tile.cornerCurve = .continuous
        tile.masksToBounds = true

        maskLayer.path = RaccoonMask().path(in: rect).cgPath
        maskLayer.fillColor = UIColor(AvatarTile.mask).cgColor

        let stroke = size * 2.4 / DesignGrid.edge
        if resting.showsDashEyes {
            eyeDots.path = nil
            eyeStrokes.path = RaccoonDashEyes().path(in: rect).cgPath
        } else {
            eyeDots.path = RaccoonFaceDots(face: spec.resolved.face).path(in: rect).cgPath
            eyeStrokes.path = RaccoonFaceStrokes(face: spec.resolved.face).path(in: rect).cgPath
        }
        eyeDots.fillColor = tint
        eyeStrokes.fillColor = nil
        eyeStrokes.strokeColor = tint
        eyeStrokes.lineWidth = stroke
        eyeStrokes.lineCap = .round
        eyeStrokes.lineJoin = .round

        // The marks: three dots over the head, two letters "z".
        let diameter = 2.6 * 2 * unit
        for (index, dot) in dots.enumerated() {
            dot.frame = CGRect(
                x: (20 + Double(index) * 6) * unit - diameter / 2, y: 7 * unit - diameter / 2,
                width: diameter, height: diameter)
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
            letter.foregroundColor = UIColor(Color.Bandito.info).cgColor
            letter.alignmentMode = .center
            letter.bounds = CGRect(x: 0, y: 0, width: fontSize * 1.2, height: fontSize * 1.4)
            // A sleeping avatar's "z" exist at rest too, faded out: the animation shows them.
            letter.isHidden = spec.mood != .sleeping
            letter.position = Self.zPoint(progress: 0, size: size)
            letter.opacity = 0
        }
        applyScale(window?.screen.scale ?? 3, to: layer)
    }

    /// Where a "z" is at `progress`: it rises up and to the right from beside the head.
    static func zPoint(progress: Double, size: CGFloat) -> CGPoint {
        CGPoint(x: size / 2 + size * 0.36 + size * 0.2 * progress, y: size / 2 - size * 0.36 - size * 0.42 * progress)
    }

    private func stopMotion() {
        for layer in [body, eyeShift, eyes] + dots + zs as [CALayer] { layer.removeAllAnimations() }
    }

    /// Adds the mood's repeating animations; none while the view is out of a window (nobody sees them).
    private func restartMotion() {
        stopMotion()
        guard let spec, window != nil else { return }
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
            eyeShift.add(
                MotionKeyframes.animation("transform.translation.x", period: 2.4, start: start) {
                    pose($0).eyeOffsetX * unit
                }, forKey: "mood")
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

/// A ring that grows from a needs-you avatar and fades, again and again: the signal pulse of a waiting agent. A Core
/// Animation layer, like the avatar's mood. Nothing is drawn with Reduce Motion (the caller does not show it).
struct PulseRing: UIViewRepresentable {
    let size: CGFloat
    let color: UIColor

    func makeUIView(context: Context) -> PulseRingView {
        let view = PulseRingView()
        view.configure(size: size, color: color)
        return view
    }

    func updateUIView(_ view: PulseRingView, context: Context) {
        view.configure(size: size, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PulseRingView, context: Context) -> CGSize? {
        CGSize(width: size + 4, height: size + 4)
    }
}

final class PulseRingView: UIView {
    private let ring = CAShapeLayer()
    private var size: CGFloat = 0
    private var color: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(size next: CGFloat, color nextColor: UIColor) {
        guard next != size || !nextColor.isEqual(color) else { return }
        size = next
        color = nextColor
        let base = next + 4
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = CGRect(x: 0, y: 0, width: base, height: base)
        ring.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: base - 2, height: base - 2), transform: nil)
        ring.strokeColor = nextColor.cgColor
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.opacity = 0
        CATransaction.commit()
        restart()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    private func restart() {
        ring.removeAllAnimations()
        guard size > 0, window != nil else { return }
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
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "pulse")
    }
}
