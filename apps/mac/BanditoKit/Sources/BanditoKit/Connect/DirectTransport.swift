import CryptoKit
import Foundation
import Security

// A direct connection to a daemon's TLS phone listener (docs/ARCHITECTURE.md#phone-access). The certificate is
// self-signed, so the system could never vouch for it: the app trusts exactly the certificate whose SHA-256 it was
// given at pairing, and nothing else.

/// The certificate fingerprint: SHA-256 of the DER bytes, written as 64 lower-case hex digits.
public enum PinnedFingerprint {
    /// `text` as 64 lower-case hex digits. Accepts upper case and the usual separators (`AB:CD:…`, spaces, dashes).
    /// nil when it is not exactly 32 bytes of hex.
    public static func normalize(_ text: String) -> String? {
        let cleaned = text.filter { !($0 == ":" || $0 == " " || $0 == "-" || $0 == "\n" || $0 == "\t") }.lowercased()
        guard cleaned.count == 64, cleaned.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return cleaned
    }

    public static func of(der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// For showing to a person: `AB:CD:EF:…`, upper case, in groups of two.
    public static func display(_ fingerprint: String) -> String {
        let chars = Array(fingerprint.uppercased())
        return stride(from: 0, to: chars.count, by: 2).map { String(chars[$0..<min($0 + 2, chars.count)]) }
            .joined(separator: ":")
    }
}

/// One address of a daemon: a host (name, IPv4 or IPv6) and a port.
public struct DirectHost: Sendable, Hashable {
    public static let defaultPort = 7879

    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Reads `host`, `host:port`, `[v6]` or `[v6]:port` (a bare IPv6 address has no port). The port defaults to 7879.
    /// A scheme, a path, a user or a space is refused: only an address is taken.
    public static func parse(_ text: String, defaultPort: Int = defaultPort) -> DirectHost? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || "/@?#\\%".contains($0) }) else { return nil }
        var host = trimmed
        var port = defaultPort
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = parsePort(rest.dropFirst()) else { return nil }
                port = p
            }
            guard isIPv6(host) else { return nil }
            return DirectHost(host: host.lowercased(), port: port)
        }
        if trimmed.filter({ $0 == ":" }).count > 1 {
            guard isIPv6(trimmed) else { return nil }
            return DirectHost(host: trimmed.lowercased(), port: port)
        }
        if let colon = trimmed.firstIndex(of: ":") {
            host = String(trimmed[..<colon])
            guard let p = parsePort(trimmed[trimmed.index(after: colon)...]) else { return nil }
            port = p
        }
        guard isHostName(host) else { return nil }
        return DirectHost(host: host.lowercased(), port: port)
    }

    private static func parsePort(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCII), let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    private static func isHostName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 253 else { return false }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// `host:port`, with an IPv6 address in brackets: the form the daemon's link uses.
    public var text: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    /// Whether the address is one of Tailscale's: `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
    public var isTailscale: Bool {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0
        }
        return false
    }

    /// `wss://host:port/v1/rpc`.
    public var rpcURL: URL? { URL(string: "wss://\(text)/v1/rpc") }

    /// `https://host:port/v1/health`.
    public var healthURL: URL? { URL(string: "https://\(text)/v1/health") }
}

/// The address that worked last for a server (by its fingerprint), so the next connection tries it first: a phone that
/// is at home reaches the LAN address at once instead of waiting for the Tailscale one to time out, and the other way.
public final class DirectHostMemory: @unchecked Sendable {
    public static let shared = DirectHostMemory(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func key(_ fingerprint: String) -> String { "direct.lastHost.\(fingerprint)" }

    public func lastGood(for fingerprint: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: key(fingerprint))
    }

    public func remember(_ host: String, for fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(host, forKey: key(fingerprint))
    }

    public func forget(_ fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key(fingerprint))
    }

    /// `hosts` with the one that worked last first; the others keep the order the server gave.
    public func ordered(_ hosts: [String], for fingerprint: String) -> [String] {
        guard let last = lastGood(for: fingerprint), let index = hosts.firstIndex(of: last), index != 0 else { return hosts }
        var out = hosts
        out.remove(at: index)
        out.insert(last, at: 0)
        return out
    }
}

/// Accepts the server certificate whose fingerprint is `expected`, refuses every other one. With `expected == nil` it
/// accepts any certificate and only records its fingerprint (`FingerprintProbe`: the person is shown it and decides).
// @unchecked: the state is guarded by `lock`.
final class PinDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let expected: String?
    private let lock = NSLock()
    private var wasMismatch = false
    private var seenFingerprint: String?

    init(expected: String?) {
        self.expected = expected
    }

    var mismatched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasMismatch
    }

    var seen: String? {
        lock.lock()
        defer { lock.unlock() }
        return seenFingerprint
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fingerprint = PinnedFingerprint.of(der: SecCertificateCopyData(leaf) as Data)
        lock.lock()
        seenFingerprint = fingerprint
        let matches = expected.map { Self.sameFingerprint($0, fingerprint) } ?? true
        if !matches { wasMismatch = true }
        lock.unlock()
        if matches {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// No redirects: a server that answers "go to another address" is not followed (another address would present another
    /// certificate, and the pin was given for this one).
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// Compares without stopping at the first different digit.
    static func sameFingerprint(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for (l, r) in zip(x, y) { diff |= l ^ r }
        return diff == 0
    }
}

/// Reads the fingerprint a server presents, without trusting it: for "trust on first use", where the person is shown the
/// fingerprint and confirms it against the one on their Mac before the app sends anything else.
public enum FingerprintProbe {
    /// The fingerprint of the certificate at `host`, or nil when nothing answered the TLS handshake in time.
    public static func fetch(host: DirectHost, timeout: Duration = .seconds(6)) async -> String? {
        guard let url = host.healthURL else { return nil }
        let delegate = PinDelegate(expected: nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(timeout.components.seconds)
        configuration.timeoutIntervalForResource = TimeInterval(timeout.components.seconds)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        // The answer does not matter, only the handshake before it: nothing is sent that the server could act on.
        _ = try? await session.data(from: url)
        return delegate.seen
    }
}

/// WebSocket to a daemon's phone listener, trying its addresses one after the other. Single use, like
/// `WebSocketTransport`: create one per connection.
public actor DirectTransport: RPCTransport {
    /// How long one address has to answer before the next is tried.
    public static let defaultHostTimeout: Duration = .seconds(6)

    private let hosts: [String]
    private let fingerprint: String
    private let token: String?
    private let hostTimeout: Duration
    private let memory: DirectHostMemory
    private var inner: WebSocketTransport?
    /// The address that answered, once connected.
    public private(set) var connectedHost: String?

    public init(
        hosts: [String], fingerprint: String, token: String?, hostTimeout: Duration = DirectTransport.defaultHostTimeout,
        memory: DirectHostMemory = .shared
    ) {
        self.hosts = hosts
        self.fingerprint = PinnedFingerprint.normalize(fingerprint) ?? fingerprint
        self.token = token
        self.hostTimeout = hostTimeout
        self.memory = memory
    }

    /// Tries the addresses in order (the last one that worked first). A server that refuses the token ends the search:
    /// it is there. A certificate that is not the pinned one does not: another address may be the real server, but if
    /// no address works the answer is the mismatch, which is worth more than "no answer".
    public func connect() async throws {
        let parsed = memory.ordered(hosts, for: fingerprint).compactMap { DirectHost.parse($0) }
        guard !parsed.isEmpty else {
            throw RPCError(code: RPCError.disconnected, message: "the server has no usable address")
        }
        guard PinnedFingerprint.normalize(fingerprint) != nil else {
            throw RPCError(code: RPCError.insecureTransport, message: "refusing to connect without a certificate pin")
        }
        var mismatch = false
        var lastError: Error = RPCError(code: RPCError.disconnected, message: "no address answered")
        for host in parsed {
            try Task.checkCancellation()
            guard let url = host.rpcURL else { continue }
            let transport = WebSocketTransport(url: url, token: token, pinnedFingerprint: fingerprint)
            do {
                try await transport.connect()
                try await transport.awaitOpen(timeout: hostTimeout)
                inner = transport
                connectedHost = host.text
                memory.remember(host.text, for: fingerprint)
                return
            } catch {
                await transport.close()
                if let rpc = error as? RPCError {
                    if rpc.code == RPCError.fingerprintMismatch.code {
                        mismatch = true
                        continue
                    }
                    // The server is there and refuses (the token, or too many tries): the other addresses are the same server.
                    if rpc.code == RPCError.keyRejected || rpc.code == RPCError.rateLimited { throw rpc }
                }
                lastError = error
            }
        }
        throw mismatch ? RPCError.fingerprintMismatch : lastError
    }

    public func send(_ text: String) async throws {
        guard let inner else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        try await inner.send(text)
    }

    public func receive() async throws -> String {
        guard let inner else { throw RPCError(code: RPCError.disconnected, message: "not connected") }
        return try await inner.receive()
    }

    public func close() async {
        await inner?.close()
        inner = nil
    }
}
