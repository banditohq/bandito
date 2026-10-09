import Foundation
import Testing

@testable import BanditoKit

/// Every request a stub session saw, from any thread.
final class RequestLog: @unchecked Sendable {
    // @unchecked: `requests` is guarded by `lock`.
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func clear() {
        lock.withLock { requests = [] }
    }

    var all: [URLRequest] {
        lock.withLock { requests }
    }
}

/// Answers every request to `bandito.dev` with a 302 to `evil.example`, and answers `evil.example` with 200.
/// A client that follows the redirect shows up in the log with the `evil.example` host.
final class RedirectingProtocol: URLProtocol {
    static let log = RequestLog()
    static let redirectTarget = URL(string: "https://evil.example/steal")!

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.log.record(request)
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if url.host == "evil.example" {
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("stolen".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let redirect = HTTPURLResponse(
            url: url, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": Self.redirectTarget.absoluteString])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: Self.redirectTarget), redirectResponse: redirect)
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct RedirectRefusalTests {
    private var stubConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        return configuration
    }

    private var authorizedRequest: URLRequest {
        var request = URLRequest(url: URL(string: "https://bandito.dev/api/v1/me")!)
        request.setValue("Bearer tok_9", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Control: a plain session does follow the stub's redirect. Without this the refusal test would prove nothing.
    @Test func controlPlainSessionFollowsTheRedirect() async throws {
        RedirectingProtocol.log.clear()
        let session = URLSession(configuration: stubConfiguration)

        _ = try await session.data(for: authorizedRequest)

        #expect(RedirectingProtocol.log.all.contains { $0.url?.host == "evil.example" })
    }

    @Test func aRedirectIsReturnedAsTheAnswerAndTheTargetIsNeverRequested() async throws {
        RedirectingProtocol.log.clear()
        let client = URLSessionHTTPClient(configuration: stubConfiguration)

        let (_, response) = try await client.send(authorizedRequest)

        #expect(response.statusCode == 302)
        let requests = RedirectingProtocol.log.all
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.url?.host == "bandito.dev" })
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok_9")
    }

    @Test func accountCallOnARedirectIsAnErrorAndSendsNoAuthorizationElsewhere() async throws {
        RedirectingProtocol.log.clear()
        let sessions = MemorySecretStore()
        try seedSession(sessions, token: "tok_9")
        let client = try AccountClient(
            identity: try makeIdentity(), sessions: sessions,
            http: URLSessionHTTPClient(configuration: stubConfiguration),
            device: DeviceDescriptor(name: "Test Mac", platform: "macos"))

        do {
            _ = try await client.me()
            Issue.record("expected an error for a 302")
        } catch let error as AccountError {
            #expect(error == .api(code: "http_302", status: 302))
        }

        #expect(RedirectingProtocol.log.all.allSatisfy { $0.url?.host == "bandito.dev" })
        #expect(!RedirectingProtocol.log.all.contains { $0.url?.host == "evil.example" })
    }
}
