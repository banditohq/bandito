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
    /// The tag of the release that was actually downloaded (`vX.Y.Z`). Nil when GitHub did not name it.
    public var tag: String?
    /// True when `version` was asked for but has no release yet, so the latest release was fetched instead.
    public var fellBackToLatest: Bool

    public init(archive: URL, sums: Data, signatureBase64: String, tag: String?, fellBackToLatest: Bool) {
        self.archive = archive
        self.sums = sums
        self.signatureBase64 = signatureBase64
        self.tag = tag
        self.fellBackToLatest = fellBackToLatest
    }
}

/// Downloads releases from GitHub over https. Redirects are followed only to GitHub's own download hosts.
public struct GitHubReleaseSource: ReleaseSource {
    public static let repository = "banditohq/bandito"
    /// The largest archive accepted by default. The daemon binary is about 20 MB.
    public static let defaultMaxArchiveBytes: Int64 = 200 * 1024 * 1024
    /// The largest `SHA256SUMS` or signature file accepted.
    static let maxTextBytes: Int64 = 1024 * 1024
    /// Bytes written to disk per call: the transfer is read byte by byte, so the buffer keeps writes large.
    static let chunkSize = 64 * 1024
    /// Hosts a download may be redirected to. GitHub serves release assets from the last two.
    static let redirectHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    let session: URLSession
    private let maxArchiveBytes: Int64

    /// - Parameters:
    ///   - session: the session to download with. Default: ephemeral, with a ten-minute limit on a whole transfer.
    ///   - maxArchiveBytes: the largest archive accepted.
    public init(session: URLSession = GitHubReleaseSource.makeSession(), maxArchiveBytes: Int64 = defaultMaxArchiveBytes) {
        self.session = session
        self.maxArchiveBytes = maxArchiveBytes
    }

    /// A session that keeps no cookies or cache, and gives a whole transfer ten minutes (the archive is about 20 MB).
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
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

    /// The release tag named by a GitHub download URL (`.../releases/download/<tag>/<file>`). Nil when the URL names
    /// no tag, or the name is not a version.
    static func tag(inDownload url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "download"), index > 0, parts[index - 1] == "releases",
            index + 1 < parts.count, SemanticVersion(parts[index + 1]) != nil
        else { return nil }
        return parts[index + 1]
    }

    public func fetch(version: String?, asset: String, into directory: URL) async throws -> FetchedRelease {
        let archive = directory.appending(path: asset)
        var outcome = try await download(Self.url(version: version, file: asset), to: archive, limit: maxArchiveBytes)
        var fellBack = false
        if outcome == .missing {
            // The version has no release yet: the latest one is used, and the caller says so.
            guard version != nil else { throw Self.missing(asset) }
            fellBack = true
            outcome = try await download(Self.url(version: nil, file: asset), to: archive, limit: maxArchiveBytes)
        }
        guard case .saved(let tag) = outcome else { throw Self.missing(asset) }

        // Latest is older than this app: its release is still being published, so the app's version is not there yet.
        if fellBack, let tag, let version, let latest = SemanticVersion(tag), let wanted = SemanticVersion(version),
            latest < wanted
        {
            throw InstallError.releaseStillPublishing(tag)
        }

        // The signature files come from the same release as the archive, not from whatever latest is by now.
        let sums = directory.appending(path: "SHA256SUMS")
        let signature = directory.appending(path: "SHA256SUMS.sig")
        let sumsOutcome = try await download(Self.url(version: tag, file: "SHA256SUMS"), to: sums, limit: Self.maxTextBytes)
        let signatureOutcome = try await download(
            Self.url(version: tag, file: "SHA256SUMS.sig"), to: signature, limit: Self.maxTextBytes)
        guard sumsOutcome != .missing, signatureOutcome != .missing else { throw Self.missing("SHA256SUMS") }
        return FetchedRelease(
            archive: archive,
            sums: try Data(contentsOf: sums),
            signatureBase64: String(decoding: try Data(contentsOf: signature), as: UTF8.self),
            tag: tag,
            fellBackToLatest: fellBack)
    }

    private static func missing(_ file: String) -> InstallError {
        .downloadFailed("the release has no \(file)")
    }

    private enum Outcome: Equatable {
        /// GitHub answered 404: there is no such file.
        case missing
        /// The file is in place. `tag` is the release it came from, when GitHub named it.
        case saved(tag: String?)
    }

    /// Streams `url` into `file` in chunks of `chunkSize`. Stops with an error as soon as more than `limit` bytes
    /// arrive, or when the server announces more than that.
    private func download(_ url: URL, to file: URL, limit: Int64) async throws -> Outcome {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let guardDelegate = RedirectGuard()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: guardDelegate)
        } catch {
            throw Self.transferError(error, guardDelegate)
        }
        if guardDelegate.refused { throw Self.refusedRedirect }
        guard let http = response as? HTTPURLResponse else {
            throw InstallError.downloadFailed("no answer from GitHub for \(url.lastPathComponent)")
        }
        if http.statusCode == 404 { return .missing }
        guard http.statusCode == 200 else {
            throw InstallError.downloadFailed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
        }
        guard http.expectedContentLength <= limit else { throw Self.tooLarge(url, limit) }

        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buffer = Data()
        var total: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == Self.chunkSize {
                    total += Int64(buffer.count)
                    guard total <= limit else { throw Self.tooLarge(url, limit) }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            total += Int64(buffer.count)
            guard total <= limit else { throw Self.tooLarge(url, limit) }
            try handle.write(contentsOf: buffer)
        } catch let error as InstallError {
            throw error
        } catch {
            throw Self.transferError(error, guardDelegate)
        }
        let tag = guardDelegate.followedTag ?? Self.tag(inDownload: url)
        return .saved(tag: tag)
    }

    private static let refusedRedirect = InstallError.downloadFailed(
        "a redirect to a host other than GitHub was refused")

    private static func transferError(_ error: Error, _ guardDelegate: RedirectGuard) -> InstallError {
        guardDelegate.refused ? refusedRedirect : .downloadFailed(error.localizedDescription)
    }

    private static func tooLarge(_ url: URL, _ limit: Int64) -> InstallError {
        .downloadFailed("\(url.lastPathComponent) is larger than \(limit) bytes")
    }
}

/// Follows a redirect only where `GitHubReleaseSource.allowsRedirect` says so. Any other redirect cancels the
/// download, and `refused` tells the caller why it failed. The release tag of the redirects is kept too: a
/// `latest/download` URL redirects to `download/<tag>`, which is how the app learns which release it got.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // @unchecked: `wasRefused` and `tags` are guarded by `lock`.
    private let lock = NSLock()
    private var wasRefused = false
    private var tags: [String] = []

    var refused: Bool {
        lock.withLock { wasRefused }
    }

    /// The tag of the last download redirect that was followed, if one named a release.
    var followedTag: String? {
        lock.withLock { tags.last }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let url = request.url, GitHubReleaseSource.allowsRedirect(to: url) {
            if let tag = GitHubReleaseSource.tag(inDownload: url) {
                lock.withLock { tags.append(tag) }
            }
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
