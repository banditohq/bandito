import BanditoDesign
import SwiftUI

/// Tile color of an avatar. Each case maps to a brand token (or `BanditoPalette` when no token
/// exists). The dark-theme values are identical to the mockup colors; in the light theme the
/// tokens switch to their light variants, so tiles follow the theme.
public enum AvatarColor: CaseIterable, Sendable {
    case peach, sky, sage, rose, lilac, cream

    /// Fill of the avatar tile.
    public var color: Color {
        switch self {
        case .peach: BanditoPalette.peach
        case .sky: Color.Bandito.info
        case .sage: Color.Bandito.ok
        case .rose: Color.Bandito.danger
        case .lilac: BanditoPalette.lilac
        case .cream: Color.Bandito.text
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
public struct RaccoonAvatar: View {
    public let name: String
    public let color: AvatarColor?
    public let face: AvatarFace
    public let size: CGFloat

    /// - Parameters:
    ///   - name: Agent name; also the seed for the automatic color and face.
    ///   - color: Tile color, or `nil` to derive it from `name`.
    ///   - face: Face on the mask, or `.auto` to derive it from `name`.
    ///   - size: Edge of the square tile in points.
    public init(name: String, color: AvatarColor? = nil, face: AvatarFace = .auto, size: CGFloat = 40) {
        self.name = name
        self.color = color
        self.face = face
        self.size = size
    }

    public var body: some View {
        let resolved = AvatarResolver.resolve(name: name, color: color, face: face)
        let tint = resolved.color.color
        let strokeWidth = size * 2.4 / DesignGrid.edge
        ZStack {
            RoundedRectangle(cornerRadius: size * 17 / DesignGrid.edge, style: .continuous)
                .fill(tint)
            RaccoonMask()
                .fill(Color.Bandito.bg)
            switch resolved.face {
            case .dots:
                RaccoonDots()
                    .fill(tint)
            case .chevronDash, .carets:
                RaccoonFaceStrokes(face: resolved.face)
                    .stroke(tint, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
            case .auto:
                // The resolver never returns `.auto`; kept for exhaustiveness.
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        // Decorative: the agent name is always shown next to the avatar.
        .accessibilityHidden(true)
    }
}

/// Agent avatar: `RaccoonAvatar` with color and face derived from the agent name.
public struct AgentAvatar: View {
    /// Agent name; seeds the automatic color and face.
    public var name: String
    /// Edge of the square tile in points.
    public var size: CGFloat

    public init(name: String, size: CGFloat = 40) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        RaccoonAvatar(name: name, size: size)
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
