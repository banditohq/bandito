import Foundation

/// Sends one HTTP request. `AccountClient` depends on this protocol so tests can answer without a network.
public protocol HTTPClient: Sendable {
    /// The body and the HTTP response. A response that is not HTTP is an error.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` without a cache or cookies: account answers are `cache-control: no-store`.
/// Redirects are refused: the answer to a redirect is returned as it is, so `Authorization` never
/// follows a `Location` header to another host.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    /// The session for account requests: no cache or cookies, and a request waits (up to 30 s in all) for the network
    /// to come back instead of failing at once, as it must after the app returns from the background or while the
    /// radio wakes up. A phone whose IPv6 does not work is served by the system's Happy Eyeballs; nothing here forces
    /// an address family.
    public static func accountConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    public init(configuration: URLSessionConfiguration = URLSessionHTTPClient.accountConfiguration()) {
        self.session = URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Answers every redirect with "do not follow": the 3xx response reaches the caller, which treats it as an error.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
