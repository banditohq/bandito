import Observation
import SwiftUI

/// What the performance scenarios ask of views that keep a choice to themselves (the icon view of Files, the open
/// metric of the Server overview), where a person would click. Only the smoothness check's demo window carries one (see
/// `PerfCheck`); in the app's own windows it is nil and the views ignore it.
@MainActor
@Observable
final class ScenarioRequests {
    /// The layout the folder browser switches to.
    var filesLayout: FileLayout?
    /// The metric whose detail the Server overview opens; nil closes it.
    var overviewMetric: OverviewMetric?
}

extension EnvironmentValues {
    /// The requests of the performance scenarios, in the smoothness check's demo window only.
    @Entry var scenarioRequests: ScenarioRequests?
}
