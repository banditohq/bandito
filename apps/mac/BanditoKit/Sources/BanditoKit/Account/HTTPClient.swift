import Foundation

/// Sends one HTTP request. `AccountClient` depends on this protocol so tests can answer without a network.
public protocol HTTPClient: Sendable {
    /// The body and the HTTP response. A response that is not HTTP is an error.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` without a cache or cookies: account answers are `cache-control: no-store`.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
