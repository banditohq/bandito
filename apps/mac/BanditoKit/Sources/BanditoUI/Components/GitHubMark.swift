import SwiftUI

/// The GitHub mark: Octicons `mark-github` at 16 x 16 (MIT, GitHub Inc.), drawn as a shape so it takes the
/// foreground colour of the button it sits in.
public struct GitHubMark: Shape {
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.minX, y: rect.minY)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        path.move(to: p(6.766, 11.328))
        path.addCurve(to: p(3.25, 7.672), control1: p(4.703, 11.078), control2: p(3.25, 9.594))
        path.addCurve(to: p(4, 5.484), control1: p(3.25, 6.891), control2: p(3.531, 6.047))
        path.addCurve(to: p(4.063, 3.422), control1: p(3.797, 4.969), control2: p(3.828, 3.875))
        path.addCurve(to: p(6.031, 4.125), control1: p(4.688, 3.344), control2: p(5.531, 3.672))
        path.addCurve(to: p(8.016, 3.844), control1: p(6.625, 3.938), control2: p(7.25, 3.844))
        path.addCurve(to: p(9.969, 4.109), control1: p(8.781, 3.844), control2: p(9.406, 3.938))
        path.addCurve(to: p(11.938, 3.422), control1: p(10.453, 3.672), control2: p(11.313, 3.344))
        path.addCurve(to: p(11.984, 5.469), control1: p(12.156, 3.844), control2: p(12.188, 4.937))
        path.addCurve(to: p(12.75, 7.672), control1: p(12.484, 6.062), control2: p(12.75, 6.859))
        path.addCurve(to: p(9.203, 11.312), control1: p(12.75, 9.594), control2: p(11.297, 11.047))
        path.addCurve(to: p(10.093, 13.266), control1: p(9.734, 11.656), control2: p(10.093, 12.406))
        path.addLine(to: p(10.093, 14.891))
        path.addCurve(to: p(10.953, 15.438), control1: p(10.093, 15.359), control2: p(10.484, 15.625))
        path.addCurve(to: p(16, 8.03), control1: p(13.781, 14.359), control2: p(16, 11.53))
        path.addCurve(to: p(7.984, 0), control1: p(16, 3.61), control2: p(12.406, 0))
        path.addCurve(to: p(0, 8.031), control1: p(3.563, 0), control2: p(0, 3.61))
        path.addCurve(to: p(5.172, 15.453), control1: p(-0.009, 11.347), control2: p(2.058, 14.314))
        path.addCurve(to: p(6, 14.906), control1: p(5.594, 15.609), control2: p(6, 15.328))
        path.addLine(to: p(6, 13.656))
        path.addCurve(to: p(5.25, 13.812), control1: p(5.781, 13.75), control2: p(5.5, 13.812))
        path.addCurve(to: p(3.172, 12.203), control1: p(4.219, 13.812), control2: p(3.61, 13.25))
        path.addCurve(to: p(2.453, 11.484), control1: p(3, 11.781), control2: p(2.812, 11.531))
        path.addCurve(to: p(2.203, 11.297), control1: p(2.266, 11.469), control2: p(2.203, 11.391))
        path.addCurve(to: p(2.828, 10.969), control1: p(2.203, 11.109), control2: p(2.516, 10.969))
        path.addCurve(to: p(4.078, 11.829), control1: p(3.281, 10.969), control2: p(3.672, 11.25))
        path.addCurve(to: p(5.109, 12.484), control1: p(4.391, 12.281), control2: p(4.718, 12.484))
        path.addCurve(to: p(6.109, 11.984), control1: p(5.5, 12.484), control2: p(5.75, 12.344))
        path.addCurve(to: p(6.766, 11.328), control1: p(6.375, 11.719), control2: p(6.579, 11.484))
        return path
    }
}
