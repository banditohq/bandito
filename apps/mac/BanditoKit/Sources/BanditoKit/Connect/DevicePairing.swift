import Foundation

// Pairing an iPhone (or any app) with a daemon's phone listener: the request that comes from the link, the QR code or
// the typed address, and the exchange of its one-time code for a device token (docs/ARCHITECTURE.md#phone-access).

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

    public init(code: String, fingerprint: String?, name: String, hosts: [String]) {
        self.code = code
        self.fingerprint = fingerprint
        self.name = name
        self.hosts = hosts
    }
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
            }
        }
        // An address that does not read is dropped: the others may. Duplicates go too.
        var hosts: [String] = []
        for text in parsed.hosts {
            if let host = DirectHost.parse(text)?.text, !hosts.contains(host) { hosts.append(host) }
        }
        guard !hosts.isEmpty else { throw PairInputError.noAddress }
        return PairRequest(code: parsed.code, fingerprint: parsed.fingerprint, name: cleanName(parsed.name, fallback: hosts[0]), hosts: hosts)
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
        return PairRequest(code: code, fingerprint: pin, name: host.host, hosts: [host.text])
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

    private static func cleanName(_ name: String, fallback: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(PhonePairLink.maxNameCharacters))
    }
}

/// A server that paired: its saved config (with the token, which the caller keeps in the Keychain) and the id the
/// daemon gave this device.
public struct PairedDevice: Sendable {
    public var config: ServerConfig
    public var deviceID: String
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
    /// Connects to the server (its addresses in order, the certificate pinned), swaps the one-time code for a device
    /// token, and returns the server's config with a `.direct` endpoint whose first address is the one that worked.
    /// `fingerprint` is the pin: the one from the link, or the one the person confirmed.
    public static func redeem(
        _ request: PairRequest, fingerprint: String, deviceName: String,
        hostTimeout: Duration = DirectTransport.defaultHostTimeout, memory: DirectHostMemory = .shared
    ) async throws -> PairedDevice {
        guard let pin = PinnedFingerprint.normalize(fingerprint) else { throw PairInputError.badFingerprint }
        let transport = DirectTransport(
            hosts: request.hosts, fingerprint: pin, token: nil, hostTimeout: hostTimeout, memory: memory)
        let client = RPCClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }
        struct Params: Encodable {
            var code: String
            var deviceName: String
        }
        let paired = try await client.call(
            "pair.redeem", Params(code: request.code, deviceName: deviceName), as: PairResult.self,
            timeout: .seconds(15))
        var hosts = request.hosts
        if let worked = await transport.connectedHost, let index = hosts.firstIndex(of: worked), index != 0 {
            hosts.remove(at: index)
            hosts.insert(worked, at: 0)
        }
        let config = ServerConfig(
            name: request.name, endpoint: .direct(hosts: hosts, fingerprint: pin), token: paired.token)
        return PairedDevice(config: config, deviceID: paired.device.id)
    }

    /// Takes a device back off the daemon (`devices.revoke`) over a connection its own token opens. For a token the app
    /// could not keep, so the daemon does not list a device that nobody holds. Best effort: it never throws.
    public static func revoke(_ device: PairedDevice) async {
        guard case .direct(let hosts, let fingerprint) = device.config.endpoint, let token = device.config.token else { return }
        let transport = DirectTransport(hosts: hosts, fingerprint: fingerprint, token: token)
        let client = RPCClient(transport: transport)
        guard (try? await client.start()) != nil else { return }
        struct Params: Encodable { var id: String }
        try? await client.call("devices.revoke", Params(id: device.deviceID), timeout: .seconds(10))
        await client.close()
    }
}
