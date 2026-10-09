import Foundation

/// Sign-in, devices and sync against the Bandito accounts API (docs/ACCOUNTS_API.md).
/// One HTTP request per method. The only state is the session, kept in `sessions`.
public actor AccountClient {
    public static let defaultBaseURL = URL(string: "https://bandito.dev/api/v1")!
    /// Keychain account of the stored session: the JSON of `Session`.
    public static let sessionAccount = "session"

    private let identity: DeviceIdentity
    private let sessions: SecretStore
    private let http: HTTPClient
    private let baseURL: URL
    private let device: DeviceDescriptor

    public init(
        identity: DeviceIdentity,
        sessions: SecretStore,
        http: HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = AccountClient.defaultBaseURL,
        device: DeviceDescriptor = .current
    ) {
        self.identity = identity
        self.sessions = sessions
        self.http = http
        self.baseURL = baseURL
        self.device = device
    }

    // MARK: session

    /// The stored session, or nil when signed out. An unreadable entry counts as signed out.
    public func restoreSession() throws -> Session? {
        guard let data = try sessions.load(account: Self.sessionAccount) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    // MARK: sign-in

    /// A fresh single-use nonce for a device-signed request.
    public func challenge() async throws -> String {
        struct Wire: Decodable { var nonce: String }
        let reply = try await send("POST", "/auth/challenge", body: EmptyBody())
        return try decodeOK(Wire.self, reply).nonce
    }

    /// Starts a GitHub device-flow sign-in on the server.
    public func githubStart() async throws -> GitHubFlow {
        let reply = try await send("POST", "/auth/github/start", body: EmptyBody())
        let wire = try decodeOK(GitHubStartWire.self, reply)
        guard let verificationURI = URL(string: wire.verificationURI) else { throw AccountError.badResponse }
        return GitHubFlow(
            flowID: wire.flowID, userCode: wire.userCode, verificationURI: verificationURI,
            interval: wire.interval, expiresIn: wire.expiresIn)
    }

    /// One poll of a GitHub flow. Every poll takes a fresh challenge and signs it.
    /// On success the session is stored.
    public func githubPoll(flowID: String) async throws -> PollResult {
        let body = PollBody(flowID: flowID, device: try await signedDevice())
        let reply = try await send("POST", "/auth/github/poll", body: body)
        // `pending` and `slow_down` are HTTP 200 with `ok: false`, not errors.
        if let failure = try? JSONDecoder().decode(Failure.self, from: reply.data),
            failure.ok == false, let code = failure.error
        {
            switch code {
            case "pending": return .pending
            case "slow_down": return .slowDown(interval: failure.interval ?? 5)
            case "expired", "flow_not_found": return .expired
            case "access_denied": return .denied
            default: throw apiError(reply, failure)
            }
        }
        let session = try decodeOK(Session.self, reply)
        try storeSession(session)
        return .signedIn(session)
    }

    /// Sends a 6-digit sign-in code to `email`. Answers the same whether or not the account exists.
    public func emailStart(email: String) async throws {
        let reply = try await send("POST", "/auth/email/start", body: EmailBody(email: email))
        try checkOK(reply)
    }

    /// Checks the code and signs in. On success the session is stored.
    public func emailVerify(email: String, code: String) async throws -> Session {
        let body = EmailVerifyBody(email: email, code: code, device: try await signedDevice())
        let reply = try await send("POST", "/auth/email/verify", body: body)
        let session = try decodeOK(Session.self, reply)
        try storeSession(session)
        return session
    }

    /// The signed-in user, this device, and every device of the account. Works before approval too.
    public func me() async throws -> Me {
        try decodeOK(Me.self, try await send("GET", "/me", authenticated: true))
    }

    /// Ends the server session, then forgets it here. A session the server no longer knows is forgotten
    /// too. A network failure keeps the session, so the call can be retried.
    public func logout() async throws {
        guard try restoreSession() != nil else { return }
        do {
            let reply = try await send("POST", "/auth/logout", body: EmptyBody(), authenticated: true)
            try checkOK(reply)
        } catch let error as AccountError {
            if case .api(code: "unauthorized", status: _) = error {
                // Already gone on the server; forget it here.
            } else {
                throw error
            }
        }
        try sessions.save(nil, account: Self.sessionAccount)
    }

    // MARK: devices

    /// Devices of the account waiting for approval. Only an approved device may ask.
    public func pendingDevices() async throws -> [PendingDevice] {
        struct Wire: Decodable { var devices: [PendingDevice] }
        let reply = try await send("GET", "/devices/pending", authenticated: true)
        return try decodeOK(Wire.self, reply).devices
    }

    /// Hands a pending device its sync-key envelope. Only an approved device may send it.
    public func approve(deviceID: String, envelope: String) async throws {
        struct Body: Encodable { var envelope: String }
        let reply = try await send(
            "POST", "/devices/\(Self.segment(deviceID))/approve", body: Body(envelope: envelope), authenticated: true)
        try checkOK(reply)
    }

    /// The envelope this device received after approval, or nil until another device approves it.
    public func myEnvelope() async throws -> Envelope? {
        let reply = try await send("GET", "/devices/me/envelope", authenticated: true)
        if reply.status == 404, (try? JSONDecoder().decode(Failure.self, from: reply.data))?.error == "not_yet" {
            return nil
        }
        return try decodeOK(Envelope.self, reply)
    }

    /// Removes a device. `force` confirms removing the last approved device, which resets the account's sync data.
    public func deleteDevice(id: String, force: Bool) async throws {
        let query = force ? "?force=1" : ""
        let reply = try await send("DELETE", "/devices/\(Self.segment(id))\(query)", authenticated: true)
        try checkOK(reply)
    }

    // MARK: sync

    /// The encrypted sync blob, or nil when the account has none yet.
    public func getSync() async throws -> SyncBlob? {
        struct Wire: Decodable {
            var version: Int
            var blob: String?
        }
        let wire = try decodeOK(Wire.self, try await send("GET", "/sync", authenticated: true))
        guard let blob = wire.blob else { return nil }
        return SyncBlob(version: wire.version, blob: blob)
    }

    /// Stores `blob` if the server is still at `version`. Returns the new version.
    /// Throws `AccountError.conflict` when the version moved on.
    public func putSync(version: Int, blob: String) async throws -> Int {
        struct Body: Encodable {
            var version: Int
            var blob: String
        }
        struct Wire: Decodable { var version: Int }
        let reply = try await send(
            "PUT", "/sync", body: Body(version: version, blob: blob), authenticated: true)
        if reply.status == 409 {
            let failure = try? JSONDecoder().decode(Failure.self, from: reply.data)
            if failure?.error == "conflict" {
                throw AccountError.conflict(current: failure?.version ?? 0)
            }
        }
        return try decodeOK(Wire.self, reply).version
    }

    /// Recovery for an account whose key is lost: discards the sync data and the other devices.
    /// Needs a session created in the last 10 minutes. Returns this device's state.
    public func reset() async throws -> DeviceRef {
        struct Body: Encodable { var confirm = "RESET" }
        struct Wire: Decodable { var device: DeviceRef }
        let reply = try await send("POST", "/account/reset", body: Body(), authenticated: true)
        return try decodeOK(Wire.self, reply).device
    }

    // MARK: internals

    private func signedDevice() async throws -> DeviceBlock {
        let nonce = try await challenge()
        return DeviceBlock(
            name: device.name,
            platform: device.platform,
            publicKey: identity.publicKeyBase64,
            signingKey: identity.signingKeyBase64,
            nonce: nonce,
            signature: identity.sign(login: nonce))
    }

    private func storeSession(_ session: Session) throws {
        try sessions.save(try JSONEncoder().encode(session), account: Self.sessionAccount)
    }

    private func requireSession() throws -> Session {
        guard let session = try restoreSession() else { throw AccountError.notSignedIn }
        return session
    }

    private func send(
        _ method: String, _ path: String, body: (any Encodable)? = nil, authenticated: Bool = false
    ) async throws -> Reply {
        var token: String?
        if authenticated {
            token = try requireSession().token
        }
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await http.send(request)
            return Reply(status: response.statusCode, data: data)
        } catch let error as AccountError {
            throw error
        } catch {
            throw AccountError.network(error.localizedDescription)
        }
    }

    private func url(for path: String) throws -> URL {
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + path) else { throw AccountError.badResponse }
        return url
    }

    /// Decodes a successful answer. A non-2xx status or an `ok: false` body is an API error.
    private func decodeOK<T: Decodable>(_ type: T.Type, _ reply: Reply) throws -> T {
        try checkOK(reply)
        guard let value = try? JSONDecoder().decode(T.self, from: reply.data) else {
            throw AccountError.badResponse
        }
        return value
    }

    private func checkOK(_ reply: Reply) throws {
        let failure = try? JSONDecoder().decode(Failure.self, from: reply.data)
        if (200..<300).contains(reply.status), failure?.ok != false { return }
        throw apiError(reply, failure)
    }

    private func apiError(_ reply: Reply, _ failure: Failure?) -> AccountError {
        .api(code: failure?.error ?? "http_\(reply.status)", status: reply.status)
    }

    /// A device ID as a single URL path segment.
    private static func segment(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}

// MARK: - wire types

private struct Reply {
    var status: Int
    var data: Data
}

/// The fields of an error or pending answer. Read before the success shape, so `ok: false` is seen first.
private struct Failure: Decodable {
    var ok: Bool?
    var error: String?
    var version: Int?
    var interval: Int?
}

private struct EmptyBody: Encodable {}

private struct EmailBody: Encodable {
    var email: String
}

/// The device block of every sign-in request (docs/ACCOUNTS_API.md#device-identity).
private struct DeviceBlock: Encodable {
    var name: String
    var platform: String
    var publicKey: String
    var signingKey: String
    var nonce: String
    var signature: String

    private enum CodingKeys: String, CodingKey {
        case name, platform, nonce, signature
        case publicKey = "public_key"
        case signingKey = "signing_key"
    }
}

private struct EmailVerifyBody: Encodable {
    var email: String
    var code: String
    var device: DeviceBlock
}

private struct PollBody: Encodable {
    var flowID: String
    var device: DeviceBlock

    private enum CodingKeys: String, CodingKey {
        case device
        case flowID = "flow_id"
    }
}

private struct GitHubStartWire: Decodable {
    var flowID: String
    var userCode: String
    var verificationURI: String
    var expiresIn: Int
    var interval: Int

    private enum CodingKeys: String, CodingKey {
        case flowID = "flow_id"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}
