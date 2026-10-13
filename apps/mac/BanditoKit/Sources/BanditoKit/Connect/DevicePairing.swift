import CryptoKit
import Foundation

// Pairing an iPhone (or any app) with a daemon's phone listener: the request that comes from the link, the QR code or
// the typed address, and the exchange of its one-time code for a device token (docs/ARCHITECTURE.md#phone-access).

/// A server's name as the app shows it. A name comes from the other side of the network (a link, a daemon's host name),
/// so it is cleaned: control characters, format characters (bidi overrides, zero-width marks) and line or paragraph
/// separators are dropped, so a name cannot reorder or hide the text around it. At most 64 Unicode scalars.
public enum ServerNameRules {
    public static let maxScalars = 64

    /// The cleaned name, or `fallback` (cleaned the same way) when nothing is left.
    public static func clean(_ name: String, fallback: String = "") -> String {
        let cleaned = scrub(name)
        return cleaned.isEmpty ? scrub(fallback) : cleaned
    }

    private static let dropped: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]

    private static func scrub(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { !dropped.contains($0.properties.generalCategory) }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: kept.prefix(maxScalars + 64))
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: trimmed.unicodeScalars.prefix(maxScalars))
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the person gave: where the server is, the one-time code, and the certificate fingerprint to trust.
public struct PairRequest: Sendable, Hashable {
    /// Six words joined by `-`.
    public var code: String
    /// 64 lower-case hex digits. nil only for an address typed by hand with no fingerprint: the app then shows the
    /// fingerprint the server presents and asks the person (`FingerprintProbe`) before it sends the code.
    public var fingerprint: String?
    /// What the server calls itself (at most 64 characters). Never empty.
    public var name: String
    /// `host:port` addresses, the best first. At least one.
    public var hosts: [String]
    /// The name is only the address the person typed: the pairing asks the server for its own name instead.
    public var nameIsGuess: Bool
    /// Bandito Relay, when the link names it: the phone can reach the server through the cloud. With it `hosts` and
    /// `fingerprint` may be empty (relay only).
    public var relay: RelayRoute?
    /// The daemon's Noise key (base64url) that goes with `relay`.
    public var noiseKey: String?

    public init(
        code: String, fingerprint: String?, name: String, hosts: [String], nameIsGuess: Bool = false,
        relay: RelayRoute? = nil, noiseKey: String? = nil
    ) {
        self.code = code
        self.fingerprint = fingerprint
        self.name = name
        self.hosts = hosts
        self.nameIsGuess = nameIsGuess
        self.relay = relay
        self.noiseKey = noiseKey
    }

    /// Whether the server can only be reached through the relay (no address, nothing to pin).
    public var isRelayOnly: Bool { hosts.isEmpty && relay != nil }
}

/// Why what the person gave cannot be used. The words for each are in the app.
public enum PairInputError: Error, Sendable, Hashable {
    /// The text is not a Bandito pairing link.
    case notALink
    /// The link is of a version this app does not know: update the app.
    case updateApp
    /// The code is not six words.
    case badCode
    /// The fingerprint is not 64 hex digits.
    case badFingerprint
    /// No address in the link, or none typed.
    case noAddress
    /// The address typed is not `host` or `host:port`.
    case badAddress
    /// The link's `relay` or `nk` does not read.
    case badRelay
}

public enum PairInput {
    /// Whether `text` holds a pairing link (the paste button offers it, and nothing else).
    public static func containsLink(_ text: String) -> Bool {
        link(in: text) != nil
    }

    /// The first `bandito://pair…` word of a text, so a link pasted inside a message still works.
    static func link(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init).first {
            $0.lowercased().hasPrefix("\(PairLink.scheme)://pair")
        }
    }

    /// Reads a pairing link: `bandito://pair?v=1&code=…&fp=…&name=…&host=…&host=…`.
    public static func parseLink(_ text: String) throws -> PairRequest {
        guard let word = link(in: text) else { throw PairInputError.notALink }
        let parsed: PhonePairLink
        do {
            parsed = try PhonePairLink.parse(word)
        } catch let problem as PhonePairLink.Problem {
            switch problem {
            case .notALink: throw PairInputError.notALink
            case .unsupportedVersion: throw PairInputError.updateApp
            case .badCode: throw PairInputError.badCode
            case .badFingerprint: throw PairInputError.badFingerprint
            case .noHosts: throw PairInputError.noAddress
            case .badRelay: throw PairInputError.badRelay
            }
        }
        // An address that does not read is dropped: the others may. Duplicates go too.
        var hosts: [String] = []
        for text in parsed.hosts {
            if let host = DirectHost.parse(text)?.text, !hosts.contains(host) { hosts.append(host) }
        }
        // Without a usable address the relay is the way; with neither there is nothing to connect to.
        guard !hosts.isEmpty || parsed.relay != nil else { throw PairInputError.noAddress }
        let fallback = hosts.first ?? parsed.relay?.host ?? ""
        return PairRequest(
            code: parsed.code, fingerprint: hosts.isEmpty ? nil : parsed.fingerprint,
            name: ServerNameRules.clean(parsed.name, fallback: fallback), hosts: hosts, relay: parsed.relay,
            noiseKey: parsed.noiseKey)
    }

    /// Reads what was typed: an address (`host`, `host:port`, `[v6]:port`), the six-word code, and the fingerprint if the
    /// person has it (empty is allowed: the app asks the server for it and shows it).
    public static func parseManual(address: String, code: String, fingerprint: String) throws -> PairRequest {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PairInputError.noAddress }
        guard let host = DirectHost.parse(address) else { throw PairInputError.badAddress }
        guard let code = normalizeCode(code) else { throw PairInputError.badCode }
        var pin: String?
        if !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let normalized = PinnedFingerprint.normalize(fingerprint) else { throw PairInputError.badFingerprint }
            pin = normalized
        }
        return PairRequest(code: code, fingerprint: pin, name: host.host, hosts: [host.text], nameIsGuess: true)
    }

    /// `Otter Lava, mint-orbit crane  fig` → `otter-lava-mint-orbit-crane-fig`. nil unless it is six words of letters.
    public static func normalizeCode(_ text: String) -> String? {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "," || $0 == "." })
            .map(String.init)
        guard words.count == 6, words.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLetter } }) else {
            return nil
        }
        return words.joined(separator: "-")
    }
}

/// A server that paired: its saved config (with the token, which the caller keeps in the Keychain) and the id the
/// daemon gave this device.
public struct PairedDevice: Sendable {
    public var config: ServerConfig
    public var deviceID: String

    public init(config: ServerConfig, deviceID: String) {
        self.config = config
        self.deviceID = deviceID
    }
}

/// What went wrong with a pairing, in the cases the app words differently.
public enum PairFailure: Sendable, Hashable {
    /// The code was refused: wrong, used, or older than ten minutes.
    case codeRejected
    /// Too many tries from this device's address: wait a few minutes.
    case tooManyAttempts
    /// The address answers with a certificate that is not the one pinned: the loudest warning.
    case fingerprintMismatch
    /// Nothing answered: the server is off, the address is wrong, or the phone is not on the same network.
    case unreachable
    /// Anything else.
    case other

    public static func classify(_ error: Error) -> PairFailure {
        if let rpc = error as? RPCError {
            switch rpc.code {
            case RPCError.unauthorized: return .codeRejected
            case RPCError.rateLimited: return .tooManyAttempts
            case RPCError.fingerprintMismatch.code: return .fingerprintMismatch
            case RPCError.disconnected, RPCError.timedOut: return .unreachable
            default: return .other
            }
        }
        return FailureKind.classify(error) == .noAnswer ? .unreachable : .other
    }
}

public enum DevicePairing {
    /// Connects to the server (its addresses in order, the certificate pinned; then Bandito Relay when the link names it),
    /// swaps the one-time code for a device token, and returns the server's config: `.direct` when the link has no relay
    /// (the old shape), else `.reachable`, with the key this device made for the relay. `fingerprint` is the pin: the one
    /// from the link, or the one the person confirmed; nil only for a relay-only link.
    public static func redeem(
        _ request: PairRequest, fingerprint: String?, deviceName: String,
        hostTimeout: Duration = DirectTransport.defaultHostTimeout, memory: DirectHostMemory = .shared,
        relayTimeout: Duration = RelayTransport.defaultTimeout
    ) async throws -> PairedDevice {
        var pin: String?
        if !request.hosts.isEmpty {
            guard let normalized = fingerprint.flatMap({ PinnedFingerprint.normalize($0) }) else {
                throw PairInputError.badFingerprint
            }
            pin = normalized
        }
        var phoneKey: Curve25519.KeyAgreement.PrivateKey?
        var daemonKey: Data?
        if let relay = request.relay {
            guard RelayRoute.isSID(relay.sid), let text = request.noiseKey, let key = Base64URL.key(text) else {
                throw PairInputError.badRelay
            }
            daemonKey = key
            phoneKey = Curve25519.KeyAgreement.PrivateKey()
        } else if pin == nil {
            throw PairInputError.badFingerprint
        }
        let transport = ReachableTransport(
            hosts: pin == nil ? [] : request.hosts, fingerprint: pin, relay: request.relay, daemonKey: daemonKey,
            phoneKey: phoneKey, token: nil, directTimeout: request.relay == nil ? hostTimeout : min(hostTimeout, .seconds(3)),
            relayTimeout: relayTimeout, memory: memory)
        let client = RPCClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }
        // An address typed by hand gives no name: ask the daemon for its host name (an anonymous call it answers).
        var name = request.name
        if request.nameIsGuess {
            struct Hello: Decodable { var hostname: String? }
            if let hello = try? await client.call("daemon.hello", NoParams(), as: Hello.self, timeout: .seconds(5)),
                let hostname = hello.hostname
            {
                name = ServerNameRules.clean(hostname, fallback: request.name)
            }
        }
        struct Params: Encodable {
            var code: String
            var deviceName: String
            var noiseKey: String?
        }
        let paired = try await client.call(
            "pair.redeem",
            Params(code: request.code, deviceName: deviceName, noiseKey: phoneKey.map { Base64URL.encode($0.publicKey.rawRepresentation) }),
            as: PairResult.self, timeout: .seconds(15))
        var hosts = request.hosts
        if case .network? = await transport.connectedRoute, let pin,
            let worked = memory.lastGood(for: pin), let index = hosts.firstIndex(of: worked), index != 0
        {
            hosts.remove(at: index)
            hosts.insert(worked, at: 0)
        }
        let endpoint: ServerEndpoint
        var secret: String?
        if let relay = request.relay, let phoneKey {
            endpoint = .reachable(hosts: hosts, fingerprint: pin, relay: relay, noiseKey: request.noiseKey)
            secret = Base64URL.encode(phoneKey.rawRepresentation)
        } else if let pin {
            endpoint = .direct(hosts: hosts, fingerprint: pin)
        } else {
            throw PairInputError.badFingerprint
        }
        let config = ServerConfig(name: name, endpoint: endpoint, token: paired.token, noiseSecret: secret)
        return PairedDevice(config: config, deviceID: paired.device.id)
    }

    /// Takes a device back off the daemon (`devices.revoke`) over a connection its own token opens. For a token the app
    /// could not keep, so the daemon does not list a device that nobody holds. Best effort: it never throws.
    public static func revoke(_ device: PairedDevice) async {
        guard device.config.endpoint.isPaired, let token = device.config.token, !token.isEmpty else { return }
        let transport = ReachableTransport(config: device.config)
        let client = RPCClient(transport: transport)
        guard (try? await client.start()) != nil else { return }
        struct Params: Encodable { var id: String }
        try? await client.call("devices.revoke", Params(id: device.deviceID), timeout: .seconds(10))
        await client.close()
    }
}

extension DevicePairing {
    /// Disconnects this device from a server it is paired with: asks the server to forget the device (the one whose key
    /// this is: `devices.list` marks it `current`), over a connection of its own with the stored token. False when the
    /// server could not be reached or refused (the caller forgets the server on this device either way).
    public static func revokeSelf(config: ServerConfig, timeout: Duration = .seconds(10)) async -> Bool {
        guard config.endpoint.isPaired, let token = config.token, !token.isEmpty else { return false }
        let transport = ReachableTransport(config: config, directTimeout: timeout)
        let client = RPCClient(transport: transport)
        defer { Task { await client.close() } }
        do {
            try await client.start()
            let devices = try await client.call("devices.list", NoParams(), as: [Device].self, timeout: timeout)
            guard let me = devices.first(where: { $0.current == true }) else { return false }
            struct Params: Encodable { var id: String }
            try await client.call("devices.revoke", Params(id: me.id), timeout: timeout)
            return true
        } catch {
            return false
        }
    }
}
