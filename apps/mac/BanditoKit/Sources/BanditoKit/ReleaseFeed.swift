import Foundation

/// The newest Bandito release on GitHub, for the "update available" banner. The answer is cached for six hours.
public enum ReleaseFeed {
    public static let latestURL = URL(string: "https://api.github.com/repos/banditohq/bandito/releases/latest")!
    public static let cacheLifetime: TimeInterval = 6 * 3600
    /// What the user runs on the server to update Bandito (the same script as the first install).
    public static let installCommand = "curl -fsSL https://bandito.dev/install.sh | sh"

    static let cacheKey = "release.latest.v1"

    public enum FeedError: Error, Equatable {
        case unparsableTag(String)
    }

    private struct Release: Decodable {
        var tagName: String
    }

    private struct Cached: Codable {
        var version: String
        /// Unix milliseconds.
        var fetchedAt: Int64
    }

    /// The version named by the `tag_name` of a GitHub release object.
    public static func latestVersion(from body: Data) throws -> SemanticVersion {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: body)
        guard let version = SemanticVersion(release.tagName) else {
            throw FeedError.unparsableTag(release.tagName)
        }
        return version
    }

    public static func isFresh(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) < cacheLifetime
    }

    /// True when `current` is a version below `latest`. An unknown `current` (such as "dev") offers nothing.
    public static func isUpdateAvailable(current: String, latest: SemanticVersion) -> Bool {
        guard let current = SemanticVersion(current) else { return false }
        return current < latest
    }

    /// The latest version: from the cache while it is fresh, else from GitHub. When GitHub cannot be
    /// reached, the last cached answer is returned, or `nil` if there is none.
    public static func latest(now: Date = Date(), session: URLSession = .shared) async -> SemanticVersion? {
        if let cached = cachedAnswer(), isFresh(fetchedAt: cached.fetchedAt, now: now) {
            return cached.version
        }
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bandito", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let result = try? await session.data(for: request),
            (result.1 as? HTTPURLResponse)?.statusCode == 200,
            let version = try? latestVersion(from: result.0)
        else {
            return cachedAnswer()?.version
        }
        store(version, at: now)
        return version
    }

    private static func cachedAnswer() -> (version: SemanticVersion, fetchedAt: Date)? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
            let cached = try? JSONDecoder().decode(Cached.self, from: data),
            let version = SemanticVersion(cached.version)
        else { return nil }
        return (version, Date(timeIntervalSince1970: TimeInterval(cached.fetchedAt) / 1000))
    }

    private static func store(_ version: SemanticVersion, at date: Date) {
        let cached = Cached(version: version.description, fetchedAt: Int64(date.timeIntervalSince1970 * 1000))
        if let data = try? JSONEncoder().encode(cached) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
