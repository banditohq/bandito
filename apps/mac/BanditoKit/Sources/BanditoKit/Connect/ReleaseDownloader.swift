import Foundation

/// Where a release comes from. The installer depends only on this, so tests substitute a fake.
public protocol ReleaseSource: Sendable {
    /// Writes the archive `asset`, `SHA256SUMS` and `SHA256SUMS.sig` of release `version` (`vX.Y.Z`, or the latest
    /// release when nil) into `directory`.
    func fetch(version: String?, asset: String, into directory: URL) async throws -> FetchedRelease
}

/// The files of one release, downloaded to this Mac.
public struct FetchedRelease: Sendable, Equatable {
    /// The archive: a file in the directory that was passed to `fetch`.
    public var archive: URL
    /// The content of `SHA256SUMS`.
    public var sums: Data
    /// The content of `SHA256SUMS.sig`: base64 of the raw Ed25519 signature.
    public var signatureBase64: String
    /// True when `version` was asked for but has no release yet, so the latest release was fetched instead.
    public var fellBackToLatest: Bool

    public init(archive: URL, sums: Data, signatureBase64: String, fellBackToLatest: Bool) {
        self.archive = archive
        self.sums = sums
        self.signatureBase64 = signatureBase64
        self.fellBackToLatest = fellBackToLatest
    }
}

/// Downloads releases from GitHub over https. Redirects are followed only to GitHub's own download hosts.
public struct GitHubReleaseSource: ReleaseSource {
    public static let repository = "banditohq/bandito"
    /// The largest archive accepted. The daemon binary is about 20 MB.
    public static let maxArchiveBytes: Int64 = 200 * 1024 * 1024
    /// The largest `SHA256SUMS` or signature file accepted.
    static let maxTextBytes: Int64 = 1024 * 1024
    /// Hosts a download may be redirected to. GitHub serves release assets from the last two.
    static let redirectHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    /// The release tag of an app version: `0.1.0` and `v0.1.0` both give `v0.1.0`. Nil when the text is no version.
    public static func tag(forAppVersion text: String) -> String? {
        SemanticVersion(text).map { "v\($0)" }
    }

    /// `https://github.com/banditohq/bandito/releases/download/<tag>/<file>`, or `.../releases/latest/download/<file>`
    /// when `version` is nil.
    public static func url(version: String?, file: String) -> URL {
        let path = version.map { "download/\($0)" } ?? "latest/download"
        guard let url = URL(string: "https://github.com/\(repository)/releases/\(path)/\(file)") else {
            preconditionFailure("not a release URL: \(file)")
        }
        return url
    }

    /// True for an https URL on one of GitHub's download hosts, on the default port, without credentials.
    public static func allowsRedirect(to url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), redirectHosts.contains(host),
            url.user == nil, url.password == nil, url.port == nil || url.port == 443
        else { return false }
        return true
    }

    public func fetch(version: String?, asset: String, into directory: URL) async throws -> FetchedRelease {
        let archive = directory.appending(path: asset)
        var tag = version
        var fellBack = false
        let found = try await download(Self.url(version: version, file: asset), to: archive, limit: Self.maxArchiveBytes)
        if !found {
            // The version has no release yet: the latest one is used, and the caller says so.
            guard version != nil else { throw Self.missing(asset) }
            fellBack = true
            tag = nil
            let latest = try await download(Self.url(version: nil, file: asset), to: archive, limit: Self.maxArchiveBytes)
            guard latest else { throw Self.missing(asset) }
        }

        let sums = directory.appending(path: "SHA256SUMS")
        let signature = directory.appending(path: "SHA256SUMS.sig")
        let sumsFound = try await download(Self.url(version: tag, file: "SHA256SUMS"), to: sums, limit: Self.maxTextBytes)
        let signatureFound = try await download(
            Self.url(version: tag, file: "SHA256SUMS.sig"), to: signature, limit: Self.maxTextBytes)
        guard sumsFound, signatureFound else { throw Self.missing("SHA256SUMS") }
        return FetchedRelease(
            archive: archive,
            sums: try Data(contentsOf: sums),
            signatureBase64: String(decoding: try Data(contentsOf: signature), as: UTF8.self),
            fellBackToLatest: fellBack)
    }

    private static func missing(_ file: String) -> InstallError {
        .downloadFailed("the release has no \(file)")
    }

    /// Downloads `url` into `file`. Returns false when GitHub answers 404; other failures throw.
    private func download(_ url: URL, to file: URL, limit: Int64) async throws -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let guardDelegate = RedirectGuard()
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: guardDelegate)
        } catch {
            if guardDelegate.refused {
                throw InstallError.downloadFailed("a redirect to a host other than GitHub was refused")
            }
            throw InstallError.downloadFailed(error.localizedDescription)
        }
        // Drops the temporary copy when it was not moved (for example, on a 404).
        defer { try? FileManager.default.removeItem(at: temporary) }

        guard let http = response as? HTTPURLResponse else {
            throw InstallError.downloadFailed("no answer from GitHub for \(url.lastPathComponent)")
        }
        if http.statusCode == 404 { return false }
        guard http.statusCode == 200 else {
            throw InstallError.downloadFailed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        // The transfer has finished when this is known: the limit bounds what is kept, not what is read.
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= limit, http.expectedContentLength <= limit else {
            throw InstallError.downloadFailed("\(url.lastPathComponent) is larger than \(limit) bytes")
        }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
        return true
    }
}

/// Follows a redirect only where `GitHubReleaseSource.allowsRedirect` says so. Any other redirect cancels the
/// download, and `refused` tells the caller why it failed.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // @unchecked: `wasRefused` is guarded by `lock`.
    private let lock = NSLock()
    private var wasRefused = false

    var refused: Bool {
        lock.withLock { wasRefused }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url, GitHubReleaseSource.allowsRedirect(to: url) {
            completionHandler(request)
            return
        }
        lock.withLock { wasRefused = true }
        task.cancel()
        completionHandler(nil)
    }
}

/// The release asset of a server, named as scripts/install.sh names it: `bandito-<arch>-<os>.tar.gz`.
public enum ReleaseAsset {
    /// `uname -sm` of a server (`Linux x86_64`, `Darwin arm64`). Nil when no build covers it.
    public static func name(unameSM: String) -> String? {
        let parts = unameSM.split(separator: " ")
        guard parts.count == 2 else { return nil }
        return name(kernel: String(parts[0]), machine: String(parts[1]))
    }

    /// `kernel` as `uname -s` says it, `machine` as `uname -m` says it (`arm64` and `amd64` are accepted too).
    public static func name(kernel: String, machine: String) -> String? {
        let arch: String
        switch machine {
        case "x86_64", "amd64": arch = "x86_64"
        case "aarch64", "arm64": arch = "aarch64"
        default: return nil
        }
        switch kernel {
        case "Linux": return "bandito-\(arch)-unknown-linux-gnu.tar.gz"
        case "Darwin": return "bandito-\(arch)-apple-darwin.tar.gz"
        default: return nil
        }
    }
}
