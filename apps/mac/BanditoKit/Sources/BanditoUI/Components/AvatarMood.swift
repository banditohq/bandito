import BanditoKit
import Foundation

/// Expression of a raccoon avatar. It shows an agent's state without words; see docs/design/Avatars.dc.html.
public enum AvatarMood: CaseIterable, Sendable {
    /// Rests and blinks now and then, each agent on its own rhythm.
    case idle
    /// Eyes scan left and right while the agent works.
    case working
    /// Hops every two seconds. The loudest state: the agent is waiting for a person.
    case needsYou
    /// Squints and shows three dots while the reply is written.
    case thinking
    /// Shakes once every three seconds and waits.
    case error
    /// Dash eyes, faded, with a rising "z": not running or offline.
    case sleeping

    /// Mood for an agent with `status`. A streamed reply reads as thinking, a running turn of an idle agent too.
    /// Waiting for a person and errors always win.
    /// A paused agent sleeps whatever it was doing: the pause interrupted its turn.
    public static func make(
        status: AgentStatus, turnRunning: Bool = false, streaming: Bool = false, paused: Bool = false
    ) -> AvatarMood {
        if paused { return .sleeping }
        return switch status {
        case .needsYou: .needsYou
        case .error: .error
        case .offline: .sleeping
        case .working: streaming ? .thinking : .working
        case .idle: (turnRunning || streaming) ? .thinking : .idle
        }
    }
}

/// What one avatar draws at one moment. Offsets are in the 52-point design grid of the raccoon.
/// Pure and deterministic, so the timing of every mood can be tested without rendering.
public struct AvatarPose: Equatable, Sendable {
    /// Vertical scale of the eyes around the eye line: 1 open, about 0.12 at a blink.
    public var eyeScaleY: Double = 1
    /// Horizontal shift of the eyes (scanning while working).
    public var eyeOffsetX: Double = 0
    /// Vertical shift of the whole body: negative is up (the hop).
    public var bodyOffsetY: Double = 0
    /// Horizontal shake of the whole body (error).
    public var shakeX: Double = 0
    public var opacity: Double = 1
    /// Two short horizontal strokes instead of eyes (sleeping).
    public var showsDashEyes = false
    /// Three dots above the head (thinking).
    public var showsDots = false
    /// Opacity of each of the three dots, 0 to 1.
    public var dotOpacities: [Double] = [0.25, 0.25, 0.25]
    /// Rising "z" letters (sleeping).
    public var showsZ = false
    /// Progress of each of the two "z" letters, 0 to 1.
    public var zProgresses: [Double] = [0, 0]

    /// Pose of `mood` at `time` (seconds, any epoch). `phase` shifts the rhythm so agents do not move in unison.
    /// With Reduce Motion every mood is drawn at rest: open eyes, no movement, static marks only.
    public static func make(mood: AvatarMood, time: Double, phase: Double, reduceMotion: Bool = false) -> AvatarPose {
        var pose = AvatarPose()
        pose.opacity = mood == .sleeping ? 0.75 : 1
        pose.showsDashEyes = mood == .sleeping
        pose.showsDots = mood == .thinking
        if reduceMotion { return pose }

        switch mood {
        case .idle:
            pose.eyeScaleY = interpolate(cycle(time, phase, period: 5), blink)
        case .working:
            pose.eyeOffsetX = 3 * sin(2 * .pi * (time + phase) / 2.4)
        case .needsYou:
            pose.bodyOffsetY = interpolate(cycle(time, phase, period: 2), hop)
        case .thinking:
            pose.eyeScaleY = interpolate(cycle(time, phase, period: 2.6), squint)
            pose.dotOpacities = (0..<3).map { index in
                interpolate(cycle(time, phase + Double(index) * 0.2, period: 1.2), dotPulse)
            }
        case .error:
            pose.shakeX = interpolate(cycle(time, phase, period: 3), shake)
        case .sleeping:
            pose.showsZ = true
            pose.zProgresses = [
                cycle(time, phase, period: 2.6),
                cycle(time, phase + 1.3, period: 2.6),
            ]
        }
        return pose
    }

    /// Seconds offset of an agent's rhythm, 0 to 5, from a stable hash of its name.
    public static func phase(for name: String) -> Double {
        Double(stableNameHash(name) % 5000) / 1000
    }

    // MARK: keyframes (fraction of the cycle → value)

    private static let blink: [(Double, Double)] = [(0, 1), (0.93, 1), (0.96, 0.12), (1, 1)]
    private static let squint: [(Double, Double)] = [(0, 1), (0.4, 0.45), (0.7, 0.45), (1, 1)]
    private static let hop: [(Double, Double)] = [(0, 0), (0.6, 0), (0.7, -6), (0.8, 0), (0.86, -2), (1, 0)]
    private static let shake: [(Double, Double)] = [
        (0, 0), (0.7, 0), (0.74, -4), (0.78, 4), (0.82, -3), (0.86, 2), (1, 0),
    ]
    private static let dotPulse: [(Double, Double)] = [(0, 0.25), (0.4, 1), (0.8, 0.25), (1, 0.25)]

    /// Position in a cycle of `period` seconds, 0 to 1, with `phase` added.
    private static func cycle(_ time: Double, _ phase: Double, period: Double) -> Double {
        let t = (time + phase).truncatingRemainder(dividingBy: period)
        return (t < 0 ? t + period : t) / period
    }

    /// Linear interpolation between keyframes sorted by their first value; the last value holds after the end.
    private static func interpolate(_ x: Double, _ points: [(Double, Double)]) -> Double {
        for index in 1..<points.count {
            let (x0, y0) = points[index - 1]
            let (x1, y1) = points[index]
            if x <= x1 {
                let k = x1 == x0 ? 1 : (x - x0) / (x1 - x0)
                return y0 + (y1 - y0) * k
            }
        }
        return points[points.count - 1].1
    }
}
