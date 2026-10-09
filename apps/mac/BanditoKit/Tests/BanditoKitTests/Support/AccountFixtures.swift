import CryptoKit
import Foundation
import Testing

@testable import BanditoKit

/// One scripted HTTP answer.
struct ScriptedReply: Sendable {
    var status: Int
    var body: String

    init(_ body: String, status: Int = 200) {
        self.body = body
        self.status = status
    }
}

/// In-memory `HTTPClient`. Routes are keyed by `METHOD /path[?query]` without the `/api/v1` prefix.
/// A route answers its replies in order and repeats the last one. A request without a route fails
/// with a network error, so an unscripted call shows up as a test failure, never as a real request.
final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
    // @unchecked: `routes` and `recorded` are guarded by `lock`.
    private let lock = NSLock()
    private var routes: [String: [ScriptedReply]]
    private var recorded: [URLRequest] = []

    init(_ routes: [String: [ScriptedReply]]) {
        self.routes = routes
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = Self.key(for: request)
        let reply: ScriptedReply? = lock.withLock {
            recorded.append(request)
            guard let queue = routes[key], !queue.isEmpty else { return nil }
            if queue.count > 1 {
                routes[key] = Array(queue.dropFirst())
                return queue[0]
            }
            return queue[0]
        }
        guard let reply, let url = request.url else {
            throw URLError(.cannotConnectToHost)
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }

    static func key(for request: URLRequest) -> String {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "?"
        }
        let path = parts.path.replacingOccurrences(of: "/api/v1", with: "")
        let query = parts.percentEncodedQuery.map { "?" + $0 } ?? ""
        return "\(request.httpMethod ?? "GET") \(path)\(query)"
    }

    /// Every request sent, in order.
    var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    /// Keys of the requests sent, in order (`POST /auth/challenge`, …).
    var keys: [String] {
        requests.map { Self.key(for: $0) }
    }
}

/// The JSON object body of a request.
func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    guard let data = request.httpBody,
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw URLError(.cannotParseResponse)
    }
    return object
}

/// The raw bytes of a symmetric key.
func rawBytes(of key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

/// A fresh identity whose keys live in memory only.
func makeIdentity() throws -> DeviceIdentity {
    try DeviceIdentity.load(from: MemorySecretStore())
}

/// An account client on scripted HTTP, with the test device's name and platform.
func makeClient(
    http: ScriptedHTTP,
    sessions: SecretStore = MemorySecretStore(),
    identity: DeviceIdentity? = nil
) throws -> AccountClient {
    AccountClient(
        identity: try identity ?? makeIdentity(),
        sessions: sessions,
        http: http,
        device: DeviceDescriptor(name: "Test Mac", platform: "macos"))
}

/// A session response body, as `/auth/email/verify` and `/auth/github/poll` send it.
let sessionBody = """
    {"ok":true,"token":"tok_1","user":{"id":"u1","email":"ann@example.com","name":"Ann","github_login":"ann"},\
    "device":{"id":"d1","approved":true}}
    """

/// Stores a session the way `AccountClient` does, so a test can start signed in.
func seedSession(_ store: SecretStore, token: String) throws {
    let session = Session(
        token: token,
        user: AccountUser(id: "u1", email: "ann@example.com", name: "Ann", githubLogin: "ann"),
        device: DeviceRef(id: "d1", approved: true))
    try store.save(try JSONEncoder().encode(session), account: AccountClient.sessionAccount)
}

/// Checks the device block of a sign-in request: nonce, keys and the Ed25519 signature over the login message.
func expectValidLoginProof(_ device: [String: Any], identity: DeviceIdentity, nonce: String) throws {
    let publicKey = try #require(device["public_key"] as? String)
    let signingKey = try #require(device["signing_key"] as? String)
    #expect(device["nonce"] as? String == nonce)
    #expect(publicKey == identity.publicKeyBase64)
    #expect(signingKey == identity.signingKeyBase64)
    let signatureText = try #require(device["signature"] as? String)
    let signature = try #require(Data(base64Encoded: signatureText))
    let keyBytes = try #require(Data(base64Encoded: signingKey))
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let message = DeviceIdentity.loginMessage(nonce: nonce, publicKey: publicKey, signingKey: signingKey)
    #expect(key.isValidSignature(signature, for: Data(message.utf8)))
}

/// Collects every event of an install stream.
func collect(_ stream: AsyncStream<InstallEvent>) async -> [InstallEvent] {
    var events: [InstallEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}
