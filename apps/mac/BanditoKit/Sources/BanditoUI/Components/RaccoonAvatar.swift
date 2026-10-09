import BanditoDesign
import SwiftUI

/// Tile color of an avatar. Fixed brand colors, the same in light and dark themes.
public enum AvatarColor: CaseIterable, Sendable {
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
public enum AvatarFace: CaseIterable, Sendable {
    /// Picked from the name hash together with the color.
    case auto
    /// `> –`: a chevron eye and a dash.
    case chevronDash
    /// `• •`: two dots.
    case dots
    /// `^ ^`: two carets above the eyes.
    case carets
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - name: Agent name; also the seed for the automatic color and face and for the rhythm.
    ///   - color: Tile color, or `nil` to derive it from `name`.
    ///   - face: Face on the mask, or `.auto` to derive it from `name`.
    ///   - size: Edge of the square tile in points.
    ///   - mood: Expression; `.idle` blinks.
    public init(
        name: String, color: AvatarColor? = nil, face: AvatarFace = .auto, size: CGFloat = 40,
        mood: AvatarMood = .idle
    ) {
        self.name = name
        self.color = color
        self.face = face
        self.size = size
        self.mood = mood
    }

    public var body: some View {
        let resolved = AvatarResolver.resolve(name: name, color: color, face: face)
        let phase = AvatarPose.phase(for: name)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
            let pose = AvatarPose.make(
                mood: mood, time: context.date.timeIntervalSinceReferenceDate, phase: phase,
                reduceMotion: reduceMotion)
            RaccoonFace(resolved: resolved, pose: pose, size: size)
        }
        .frame(width: size, height: size)
        // Decorative: the agent name is always shown next to the avatar.
        .accessibilityHidden(true)
    }
}

/// One frame of a raccoon avatar drawn from a pose. Pose offsets are in the 52-point design grid.
private struct RaccoonFace: View {
    let resolved: ResolvedAvatar
    let pose: AvatarPose
    let size: CGFloat

    var body: some View {
        let tint = resolved.color.color
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
                switch resolved.face {
                case .dots:
                    RaccoonDots().fill(tint)
                case .chevronDash, .carets:
                    RaccoonFaceStrokes(face: resolved.face)
                        .stroke(tint, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
                case .auto:
                    // The resolver never returns `.auto`; kept for exhaustiveness.
                    EmptyView()
                }
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

/// Stroked face parts for `.chevronDash` and `.carets`. Other faces produce an empty path.
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
        case .auto, .dots:
            break
        }
        return path
    }
}

/// Two filled eye dots (r 2.6 at x 18 and 34, y 26) for `.dots`.
struct RaccoonDots: Shape {
    func path(in rect: CGRect) -> Path {
        let grid = DesignGrid(rect: rect)
        let radius = 2.6 * grid.scale
        var path = Path()
        for x in [CGFloat(18), CGFloat(34)] {
            let center = grid.point(x, 26)
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
