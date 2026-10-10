import BanditoDesign
import BanditoKit
import SwiftUI

/// Tile color of an avatar. Fixed brand colors, the same in light and dark themes.
public enum AvatarColor: String, CaseIterable, Sendable {
    case peach, sky, sage, rose, lilac, cream

    /// Fill of the avatar tile.
    public var color: Color {
        switch self {
        case .peach: BanditoPalette.avatarPeach
        case .sky: BanditoPalette.avatarSky
        case .sage: BanditoPalette.avatarSage
        case .rose: BanditoPalette.avatarRose
        case .lilac: BanditoPalette.avatarLilac
        case .cream: BanditoPalette.avatarCream
        }
    }
}

/// Face drawn on the raccoon mask, in the avatar color.
public enum AvatarFace: String, CaseIterable, Sendable {
    /// Picked from the name hash together with the color.
    case auto
    /// `> –`: a chevron eye and a dash.
    case chevronDash
    /// `• •`: two dots.
    case dots
    /// `^ ^`: two carets above the eyes.
    case carets
    /// One eye closed in a smile, the other a dot.
    case wink
    /// Two open rings: a surprised look.
    case surprised
    /// Dash eyes: asleep.
    case sleeping
    /// Two rings with a bridge and dot pupils.
    case glasses
    /// Two closed smiling eyes (`∪ ∪`).
    case happy
    /// Dots under straight brows.
    case serious
}

/// Raccoon avatar: a rounded tile in an agent color, the dark mask and a face on it.
/// Without explicit `color` / `face`, both come from a stable hash of `name`.
/// `mood` animates the face (blinking, scanning, hopping…); with Reduce Motion it stays at rest.
public struct RaccoonAvatar: View {
    public let name: String
    public let color: AvatarColor?
    public let face: AvatarFace
    public let size: CGFloat
    public let mood: AvatarMood
    /// A custom tile color as `#RRGGBB`, used instead of `color` when it is valid.
    public let customHex: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.avatarSleepRests) private var sleepRests
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// Repeating motion stands still: Reduce Motion, or "Less" / "Off" in settings. A sleeping avatar also rests where
    /// a list shows many of them (`avatarSleepRests`).
    private var still: Bool {
        reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion
            || AvatarSleepPolicy.rests(mood: mood, listed: sleepRests)
    }
    /// No frames are asked for while the window is not the active one: nobody sees the "z" rise.
    private var paused: Bool { still || AvatarSleepPolicy.pausesWhenInactive(mood: mood, active: scenePhase == .active) }

    /// - Parameters:
    ///   - name: Agent name; also the seed for the automatic color and face and for the rhythm.
    ///   - color: Tile color, or `nil` to derive it from `name`.
    ///   - face: Face on the mask, or `.auto` to derive it from `name`.
    ///   - size: Edge of the square tile in points.
    ///   - mood: Expression; `.idle` blinks.
    ///   - customHex: Tile color as `#RRGGBB`; wins over `color` when valid.
    public init(
        name: String, color: AvatarColor? = nil, face: AvatarFace = .auto, size: CGFloat = 40,
        mood: AvatarMood = .idle, customHex: String? = nil
    ) {
        self.name = name
        self.color = color
        self.face = face
        self.size = size
        self.mood = mood
        self.customHex = customHex
    }

    public var body: some View {
        let resolved = AvatarResolver.resolve(name: name, color: color, face: face)
        let tint = customHex.flatMap(AvatarHex.value).map { Color(hex: $0) } ?? resolved.color.color
        let phase = AvatarPose.phase(for: name)
        TimelineView(AvatarSchedule(mood: mood, phase: phase, paused: paused)) { context in
            let pose = AvatarPose.make(
                mood: mood, time: context.date.timeIntervalSinceReferenceDate, phase: phase,
                reduceMotion: still)
            RaccoonFace(resolved: resolved, tint: tint, pose: pose, size: size)
        }
        .frame(width: size, height: size)
        // Decorative: the agent name is always shown next to the avatar.
        .accessibilityHidden(true)
    }
}

/// One frame of a raccoon avatar drawn from a pose. Pose offsets are in the 52-point design grid.
private struct RaccoonFace: View {
    let resolved: ResolvedAvatar
    let tint: Color
    let pose: AvatarPose
    let size: CGFloat

    var body: some View {
        let unit = size / DesignGrid.edge
        let strokeWidth = size * 2.4 / DesignGrid.edge
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: size * 17 / DesignGrid.edge, style: .continuous)
                    .fill(tint)
                RaccoonMask()
                    .fill(BanditoPalette.avatarMask)
                eyes(tint: tint, strokeWidth: strokeWidth, unit: unit)
            }
            .offset(x: pose.shakeX * unit, y: pose.bodyOffsetY * unit)
            .opacity(pose.opacity)

            if pose.showsDots {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(tint)
                        .frame(width: 2.6 * 2 * unit, height: 2.6 * 2 * unit)
                        .opacity(pose.dotOpacities[index])
                        .position(x: (20 + Double(index) * 6) * unit, y: 7 * unit)
                }
            }
            if pose.showsZ {
                ForEach(0..<2, id: \.self) { index in
                    let progress = pose.zProgresses[index]
                    Text("z")
                        .font(BanditoFont.font(size: size * (index == 0 ? 0.3 : 0.24), weight: 700))
                        .foregroundStyle(Color.Bandito.info)
                        .opacity(zOpacity(progress))
                        .offset(x: size * 0.36 + size * 0.2 * progress, y: -size * 0.36 - size * 0.42 * progress)
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func eyes(tint: Color, strokeWidth: CGFloat, unit: CGFloat) -> some View {
        if pose.showsDashEyes {
            RaccoonDashEyes()
                .stroke(tint, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        } else {
            Group {
                RaccoonFaceDots(face: resolved.face).fill(tint)
                RaccoonFaceStrokes(face: resolved.face)
                    .stroke(tint, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            }
            .scaleEffect(x: 1, y: pose.eyeScaleY, anchor: .center)
            .offset(x: pose.eyeOffsetX * unit)
        }
    }

    /// Fades a "z" in, then out again over its progress from 0 to 1.
    private func zOpacity(_ progress: Double) -> Double {
        if progress < 0.3 { return progress / 0.3 }
        return max(0, 1 - (progress - 0.3) / 0.7)
    }
}

/// Agent avatar: `RaccoonAvatar` with color and face derived from the agent name.
public struct AgentAvatar: View {
    /// Agent name; seeds the automatic color and face.
    public var name: String
    /// Edge of the square tile in points.
    public var size: CGFloat
    /// Expression of the face.
    public var mood: AvatarMood

    public init(name: String, size: CGFloat = 40, mood: AvatarMood = .idle) {
        self.name = name
        self.size = size
        self.mood = mood
    }

    public var body: some View {
        RaccoonAvatar(name: name, size: size, mood: mood)
    }
}

// MARK: - Resolution

/// Color and face of an avatar after automatic choices are applied. Never contains `.auto`.
struct ResolvedAvatar: Equatable, Sendable {
    let color: AvatarColor
    let face: AvatarFace
}

enum AvatarResolver {
    static func resolve(name: String, color: AvatarColor?, face: AvatarFace) -> ResolvedAvatar {
        let hash = stableNameHash(name)
        let colors = AvatarColor.allCases
        let faces: [AvatarFace] = [.chevronDash, .dots, .carets]
        let autoColor = colors[Int(hash % UInt64(colors.count))]
        let autoFace = faces[Int((hash / UInt64(colors.count)) % UInt64(faces.count))]
        return ResolvedAvatar(
            color: color ?? autoColor,
            face: face == .auto ? autoFace : face)
    }
}

/// Stable hash of a name: `h = h * 31 + scalar`, wrapping on overflow.
/// Deliberately not `hashValue`, which is seeded per process and would change between launches.
func stableNameHash(_ name: String) -> UInt64 {
    name.unicodeScalars.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1.value) }
}

// MARK: - Geometry

/// Maps the 52×52 design grid of the raccoon mockups onto a rect.
struct DesignGrid {
    static let edge: CGFloat = 52

    let rect: CGRect

    var scale: CGFloat { rect.width / Self.edge }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
}

/// Mask: `M8 22c6-6 30-6 36 0v7c-6 4-30 4-36 0z`.
struct RaccoonMask: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = DesignGrid(rect: rect)
        var path = Path()
        path.move(to: grid.point(8, 22))
        path.addCurve(to: grid.point(44, 22), control1: grid.point(14, 16), control2: grid.point(38, 16))
        path.addLine(to: grid.point(44, 29))
        path.addCurve(to: grid.point(8, 29), control1: grid.point(38, 33), control2: grid.point(14, 33))
        path.closeSubpath()
        return path
    }
}

/// Stroked face parts. `.dots` and `.auto` have none; the dots of a face are `RaccoonFaceDots`.
struct RaccoonFaceStrokes: Shape {
    let face: AvatarFace

    func path(in rect: CGRect) -> Path {
        let grid = DesignGrid(rect: rect)
        var path = Path()
        switch face {
        case .chevronDash:
            // m16 23 4 3-4 3  and  M31 26h6
            path.move(to: grid.point(16, 23))
            path.addLine(to: grid.point(20, 26))
            path.addLine(to: grid.point(16, 29))
            path.move(to: grid.point(31, 26))
            path.addLine(to: grid.point(37, 26))
        case .carets:
            // m15 27 3-3 3 3  and  m31 27 3-3 3 3
            path.move(to: grid.point(15, 27))
            path.addLine(to: grid.point(18, 24))
            path.addLine(to: grid.point(21, 27))
            path.move(to: grid.point(31, 27))
            path.addLine(to: grid.point(34, 24))
            path.addLine(to: grid.point(37, 27))
        case .wink:
            Self.smileArc(grid, centerX: 18, into: &path)
        case .happy:
            Self.smileArc(grid, centerX: 18, into: &path)
            Self.smileArc(grid, centerX: 34, into: &path)
        case .sleeping:
            path.addPath(RaccoonDashEyes().path(in: rect))
        case .surprised:
            Self.ring(grid, centerX: 18, radius: 3.2, into: &path)
            Self.ring(grid, centerX: 34, radius: 3.2, into: &path)
        case .glasses:
            Self.ring(grid, centerX: 18, radius: 4.4, into: &path)
            Self.ring(grid, centerX: 34, radius: 4.4, into: &path)
            path.move(to: grid.point(22.4, 26))
            path.addLine(to: grid.point(29.6, 26))
        case .serious:
            path.move(to: grid.point(15, 21.8))
            path.addLine(to: grid.point(21, 21.8))
            path.move(to: grid.point(31, 21.8))
            path.addLine(to: grid.point(37, 21.8))
        case .auto, .dots:
            break
        }
        return path
    }

    /// A closed smiling eye (`∪`) six points wide, its ends on the eye line.
    private static func smileArc(_ grid: DesignGrid, centerX: CGFloat, into path: inout Path) {
        path.move(to: grid.point(centerX - 3, 25.5))
        path.addQuadCurve(to: grid.point(centerX + 3, 25.5), control: grid.point(centerX, 28.5))
    }

    /// An open eye: a circle of `radius` grid points around the eye line.
    private static func ring(_ grid: DesignGrid, centerX: CGFloat, radius: CGFloat, into path: inout Path) {
        let center = grid.point(centerX, 26)
        let r = radius * grid.scale
        path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }
}

/// Filled eye dots of a face: two for `.dots` and `.serious`, one for `.wink`, small pupils for `.glasses`.
struct RaccoonFaceDots: Shape {
    let face: AvatarFace

    func path(in rect: CGRect) -> Path {
        let grid = DesignGrid(rect: rect)
        let spots: [(x: CGFloat, radius: CGFloat)]
        switch face {
        case .dots, .serious: spots = [(18, 2.6), (34, 2.6)]
        case .wink: spots = [(34, 2.6)]
        case .glasses: spots = [(18, 1.6), (34, 1.6)]
        case .auto, .chevronDash, .carets, .happy, .surprised, .sleeping: spots = []
        }
        var path = Path()
        for spot in spots {
            let center = grid.point(spot.x, 26)
            let radius = spot.radius * grid.scale
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }
}

/// Two short horizontal strokes (`M15 26.5h6` and `M31 26.5h6`) for sleeping avatars.
struct RaccoonDashEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = DesignGrid(rect: rect)
        var path = Path()
        path.move(to: grid.point(15, 26.5))
        path.addLine(to: grid.point(21, 26.5))
        path.move(to: grid.point(31, 26.5))
        path.addLine(to: grid.point(37, 26.5))
        return path
    }
}

/// Where a sleeping avatar rests or runs. Pure, so the rules are tested alone.
enum AvatarSleepPolicy {
    /// A sleeping avatar in a list (the sidebar) is drawn at rest: a list holds many of them, and each rising "z" would
    /// cost a redraw several times a second for a mark nobody looks at.
    static func rests(mood: AvatarMood, listed: Bool) -> Bool {
        mood == .sleeping && listed
    }

    /// A sleeping avatar asks for no frames while its window is not active.
    static func pausesWhenInactive(mood: AvatarMood, active: Bool) -> Bool {
        mood == .sleeping && !active
    }
}

private struct AvatarSleepRestsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a list of agents: sleeping avatars there do not animate.
    var avatarSleepRests: Bool {
        get { self[AvatarSleepRestsKey.self] }
        set { self[AvatarSleepRestsKey.self] = newValue }
    }
}

/// When an avatar needs a new frame: 20 times a second while its mood moves, and not at all in between. An idle
/// raccoon blinks for a third of a second every five seconds, so it is drawn about seven times per blink instead of
/// a hundred times; a row of agents in the sidebar costs next to nothing.
struct AvatarSchedule: TimelineSchedule {
    let mood: AvatarMood
    let phase: Double
    let paused: Bool

    static let frameInterval: TimeInterval = 1.0 / 20
    /// A sleeping avatar moves slowly (a "z" rises in 2.6 s) and is drawn all the time, so it gets fewer frames.
    static let sleepingInterval: TimeInterval = 1.0 / 8

    /// The time between two frames of `mood`.
    static func interval(for mood: AvatarMood) -> TimeInterval {
        mood == .sleeping ? sleepingInterval : frameInterval
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        // Paused, or the system asks for few updates (low power, window hidden): one frame, then nothing.
        if paused || mode == .lowFrequency {
            var done = false
            return AnyIterator {
                if done { return nil }
                done = true
                return startDate
            }
        }
        let window = AvatarPose.activeWindow(for: mood)
        let interval = Self.interval(for: mood)
        var next = startDate
        return AnyIterator {
            let date = next
            next = Self.after(date, window: window, phase: phase, interval: interval)
            return date
        }
    }

    /// The frame after `date`: the next tick inside the moving part of the cycle, or the start of the next one.
    static func after(
        _ date: Date, window: (period: Double, start: Double, end: Double)?, phase: Double,
        interval: TimeInterval = frameInterval
    ) -> Date {
        let tick = date.addingTimeInterval(interval)
        guard let window else { return tick }
        func inside(_ d: Date) -> Bool {
            let p = (d.timeIntervalSinceReferenceDate + phase).truncatingRemainder(dividingBy: window.period) / window.period
            return p >= window.start && p <= window.end
        }
        // Inside the moving part, and the first frame after it (so the pose comes back to rest), are drawn.
        if inside(tick) || inside(date) { return tick }
        let t = tick.timeIntervalSinceReferenceDate + phase
        let position = t.truncatingRemainder(dividingBy: window.period) / window.period
        // Jump to the start of the next moving part (this cycle's, or the next cycle's).
        let cycleStart = t - position * window.period
        var start = cycleStart + window.start * window.period
        if start <= t { start += window.period }
        return Date(timeIntervalSinceReferenceDate: start - phase)
    }
}
