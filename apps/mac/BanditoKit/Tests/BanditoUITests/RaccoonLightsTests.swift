import CoreGraphics
import QuartzCore
import Testing

@testable import BanditoDesign

/// The figure of lights (BanditoDesign, shared by iPhone and Mac): the logo's head and its eyes, the places of the
/// lights, the timing of the flight, and the layer that shows it.
@Suite struct RaccoonLightsTests {
    private let lights = RaccoonLights.figure.lights

    @Test func theFigureHasAboutTwoThousandLights() {
        #expect((1500...2500).contains(lights.count), "got \(lights.count)")
    }

    @Test func theFigureIsTheSameEveryTime() {
        #expect(RaccoonLights.make() == RaccoonLights.figure)
    }

    @Test func theHeadPathParsesAndSitsInTheLogo() throws {
        #expect(SVGPath.parse(RaccoonHead.pathData) != nil, "the logo's head path is one the parser knows")
        #expect(SVGPath.parse("M0 0 X1 1") == nil, "a command the logo does not use is refused")
        let square = try #require(SVGPath.parse("M0 0 L10 0 L10 10 Z")).boundingBoxOfPath
        #expect(square.width == 10 && square.height == 10)
        let sample = try #require(RaccoonHead.sample())
        #expect(RaccoonHead.viewBox.contains(sample.box), "the head is inside the logo's viewBox")
    }

    @Test func lightsRestInsideTheSquareAndStartOnARing() {
        for light in lights {
            #expect((0...1).contains(light.x) && (0...1).contains(light.y))
            #expect(light.diameter > 0 && light.diameter < 0.05)
            let distance = hypot(light.startX - 0.5, light.startY - 0.5)
            #expect(distance >= 0.459 && distance <= 0.621, "lights start on a ring around the figure")
        }
    }

    @Test func theEyesAreTwoGroupsOfLights() {
        let figure = RaccoonLights.figure
        #expect(figure.eyeCentres.count == 2)
        for eye in figure.eyeCentres {
            let near = lights.filter { $0.region == .eye && hypot($0.x - eye.x, $0.y - eye.y) < 0.06 }
            #expect(near.count >= 10, "each eye has its own lights, got \(near.count)")
        }
        #expect(lights.contains { $0.region == .fur })
    }

    @Test func everyFlightEndsInsideTheAssembly() {
        for light in lights {
            #expect(light.delay >= 0)
            #expect(light.delay + light.duration <= RaccoonLights.assemblyDuration + 1e-9)
            #expect(light.alpha > 0 && light.alpha <= 1)
        }
    }

    @Test func eyesArriveAfterTheFigure() {
        let figureLast = lights.filter { $0.region != .eye }.map(\.delay).max() ?? 0
        let eyesFirst = lights.filter { $0.region == .eye }.map(\.delay).min() ?? 0
        #expect(eyesFirst > figureLast)
    }

    @Test func theNoiseStaysInRange() {
        for seed in 0..<1000 {
            let value = RaccoonLights.noise(seed, 3)
            #expect(value >= 0 && value < 1)
        }
    }

    /// The picture of the flight: at 0.5 s the lights are where the flight puts them (not yet at their rests), and at
    /// the end of the assembly every light is at its rest.
    @Test func showingAMomentPlacesTheLightsOnTheirFlight() {
        let layer = RaccoonLightsLayer()
        layer.signalColor = CGColor(red: 1, green: 0.5, blue: 0.2, alpha: 1)
        layer.creamColor = CGColor(red: 1, green: 0.95, blue: 0.87, alpha: 1)
        layer.bounds = CGRect(x: 0, y: 0, width: 280, height: 280)
        layer.layoutIfNeeded()
        let discs = Array((layer.sublayers ?? []).prefix(lights.count))
        #expect(discs.count == lights.count, "one layer per light")

        func distanceToRest(_ disc: CALayer, _ light: RaccoonLight) -> CGFloat {
            hypot(disc.position.x - CGFloat(light.x) * 280, disc.position.y - CGFloat(light.y) * 280)
        }
        layer.show(at: 0.5)
        let onTheWay = zip(discs, lights).filter { distanceToRest($0.0, $0.1) > 1 }
        #expect(!onTheWay.isEmpty, "some lights are still on their way at 0.5 s")

        layer.show(at: 2.4)
        let unsettled = zip(discs, lights).filter { distanceToRest($0.0, $0.1) > 0.01 }
        #expect(unsettled.isEmpty, "every light is at its rest after the assembly")
    }

    @Test func theCurveStartsAndEndsAtTheRest() {
        #expect(abs(RaccoonLights.flightCurve(0)) < 1e-9)
        #expect(abs(RaccoonLights.flightCurve(1) - 1) < 1e-9)
        #expect(RaccoonLights.flightCurve(0.5) > 0.5, "a fast start: ease-out")
        #expect(RaccoonLights.eyeGlow(at: 0.5) == 0)
        #expect(abs(RaccoonLights.eyeGlow(at: 1.49) - 0.8) < 0.05, "the glow is lit by 1.5 s")
    }
}
