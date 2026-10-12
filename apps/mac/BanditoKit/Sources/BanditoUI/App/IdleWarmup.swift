import AppKit
import BanditoDesign
import BanditoL10n
import Charts
import CoreGraphics
import SwiftUI

/// Work the app does once, offscreen, while nobody is using it shortly after launch, so that the first opening of a
/// screen does not pay for it. Nothing is shown: each step draws a view into an image that is thrown away.
///
/// The first chart of the app (a metric's detail on the Server page) cost more than the next ones: Swift Charts builds
/// its types, scales and axis text on first use (20 ms on a fast Mac, three times that without a GPU). Drawn here
/// first, the detail opens at its usual cost.
@MainActor
public enum IdleWarmup {
    /// How long after launch the warm-up starts at the earliest.
    static let delay: Duration = .seconds(2)
    /// No keyboard, mouse or trackpad input for this long counts as idle.
    static let quietSeconds: Double = 1

    private static var started = false
    /// The next step to run; all are done when it reaches `steps.count`.
    private static var next = 0

    /// The steps, in order. Each is one offscreen drawing.
    static let steps: [@MainActor () -> Void] = [ChartsWarmup.run]

    /// Starts the warm-up once; later calls do nothing. Called by the app when its window is up.
    public static func start() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            while next < steps.count {
                if secondsSinceInput() < quietSeconds {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                runNext()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Runs what is left of the warm-up now, without waiting for a quiet moment. The smoothness check calls it before
    /// it measures, so a step never lands inside a measured stretch.
    public static func finishNow() {
        started = true
        while next < steps.count { runNext() }
    }

    private static func runNext() {
        let step = steps[next]
        next += 1
        step()
    }

    /// Seconds since the last keyboard, mouse, trackpad or scroll input anywhere in the session.
    private static func secondsSinceInput() -> Double {
        let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .leftMouseDragged]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }
}

/// Draws the metric chart of the Server page once, offscreen (`IdleWarmup`).
@MainActor
enum ChartsWarmup {
    static func run() {
        let now = Date()
        func samples(_ series: [String]) -> [MetricChart.Sample] {
            (0..<120).map { index in
                MetricChart.Sample(
                    id: index, date: now.addingTimeInterval(Double(index / series.count - 60) * 60),
                    value: Double((index * 37) % 100), series: series[index % series.count])
            }
        }
        let cpu = [OverviewMetric.cpu.title]
        let network = [L10n.Server.Detail.download, L10n.Server.Detail.upload]
        // One line without a legend (CPU, memory) and two with one (network): the two kinds of detail.
        let chart = VStack {
            MetricChart(
                metric: .cpu, samples: samples(cpu), names: [(cpu[0], Color.Bandito.ok)], yScale: 1,
                yDomain: 0...100, yTicks: .automatic(desiredCount: 4), range: .hour, selected: .constant(nil))
            MetricChart(
                metric: .network, samples: samples(network),
                names: [(network[0], Color.Bandito.info), (network[1], Color.Bandito.signal)], yScale: 1,
                yDomain: 0...100, yTicks: .automatic(desiredCount: 4), range: .hour, selected: .constant(nil))
        }
        .frame(width: 488)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: chart)
        renderer.scale = 1
        _ = renderer.cgImage
    }
}
