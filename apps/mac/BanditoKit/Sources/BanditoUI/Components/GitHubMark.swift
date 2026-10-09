import SwiftUI

/// The GitHub mark as a shape: the Octicon `mark-github` (MIT, GitHub Primer), drawn in the frame it is given.
/// The path is parsed once; SVG arcs are turned into cubic curves so SwiftUI can draw them.
struct GitHubMark: Shape {
    /// Octicons `mark-github`, 16 × 16.
    static let svgPath = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"

    /// The path in its own 16 × 16 frame, parsed once for all uses.
    private static let unitPath: Path = {
        var parser = SVGPathParser(svgPath)
        return parser.parse()
    }()

    func path(in rect: CGRect) -> Path {
        let scale = CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return Self.unitPath.applying(scale)
    }
}

/// Reads the subset of SVG path syntax the marks use: M L H V C S A Z, absolute and relative, with implicit repeats.
/// Arc flags are single characters, so the scanner reads them one by one.
struct SVGPathParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    mutating func parse() -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var command: UInt8 = 0

        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            if isLetter(bytes[index]) {
                command = bytes[index]
                index += 1
            } else if command == 0 || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                break
            }
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            let upper = relative ? command - 32 : command

            switch upper {
            case UInt8(ascii: "M"):
                guard let point = readPoint() else { return path }
                let target = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
                path.move(to: target)
                current = target
                subpathStart = target
                lastCubicControl = nil
                // Further pairs after a move are line segments.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "L"):
                guard let point = readPoint() else { return path }
                current = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
                path.addLine(to: current)
                lastCubicControl = nil
            case UInt8(ascii: "H"):
                guard let x = readNumber() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
            case UInt8(ascii: "V"):
                guard let y = readNumber() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastCubicControl = nil
            case UInt8(ascii: "C"):
                guard let c1 = readPoint(), let c2 = readPoint(), let end = readPoint() else { return path }
                let control1 = CGPoint(x: origin.x + c1.x, y: origin.y + c1.y)
                let control2 = CGPoint(x: origin.x + c2.x, y: origin.y + c2.y)
                current = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
                path.addCurve(to: current, control1: control1, control2: control2)
                lastCubicControl = control2
            case UInt8(ascii: "S"):
                guard let c2 = readPoint(), let end = readPoint() else { return path }
                let control1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let control2 = CGPoint(x: origin.x + c2.x, y: origin.y + c2.y)
                current = CGPoint(x: origin.x + end.x, y: origin.y + end.y)
                path.addCurve(to: current, control1: control1, control2: control2)
                lastCubicControl = control2
            case UInt8(ascii: "A"):
                guard let rx = readNumber(), let ry = readNumber(), let rotation = readNumber(),
                    let largeArc = readFlag(), let sweep = readFlag(), let point = readPoint()
                else { return path }
                let target = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
                Self.addArc(
                    to: &path, from: current, rx: rx, ry: ry, rotationDegrees: rotation,
                    largeArc: largeArc, sweep: sweep, to: target)
                current = target
                lastCubicControl = nil
            case UInt8(ascii: "Z"):
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                command = 0
            default:
                return path
            }
        }
        return path
    }

    // MARK: - Scanning

    private mutating func skipSeparators() {
        while index < bytes.count, [32, 9, 10, 13, 44].contains(bytes[index]) {
            index += 1
        }
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
    }

    private mutating func readPoint() -> CGPoint? {
        guard let x = readNumber(), let y = readNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }

    private mutating func readFlag() -> Bool? {
        skipSeparators()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else {
            return nil
        }
        defer { index += 1 }
        return bytes[index] == UInt8(ascii: "1")
    }

    /// One number: optional sign, digits, at most one decimal point. A second sign or point starts the next number.
    private mutating func readNumber() -> Double? {
        skipSeparators()
        let start = index
        var sawDot = false
        var sawDigit = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                sawDigit = true
            } else if byte == UInt8(ascii: ".") && !sawDot {
                sawDot = true
            } else {
                break
            }
            index += 1
        }
        guard sawDigit else {
            index = start
            return nil
        }
        return Double(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    // MARK: - Arcs

    /// An SVG elliptical arc (endpoint form) as cubic curves, one per quarter turn at most.
    static func addArc(
        to path: inout Path, from start: CGPoint, rx rxIn: Double, ry ryIn: Double, rotationDegrees: Double,
        largeArc: Bool, sweep: Bool, to end: CGPoint
    ) {
        guard start != end else { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        guard rx > 0, ry > 0 else {
            path.addLine(to: end)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coefficient = denominator == 0 ? 0 : (max(0, numerator / denominator)).squareRoot()
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1 / ry
        let cyp = -coefficient * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        let ux = (x1 - cxp) / rx
        let uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx
        let vy = (-y1 - cyp) / ry
        let theta = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func point(_ a: Double) -> CGPoint {
            CGPoint(
                x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: Double) -> CGPoint {
            CGPoint(
                x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        for segment in 0..<segments {
            let a1 = theta + Double(segment) * step
            let a2 = a1 + step
            let p1 = point(a1)
            let p2 = point(a2)
            let d1 = derivative(a1)
            let d2 = derivative(a2)
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y),
                control2: CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y))
        }
    }
}
