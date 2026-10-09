import Foundation

// Pairing another device with this server: `pair.create` makes a one-time code (docs/ARCHITECTURE.md#transports).

/// A one-time code for a new device. The code is good for `expiresInMs` (ten minutes today).
public struct PairCode: Codable, Sendable, Hashable {
    public var code: String
    public var expiresInMs: Int64
}

extension ServerModel {
    /// Creates a code that another device can redeem with `pair.redeem`.
    public func createPairCode() async throws -> PairCode {
        try await rpc().call("pair.create", NoParams(), as: PairCode.self)
    }
}

/// The link a pairing QR code carries: `bandito://pair?code=…&host=…`.
public enum PairLink {
    public static let scheme = "bandito"

    /// Both values are percent-encoded so that neither can add a parameter of its own.
    public static func url(code: String, host: String) -> String {
        "\(scheme)://pair?code=\(escape(code))&host=\(escape(host))"
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
