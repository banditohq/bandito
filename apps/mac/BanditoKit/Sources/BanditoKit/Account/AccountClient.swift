import CryptoKit
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
    private let retryDelay: Duration

    /// - Throws: `AccountError.insecureBaseURL` unless `baseURL` is `validate(baseURL:)`-clean.
    public init(
        identity: DeviceIdentity,
        sessions: SecretStore,
        http: HTTPClient = URLSessionHTTPClient(),
        baseURL: URL = AccountClient.defaultBaseURL,
        device: DeviceDescriptor = .current,
        retryDelay: Duration = .milliseconds(1500)
    ) throws {
        try Self.validate(baseURL: baseURL)
        self.identity = identity
        self.sessions = sessions
        self.http = http
        self.baseURL = baseURL
        self.device = device
        self.retryDelay = retryDelay
    }

    /// Extra attempts after a transport failure (two retries, three tries in all).
    static let maxRetries = 2

    /// The base URL must be `https://bandito.dev` with no port or port 443, and no user info. Plain `http` is
    /// allowed only to a loopback host on any port (local development, `wrangler dev`), also without user info.
    /// Anything else would send tokens in the clear or to another server.
    public static func validate(baseURL: URL) throws {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host?.lowercased() else {
            throw AccountError.insecureBaseURL
        }
        guard baseURL.user == nil, baseURL.password == nil else { throw AccountError.insecureBaseURL }
        if scheme == "https", host == "bandito.dev", baseURL.port == nil || baseURL.port == 443 { return }
        if scheme == "http", ["127.0.0.1", "localhost"].contains(host) { return }
        throw AccountError.insecureBaseURL
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
        let reply = try await send("POST", "/auth/challenge", body: EmptyBody(), retry: .always)
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
    ///
    /// A connection that drops mid-request is tried again with a fresh signed challenge (a nonce is single use). If the
    /// first try may have reached the server and the retry is then told the code is wrong, the code was probably spent
    /// by the first try and its answer was lost: `AccountError.api(code: "verify_unconfirmed", status: 0)`.
    public func emailVerify(email: String, code: String) async throws -> Session {
        var maybeDelivered = false
        var attempt = 0
        while true {
            let body = EmailVerifyBody(email: email, code: code, device: try await signedDevice())
            let request = try makeRequest("POST", "/auth/email/verify", body: body)
            do {
                let reply = try await transmit(request)
                if maybeDelivered, reply.status == 401 || reply.status == 429 {
                    throw AccountError.api(code: Self.verifyUnconfirmed, status: 0)
                }
                let session = try decodeOK(Session.self, reply)
                try storeSession(session)
                return session
            } catch let failure as TransportFailure {
                guard attempt < Self.maxRetries, !Task.isCancelled, RetryScope.always.allows(failure.underlying) else {
                    throw AccountError.network(Self.detail(of: failure.underlying))
                }
                if !RetryScope.beforeSend.allows(failure.underlying) { maybeDelivered = true }
                attempt += 1
                try await Task.sleep(for: retryDelay)
            }
        }
    }

    /// The `api` code of a verify whose answer was lost and whose code the retry then found spent.
    public static let verifyUnconfirmed = "verify_unconfirmed"

    /// The signed-in user, this device, and every device of the account. Works before approval too.
    public func me() async throws -> Me {
        try decodeOK(Me.self, try await send("GET", "/me", authenticated: true))
    }

    /// Ends the session `session` on the server, using its own token. Works after the local copy is gone:
    /// the caller keeps the session in memory and forgets the local copy first. A session the server no longer
    /// knows counts as ended.
    public func revoke(_ session: Session) async throws {
        do {
            let reply = try await send("POST", "/auth/logout", body: EmptyBody(), token: session.token)
            try checkOK(reply)
        } catch AccountError.api(code: "unauthorized", status: _) {
            return
        }
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

    /// Hands a pending device the sync key. Only an approved device may call it.
    ///
    /// The code of `device.publicKey` must equal `confirmedFingerprint`, the code the user compared on the new
    /// device's screen. Otherwise nothing is sealed or sent: `AccountError.fingerprintMismatch`. This is what
    /// stops a server that swapped the public key from receiving the sync key.
    ///
    /// The envelope is bound to this account (the signed-in session) and to `device.id`. Only that device of
    /// that account can open it.
    public func approve(
        _ device: PendingDevice, confirmedFingerprint: String, syncKey: SymmetricKey, identity: DeviceIdentity
    ) async throws {
        let computed = try DeviceFingerprint.code(publicKeyBase64: device.publicKey)
        guard DeviceFingerprint.matches(computed, confirmedFingerprint) else {
            throw AccountError.fingerprintMismatch
        }
        struct Body: Encodable { var envelope: String }
        let path = "/devices/\(try Self.segment(device.id))/approve"
        let session = try requireSession()
        let envelope = try SyncKey.seal(
            syncKey, forPublicKey: device.publicKey, sender: identity,
            accountID: session.user.id, deviceID: device.id)
        let reply = try await send("POST", path, body: Body(envelope: envelope), authenticated: true)
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
        let reply = try await send("DELETE", "/devices/\(try Self.segment(id))\(query)", authenticated: true)
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
    ///
    /// The UI must not call this directly. Use `SyncStore.resetAccount()`: it also forgets the version history
    /// of the account on this device. Without that, the new blob (version 1) would be refused as a rollback.
    public func reset() async throws -> DeviceRef {
        struct Body: Encodable { var confirm = "RESET" }
        struct Wire: Decodable { var device: DeviceRef }
        let reply = try await send("POST", "/account/reset", body: Body(), authenticated: true)
        return try decodeOK(Wire.self, reply).device
    }

    // MARK: sharing (docs/ARCHITECTURE.md#sharing)

    /// Publishes a bot or skill (`POST /shares`). The platform checks every text of the draft for keys and tokens.
    public func createShare(_ draft: ShareDraft) async throws -> ShareCreated {
        let reply = try await shareSend("POST", "/shares", body: draft, authenticated: true)
        return try shareDecode(ShareCreated.self, reply)
    }

    /// The owner's shares, without their payloads (`GET /shares/mine`).
    public func myShares() async throws -> [ShareSummary] {
        struct Wire: Decodable { var shares: [ShareSummary] }
        let reply = try await shareSend("GET", "/shares/mine", authenticated: true)
        return try shareDecode(Wire.self, reply).shares
    }

    /// Changes the visibility, title, summary or payload of one of the owner's shares (`PATCH /shares/:id`).
    /// A payload change makes the next version. Another account's share is `ShareFailure.notFound`.
    /// Returns the share's version after the change: a payload change makes the next version (`{ok, version}`).
    @discardableResult
    public func updateShare(id: String, _ update: ShareUpdate) async throws -> Int {
        struct Wire: Decodable { var version: Int }
        let path = "/shares/\(try Self.shareSegment(id))"
        let reply = try await shareSend("PATCH", path, body: update, authenticated: true)
        return try shareDecode(Wire.self, reply).version
    }

    /// Removes one of the owner's shares (`DELETE /shares/:id`). The link stops working.
    public func deleteShare(id: String) async throws {
        let reply = try await shareSend("DELETE", "/shares/\(try Self.shareSegment(id))", authenticated: true)
        try shareCheck(reply)
    }

    /// A shared item by its id. No sign-in needed. A hidden item is `ShareFailure.hidden`, an unknown one `.notFound`.
    public func getShare(id: String) async throws -> SharedItem {
        struct Wire: Decodable { var share: SharedItem }
        let reply = try await shareSend("GET", "/shares/\(try Self.shareSegment(id))")
        return try shareDecode(Wire.self, reply).share
    }

    /// Reports a shared item (`POST /shares/:id/report`). Five different reporters hide it until it is reviewed.
    public func reportShare(id: String, reason: ShareReportReason, note: String) async throws {
        struct Body: Encodable {
            var reason: ShareReportReason
            var note: String
        }
        let path = "/shares/\(try Self.shareSegment(id))/report"
        let reply = try await shareSend("POST", path, body: Body(reason: reason, note: note))
        try shareCheck(reply)
    }

    /// Counts one install of a shared item (`POST /shares/:id/installed`). The platform counts once a day per address.
    public func markInstalled(id: String) async throws {
        let reply = try await shareSend("POST", "/shares/\(try Self.shareSegment(id))/installed")
        try shareCheck(reply)
    }

    /// An ID of a share as a URL path segment. Only the base62 form of a share id passes (22 characters).
    static func shareSegment(_ id: String) throws -> String {
        guard ShareID.isValid(id) else { throw ShareFailure.invalid }
        return id
    }

    // MARK: relay registrations (docs/RELAY.md, platform docs/API.md "Relay")

    /// Registers a server for Bandito Relay (`POST /relay/servers`). The secret comes back once; it goes to the daemon
    /// (`relay.enable`) and is kept nowhere else. Needs an approved device session.
    public func registerRelayServer(name: String) async throws -> RelayRegistration {
        struct Body: Encodable { var name: String }
        let reply = try await send("POST", "/relay/servers", body: Body(name: String(name.prefix(100))), authenticated: true)
        return try decodeOK(RelayRegistration.self, reply)
    }

    /// The account's registered servers (`GET /relay/servers`), oldest first.
    public func relayServers() async throws -> [RelayServerEntry] {
        struct Wire: Decodable { var servers: [RelayServerEntry] }
        return try decodeOK(Wire.self, try await send("GET", "/relay/servers", authenticated: true)).servers
    }

    /// Removes a registration (`DELETE /relay/servers/:sid`). One the server does not know counts as removed.
    public func deleteRelayServer(sid: String) async throws {
        guard RelayRoute.isSID(sid) else { throw AccountError.invalidIdentifier }
        do {
            try checkOK(try await send("DELETE", "/relay/servers/\(sid)", authenticated: true))
        } catch AccountError.api(code: "not_found", status: _) {
            return
        }
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

    /// Which transport failures a request may be tried again after.
    enum RetryScope {
        /// A request that can be repeated without harm (a read, a fresh challenge): any dropped connection or timeout.
        case always
        /// Anything else: only failures where the request cannot have left the phone.
        case beforeSend

        func allows(_ error: Error) -> Bool {
            guard let code = (error as? URLError)?.code else { return false }
            switch code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                .internationalRoamingOff, .dataNotAllowed:
                return true
            case .networkConnectionLost, .timedOut:
                return self == .always
            default:
                return false
            }
        }
    }

    /// A failure of the transport, kept apart from `AccountError` until the retries are used up.
    struct TransportFailure: Error {
        var underlying: Error
    }

    /// "NSURLErrorDomain -1005": what the screen's details line shows. No address, no text of the request.
    static func detail(of error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }

    private func makeRequest(
        _ method: String, _ path: String, body: (any Encodable)? = nil, token: String? = nil
    ) throws -> URLRequest {
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
        return request
    }

    /// One try. A failure that is not an `AccountError` is a `TransportFailure`.
    private func transmit(_ request: URLRequest) async throws -> Reply {
        do {
            let (data, response) = try await http.send(request)
            return Reply(status: response.statusCode, data: data)
        } catch let error as AccountError {
            throw error
        } catch {
            throw TransportFailure(underlying: error)
        }
    }

    private func send(
        _ method: String, _ path: String, body: (any Encodable)? = nil, authenticated: Bool = false,
        token explicitToken: String? = nil, retry: RetryScope? = nil
    ) async throws -> Reply {
        var token: String? = explicitToken
        if authenticated, token == nil {
            token = try requireSession().token
        }
        let request = try makeRequest(method, path, body: body, token: token)
        // Reads can always be repeated; everything else only when the request cannot have been sent.
        let scope = retry ?? (method == "GET" ? .always : .beforeSend)
        var attempt = 0
        while true {
            do {
                let reply = try await transmit(request)
                // A gateway that is briefly down answers 502/503/504 to a read: try again.
                if scope == .always, [502, 503, 504].contains(reply.status), attempt < Self.maxRetries, !Task.isCancelled {
                    attempt += 1
                    try await Task.sleep(for: retryDelay)
                    continue
                }
                return reply
            } catch let failure as TransportFailure {
                guard attempt < Self.maxRetries, !Task.isCancelled, scope.allows(failure.underlying) else {
                    throw AccountError.network(Self.detail(of: failure.underlying))
                }
                attempt += 1
                try await Task.sleep(for: retryDelay)
            }
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

    /// `send` for the sharing calls: the same request, with the failures named as `ShareFailure`.
    private func shareSend(
        _ method: String, _ path: String, body: (any Encodable)? = nil, authenticated: Bool = false
    ) async throws -> Reply {
        do {
            return try await send(method, path, body: body, authenticated: authenticated)
        } catch AccountError.notSignedIn {
            throw ShareFailure.unauthorized
        } catch AccountError.network(let detail) {
            throw ShareFailure.network(detail)
        } catch {
            throw ShareFailure.badResponse
        }
    }

    private func shareDecode<T: Decodable>(_ type: T.Type, _ reply: Reply) throws -> T {
        try shareCheck(reply)
        guard let value = try? JSONDecoder().decode(T.self, from: reply.data) else {
            throw ShareFailure.badResponse
        }
        return value
    }

    /// A 2xx answer without `ok: false` passes. Anything else is the platform's error, by its code or else by status.
    private func shareCheck(_ reply: Reply) throws {
        let body = try? JSONDecoder().decode(ShareFailureBody.self, from: reply.data)
        if (200..<300).contains(reply.status), body?.ok != false { return }
        if let code = body?.error {
            throw ShareFailure.from(code: code, status: reply.status, field: body?.field)
        }
        throw ShareFailure.from(status: reply.status)
    }

    private func apiError(_ reply: Reply, _ failure: Failure?) -> AccountError {
        .api(code: failure?.error ?? "http_\(reply.status)", status: reply.status)
    }

    /// An ID as a URL path segment. Only `^[A-Za-z0-9_-]{1,128}$` passes, so `..`, slashes and empty IDs
    /// cannot reach another endpoint.
    static func segment(_ id: String) throws -> String {
        guard (1...128).contains(id.count), id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else {
            throw AccountError.invalidIdentifier
        }
        return id
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
