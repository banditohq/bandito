import SwiftUI

// The raccoon avatar's geometry and tile colors, shared by the Mac app (`RaccoonAvatar` and its Core Animation motion
// in BanditoUI) and the iPhone app. Pure SwiftUI shapes and values: nothing here knows AppKit or UIKit. The motion
// itself (layers, timing of the moods) lives next to the platform views that draw it.

/// The avatar tile colors. Fixed brand colors, the same in light and dark themes: they do not follow theme tokens.
public enum AvatarTile {
    public static let peach = srgb(0xFFB067)
    public static let sky = srgb(0xA3BDEB)
    public static let sage = srgb(0xA9C7A2)
    public static let rose = srgb(0xF2A093)
    public static let lilac = srgb(0xC8B6E8)
    public static let cream = srgb(0xF3EBDD)
    /// Raccoon mask on every avatar: fixed #12100E, same in light and dark.
    public static let mask = srgb(0x12100E)

    private static func srgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

/// Tile color of an avatar.
public enum AvatarColor: String, CaseIterable, Sendable {
    case peach, sky, sage, rose, lilac, cream

    /// Fill of the avatar tile.
    public var color: Color {
        switch self {
        case .peach: AvatarTile.peach
        case .sky: AvatarTile.sky
        case .sage: AvatarTile.sage
        case .rose: AvatarTile.rose
        case .lilac: AvatarTile.lilac
        case .cream: AvatarTile.cream
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

/// Color and face of an avatar after automatic choices are applied. Never contains `.auto`.
public struct ResolvedAvatar: Equatable, Sendable {
    public let color: AvatarColor
    public let face: AvatarFace

    public init(color: AvatarColor, face: AvatarFace) {
        self.color = color
        self.face = face
    }
}

public enum AvatarResolver {
    public static func resolve(name: String, color: AvatarColor?, face: AvatarFace) -> ResolvedAvatar {
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
public func stableNameHash(_ name: String) -> UInt64 {
    name.unicodeScalars.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1.value) }
}

// MARK: - Geometry

/// Maps the 52×52 design grid of the raccoon mockups onto a rect.
public struct DesignGrid: Sendable {
    public static let edge: CGFloat = 52

    public let rect: CGRect

    public init(rect: CGRect) {
        self.rect = rect
    }

    public var scale: CGFloat { rect.width / Self.edge }

    public func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }
}

/// Mask: `M8 22c6-6 30-6 36 0v7c-6 4-30 4-36 0z`.
public struct RaccoonMask: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
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
public struct RaccoonFaceStrokes: Shape {
    public let face: AvatarFace

    public init(face: AvatarFace) {
        self.face = face
    }

    public func path(in rect: CGRect) -> Path {
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
public struct RaccoonFaceDots: Shape {
    public let face: AvatarFace

    public init(face: AvatarFace) {
        self.face = face
    }

    public func path(in rect: CGRect) -> Path {
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
public struct RaccoonDashEyes: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let grid = DesignGrid(rect: rect)
        var path = Path()
        path.move(to: grid.point(15, 26.5))
        path.addLine(to: grid.point(21, 26.5))
        path.move(to: grid.point(31, 26.5))
        path.addLine(to: grid.point(37, 26.5))
        return path
    }
}

/// One frame of a raccoon avatar drawn from a pose: the tile, the mask, the eyes, and the marks of a thinking or a
/// sleeping one. Pose offsets are in the 52-point design grid. The Core Animation motion (`AvatarMotion` on Mac, the
/// iPhone's layer view) moves the same parts from the same shapes.
public struct RaccoonFace: View {
    public let resolved: ResolvedAvatar
    public let tint: Color
    public let pose: AvatarPose
    public let size: CGFloat

    public init(resolved: ResolvedAvatar, tint: Color, pose: AvatarPose, size: CGFloat) {
        self.resolved = resolved
        self.tint = tint
        self.pose = pose
        self.size = size
    }

    public var body: some View {
        let unit = size / DesignGrid.edge
        let strokeWidth = size * 2.4 / DesignGrid.edge
        ZStack {
            ZStack {
                RoundedRectangle(cornerRadius: size * 17 / DesignGrid.edge, style: .continuous)
                    .fill(tint)
                RaccoonMask()
                    .fill(AvatarTile.mask)
                eyes(tint: tint, strokeWidth: strokeWidth, unit: unit)
            }
            .offset(x: pose.shakeX * unit, y: pose.bodyOffsetY * unit)
            .opacity(pose.opacity)

            AvatarMarks(pose: pose, tint: tint, size: size)
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
}

/// Where an avatar rests or runs. Pure, so the rules are tested alone.
public enum AvatarSleepPolicy {
    /// Whether an avatar asks for no frames: its motion is off, it is scrolled out of view, or it sleeps in a window that
    /// is not the active one (nobody sees the "z" rise).
    public static func paused(mood: AvatarMood, still: Bool, onScreen: Bool, windowActive: Bool) -> Bool {
        still || !onScreen || (mood == .sleeping && !windowActive)
    }
}

/// The dots of a thinking avatar and the rising "z" of a sleeping one, drawn over the tile from a pose. Shared by the
/// raccoon and by the tiles of avatars that are a picture or an emoji.
public struct AvatarMarks: View {
    public let pose: AvatarPose
    public let tint: Color
    public let size: CGFloat

    public init(pose: AvatarPose, tint: Color, size: CGFloat) {
        self.pose = pose
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        let unit = size / DesignGrid.edge
        ZStack {
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
                        .font(BanditoFont.text(size: size * (index == 0 ? 0.3 : 0.24), weight: 700))
                        .foregroundStyle(Color.Bandito.info)
                        .opacity(Self.zOpacity(progress))
                        .offset(x: size * 0.36 + size * 0.2 * progress, y: -size * 0.36 - size * 0.42 * progress)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Fades a "z" in, then out again over its progress from 0 to 1.
    public static func zOpacity(_ progress: Double) -> Double {
        if progress < 0.3 { return progress / 0.3 }
        return max(0, 1 - (progress - 0.3) / 0.7)
    }
}
