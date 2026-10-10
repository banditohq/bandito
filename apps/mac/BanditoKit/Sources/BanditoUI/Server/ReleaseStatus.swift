import BanditoKit
import Observation

/// The newest Bandito release, for the "update available" hints. Loaded from GitHub or the six-hour cache.
@MainActor
@Observable
final class ReleaseStatus {
    private(set) var latest: SemanticVersion?
    /// True once a load has finished, whether or not it found a release. Before that, "unknown" means "not yet".
    private(set) var checked = false

    func load() async {
        latest = await ReleaseFeed.latest()
        checked = true
    }

    /// True when the server runs a version below the newest release.
    func updateAvailable(current: String?) -> Bool {
        guard let latest, let current else { return false }
        return ReleaseFeed.isUpdateAvailable(current: current, latest: latest)
    }
}
