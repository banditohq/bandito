import Foundation
import Testing

@testable import BanditoKit

/// Answers requests from a table, so `GitHubReleaseSource` runs without a network. The table is shared by the
/// suite, which runs one test after another.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// A redirect to this address. The body is then ignored.
        var location: String?
    }

    final class Table: @unchecked Sendable {
        // @unchecked: `replies` is guarded by `lock`.
        static let shared = Table()
        private let lock = NSLock()
        private var replies: [String: Reply] = [:]

        func install(_ table: [String: Reply]) {
            lock.withLock { replies = table }
        }

        func reply(for url: String) -> Reply? {
            lock.withLock { replies[url] }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let reply = Table.shared.reply(for: url.absoluteString) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        var headers = reply.headers
        if let location = reply.location {
            headers["Location"] = location
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        if let location = reply.location, let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct GitHubReleaseSourceTests {
    private let asset = TestRelease.asset
    private let archive = TestRelease.archive
    private let release = TestRelease()

    private func stubbedSource(maxArchiveBytes: Int64 = GitHubReleaseSource.defaultMaxArchiveBytes) -> GitHubReleaseSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return GitHubReleaseSource(session: URLSession(configuration: configuration), maxArchiveBytes: maxArchiveBytes)
    }

    private func download(_ tag: String, _ file: String) -> String {
        "https://github.com/banditohq/bandito/releases/download/\(tag)/\(file)"
    }

    private func latest(_ file: String) -> String {
        "https://github.com/banditohq/bandito/releases/latest/download/\(file)"
    }

    private func cdn(_ file: String) -> String {
        "https://objects.githubusercontent.com/github-production-release-asset/\(file)"
    }

    /// Replies for a published release: each file's download URL redirects to a CDN host that serves the bytes.
    private func published(_ tag: String, archive: Data? = nil, sums: Data? = nil) throws -> [String: StubURLProtocol.Reply] {
        let files = [
            (asset, archive ?? self.archive),
            ("SHA256SUMS", sums ?? release.sums),
            ("SHA256SUMS.sig", Data(release.signatureFile.utf8)),
        ]
        var table: [String: StubURLProtocol.Reply] = [:]
        for (name, bytes) in files {
            table[download(tag, name)] = .init(status: 302, location: cdn(name))
            table[cdn(name)] = .init(headers: ["Content-Length": "\(bytes.count)"], body: bytes)
        }
        return table
    }

    /// The latest download of the asset redirects to the release `tag`, as GitHub does.
    private func latestArchive(_ tag: String) -> [String: StubURLProtocol.Reply] {
        [latest(asset): .init(status: 302, location: download(tag, asset))]
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "github-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The error a fetch ends with, or nil when it succeeds.
    private func fetchError(_ source: GitHubReleaseSource, version: String?) async throws -> InstallError? {
        do {
            _ = try await source.fetch(version: version, asset: asset, into: try directory())
            return nil
        } catch let error as InstallError {
            return error
        }
    }

    @Test func aPublishedVersionIsDownloadedWithItsTag() async throws {
        StubURLProtocol.Table.shared.install(try published("v0.2.0"))

        let fetched = try await stubbedSource().fetch(version: "v0.2.0", asset: asset, into: try directory())

        #expect(fetched.tag == "v0.2.0")
        #expect(fetched.fellBackToLatest == false)
        #expect(try Data(contentsOf: fetched.archive) == archive)
        #expect(fetched.sums == release.sums)
        let expectedSignature = release.signatureFile
        #expect(fetched.signatureBase64 == expectedSignature, "got \(fetched.signatureBase64) want \(expectedSignature)")
    }

    @Test func aVersionWithoutAReleaseFallsBackToTheNewerLatestWithItsTag() async throws {
        var table = try published("v0.3.0")
        table[download("v0.2.0", asset)] = .init(status: 404)
        table.merge(latestArchive("v0.3.0")) { $1 }
        StubURLProtocol.Table.shared.install(table)

        let fetched = try await stubbedSource().fetch(version: "v0.2.0", asset: asset, into: try directory())

        #expect(fetched.fellBackToLatest == true)
        #expect(fetched.tag == "v0.3.0")
        #expect(try Data(contentsOf: fetched.archive) == archive)
    }

    @Test func aLatestOlderThanTheAppIsStillBeingPublished() async throws {
        // 404 for v0.2.0, and latest is v0.1.0: the v0.2.0 release is not finished yet.
        var table = try published("v0.1.0")
        table[download("v0.2.0", asset)] = .init(status: 404)
        table.merge(latestArchive("v0.1.0")) { $1 }
        StubURLProtocol.Table.shared.install(table)

        let error = try await fetchError(stubbedSource(), version: "v0.2.0")

        #expect(error == .releaseStillPublishing("0.2.0"))
    }

    @Test func aLatestDownloadWithoutAnAppVersionNamesItsTag() async throws {
        var table = try published("v0.4.0")
        table.merge(latestArchive("v0.4.0")) { $1 }
        StubURLProtocol.Table.shared.install(table)

        let fetched = try await stubbedSource().fetch(version: nil, asset: asset, into: try directory())

        #expect(fetched.tag == "v0.4.0")
        #expect(fetched.fellBackToLatest == false)
    }

    @Test func aMissingSumsFileIsAnError() async throws {
        var table = try published("v0.2.0")
        table[download("v0.2.0", "SHA256SUMS")] = .init(status: 404)
        StubURLProtocol.Table.shared.install(table)

        let error = try await fetchError(stubbedSource(), version: "v0.2.0")

        #expect(error == .downloadFailed("the release has no SHA256SUMS"))
    }

    @Test func anArchiveAnnouncedAsTooBigIsRefusedBeforeItIsRead() async throws {
        var table = try published("v0.2.0")
        table[download("v0.2.0", asset)] = .init(status: 302, location: cdn(asset))
        table[cdn(asset)] = .init(headers: ["Content-Length": "5000"], body: Data(count: 5000))
        StubURLProtocol.Table.shared.install(table)

        let error = try await fetchError(stubbedSource(maxArchiveBytes: 1000), version: "v0.2.0")

        #expect(error == .downloadFailed("\(asset) is larger than 1000 bytes"))
    }

    @Test func anArchiveThatGrowsPastTheLimitIsStoppedWhileItStreams() async throws {
        // No Content-Length: the limit is only known while the bytes arrive, in 64 KB pieces.
        var table = try published("v0.2.0")
        table[cdn(asset)] = .init(body: Data(count: 150 * 1024))
        StubURLProtocol.Table.shared.install(table)

        let error = try await fetchError(stubbedSource(maxArchiveBytes: 100 * 1024), version: "v0.2.0")

        #expect(error == .downloadFailed("\(asset) is larger than \(100 * 1024) bytes"))
    }

    @Test func aLargeArchiveArrivesWhole() async throws {
        // Several 64 KB pieces, with a last one that is short.
        let big = Data((0..<(150 * 1024)).map { UInt8($0 % 251) })
        StubURLProtocol.Table.shared.install(try published("v0.2.0", archive: big))

        let fetched = try await stubbedSource().fetch(version: "v0.2.0", asset: asset, into: try directory())

        #expect(try Data(contentsOf: fetched.archive) == big)
    }

    @Test func aRedirectOffGitHubIsRefused() async throws {
        var table = try published("v0.2.0")
        table[download("v0.2.0", asset)] = .init(status: 302, location: "https://evil.example/bandito")
        StubURLProtocol.Table.shared.install(table)

        let error = try await fetchError(stubbedSource(), version: "v0.2.0")

        #expect(error == .downloadFailed("a redirect to a host other than GitHub was refused"))
    }

    @Test func aDownloadGetsTenMinutesAsAWhole() {
        #expect(GitHubReleaseSource.makeSession().configuration.timeoutIntervalForResource == 600)
    }
}
