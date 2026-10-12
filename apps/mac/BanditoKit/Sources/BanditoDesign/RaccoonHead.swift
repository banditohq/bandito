import CoreGraphics

// The raccoon's head as the brand draws it in brand/logo/bandito-mark-on-dark.svg, the same geometry as the site's hero.
// The head is the file's path, flipped the way the file flips it (`translate(0,2048) scale(1,-1)`), with its ears and
// its open mask. The two eyes are strokes of the logo's eye marks, drawn wider (52 units) so that their lights are
// dense. `sample()` lays one grid of points over the head and over the eyes; the lights are made from those points.
// Everything is in the logo's own units (y down, the viewBox is 360 500 1330 1050).
public enum RaccoonHead {
    /// The logo's viewBox (x, y, width, height), in the logo's units.
    public static let viewBox = CGRect(x: 360, y: 500, width: 1330, height: 1050)

    /// The `d` of the head path in the logo file, untransformed (the flip is applied by `sample()`).
    public static let pathData = "M545 1475 c-16 -5 -29 -20 -33 -37 -3 -9 -6 -41 -7 -62 -3 -62 12 -139 40 -211 l7 -16 -4 -5 c-2 -2 -8 -10 -14 -17 -38 -46 -75 -93 -105 -134 -16 -21 -20 -27 -20 -29 0 -3 2 -7 16 -23 9 -10 29 -33 44 -51 38 -44 60 -69 92 -104 47 -52 63 -68 76 -77 18 -12 76 -39 172 -79 17 -8 48 -21 69 -30 83 -36 106 -44 133 -46 36 -3 58 4 156 46 21 9 52 22 69 30 96 40 154 67 172 79 13 9 29 25 76 77 32 35 54 60 92 104 15 18 35 41 44 51 14 16 16 20 16 23 0 5 -63 88 -125 163 -6 7 -12 15 -14 17 l-4 5 7 16 c28 72 43 149 40 211 -1 21 -4 53 -7 62 -4 15 -14 28 -28 35 -10 5 -22 6 -37 2 -18 -5 -78 -26 -108 -39 -47 -19 -88 -46 -140 -93 -8 -7 -16 -14 -16 -14 -1 0 -8 2 -16 4 -111 32 -220 32 -331 0 -8 -2 -15 -4 -16 -4 0 0 -8 7 -16 14 -52 47 -93 74 -140 93 -29 13 -87 33 -107 39 -11 3 -25 3 -33 0z m55 -91 c23 -8 68 -29 91 -43 21 -12 49 -32 64 -45 l3 -3 -18 -14 c-64 -51 -129 -99 -131 -98 -2 3 -11 36 -17 67 -9 41 -12 70 -12 107 0 26 0 26 3 29 4 4 6 4 17 0z m862 0 c4 -3 4 -3 3 -29 0 -37 -3 -66 -12 -107 -6 -31 -15 -64 -17 -67 -2 -1 -67 47 -131 98 l-18 14 3 3 c15 13 43 33 64 45 30 18 92 46 102 46 2 0 4 -1 6 -3z m-671 -273 c12 -4 11 -4 95 -56 19 -12 43 -27 53 -34 40 -25 48 -31 51 -47 6 -21 -4 -52 -24 -71 -26 -26 -97 -76 -156 -112 -28 -17 -34 -19 -53 -18 -12 0 -16 0 -24 2 -44 12 -104 49 -175 106 -34 27 -65 56 -68 63 -4 7 -2 9 51 53 116 97 129 106 156 113 14 3 82 4 94 1z m550 0 c27 -4 42 -13 125 -82 92 -77 93 -77 89 -85 -3 -7 -34 -36 -68 -63 -71 -57 -131 -94 -175 -106 -8 -2 -12 -2 -23 -2 -20 -1 -26 1 -54 18 -59 36 -130 86 -156 112 -20 19 -30 50 -24 71 3 16 11 22 51 47 10 7 34 22 53 34 90 56 85 53 101 57 8 1 68 1 81 -1z m-264 -329 c21 -5 32 -21 25 -39 -2 -7 -13 -21 -31 -40 -33 -36 -51 -40 -78 -19 -15 12 -46 49 -50 59 -6 16 2 32 21 38 7 2 28 3 69 2 28 0 39 0 44 -1z"

    /// The flip of the head path in the file: y' = 2048 - y.
    static let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2048)

    /// The eyes as the logo draws them: the left chevron (>) and the right dash.
    static let eyeLines: [[CGPoint]] = [
        [CGPoint(x: 736, y: 1036), CGPoint(x: 826, y: 1097), CGPoint(x: 736, y: 1158)],
        [CGPoint(x: 1208, y: 1147), CGPoint(x: 1320, y: 1147)],
    ]
    static let eyeStrokeWidth: CGFloat = 52

    /// The spacing of the grid in the logo's units: about 2000 points over the head and the eyes (2060 at 16).
    public static let gridStep: CGFloat = 16

    /// What the grid found: the head's box (the figure's frame), the points inside the head, and the points inside each
    /// eye with the eye's centre.
    public struct Sample {
        public let box: CGRect
        public let head: [CGPoint]
        public let eyes: [[CGPoint]]
        public let eyeCentres: [CGPoint]
    }

    /// The head's path in the logo's units, or nil if the path data is not one the parser knows.
    static func headPath() -> CGPath? {
        SVGPath.parse(pathData, transform: flip)
    }

    /// The stroked outline of one eye (round caps and joins), as a filled area.
    static func eyePath(_ line: [CGPoint]) -> CGPath? {
        guard let first = line.first else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        for point in line.dropFirst() {
            path.addLine(to: point)
        }
        return path.copy(strokingWithWidth: eyeStrokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    /// The grid over the head's box. A point is in the head (even-odd, as the file fills it), or in an eye's stroke. The
    /// lattice starts half a step before the box, so the points are cell centres.
    public static func sample() -> Sample? {
        guard let head = headPath() else { return nil }
        let eyePaths = eyeLines.compactMap { eyePath($0) }
        guard eyePaths.count == eyeLines.count else { return nil }
        let box = head.boundingBoxOfPath
        let step = gridStep

        var headPoints: [CGPoint] = []
        var eyePoints = Array(repeating: [CGPoint](), count: eyeLines.count)
        var y = box.minY - step / 2
        while y <= box.maxY + step {
            var x = box.minX - step / 2
            while x <= box.maxX + step {
                let point = CGPoint(x: x, y: y)
                if head.contains(point, using: .evenOdd) {
                    headPoints.append(point)
                } else if let eye = eyePaths.firstIndex(where: { $0.contains(point, using: .winding) }) {
                    eyePoints[eye].append(point)
                }
                x += step
            }
            y += step
        }
        let centres = eyePaths.map { CGPoint(x: $0.boundingBoxOfPath.midX, y: $0.boundingBoxOfPath.midY) }
        return Sample(box: box, head: headPoints, eyes: eyePoints, eyeCentres: centres)
    }
}

/// The subset of SVG path data the logo uses: M, L, C and Z, absolute and relative, with implicit repeats. Any other
/// command, or a malformed number, gives nil; the logo's data is a constant, so a test checks that it parses.
enum SVGPath {
    private enum Token {
        case command(Character)
        case number(Double)
    }

    static func parse(_ data: String, transform: CGAffineTransform = .identity) -> CGPath? {
        guard let tokens = tokenize(data) else { return nil }
        let path = CGMutablePath()
        var index = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        func number() -> Double? {
            guard index < tokens.count, case let .number(value) = tokens[index] else { return nil }
            index += 1
            return value
        }

        while index < tokens.count {
            if case let .command(letter) = tokens[index] {
                command = letter
                index += 1
                if command == "Z" || command == "z" {
                    path.closeSubpath()
                    current = subpathStart
                    continue
                }
            }
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            switch command.uppercased() {
            case "M", "L":
                guard let x = number(), let y = number() else { return nil }
                let point = CGPoint(x: origin.x + x, y: origin.y + y)
                if command.uppercased() == "M" {
                    path.move(to: point.applying(transform))
                    subpathStart = point
                    command = relative ? "l" : "L"
                } else {
                    path.addLine(to: point.applying(transform))
                }
                current = point
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return nil }
                let end = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addCurve(
                    to: end.applying(transform),
                    control1: CGPoint(x: origin.x + x1, y: origin.y + y1).applying(transform),
                    control2: CGPoint(x: origin.x + x2, y: origin.y + y2).applying(transform))
                current = end
            default:
                return nil
            }
        }
        return path
    }

    private static func tokenize(_ data: String) -> [Token]? {
        let bytes = Array(data.utf8)
        var tokens: [Token] = []
        var i = 0
        func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 32 || byte == 44 || byte == 9 || byte == 10 || byte == 13 {
                i += 1
            } else if (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) {
                tokens.append(.command(Character(UnicodeScalar(byte))))
                i += 1
            } else {
                let start = i
                if byte == 43 || byte == 45 { i += 1 }
                var digits = false
                while i < bytes.count, isDigit(bytes[i]) { i += 1; digits = true }
                if i < bytes.count, bytes[i] == 46 {
                    i += 1
                    while i < bytes.count, isDigit(bytes[i]) { i += 1; digits = true }
                }
                guard digits, let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)) else { return nil }
                tokens.append(.number(value))
            }
        }
        return tokens
    }
}
