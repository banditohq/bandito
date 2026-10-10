import BanditoKit
import Foundation

/// Why an integration check failed, in the few kinds the app words for the owner. The daemon sends the server's
/// stderr; the kind is read from its text, and anything unknown is `other`.
public enum IntegrationFailure: Equatable, Sendable {
    /// The program the integration starts is not on the server.
    case missingProgram
    /// The server answered, but refused the key or the token.
    case rejected
    /// The address or the host could not be reached.
    case unreachable
    /// The server did not answer in time.
    case timeout
    case other

    public static func classify(_ raw: String?) -> IntegrationFailure {
        guard let raw, !raw.isEmpty else { return .other }
        let text = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("enoent", "no such file", "command not found", "executable file not found") {
            return .missingProgram
        }
        if has("timed out", "timeout", "time out") {
            return .timeout
        }
        if has("401", "403", "unauthorized", "forbidden", "invalid api key", "invalid_api_key", "authentication") {
            return .rejected
        }
        if has("connection refused", "could not resolve", "failed to connect", "couldn't connect", "network is unreachable") {
            return .unreachable
        }
        return .other
    }
}

/// What the integrations list says about one integration: off, not checked yet, working with its tools, or failed.
public enum IntegrationStatus: Equatable, Sendable {
    case disabled
    case unchecked
    case connected(tools: Int)
    case failed(IntegrationFailure)

    /// The status from the row and the last check the app ran in this session (`nil` when there was none).
    public static func of(_ integration: Integration, test: IntegrationTest?) -> IntegrationStatus {
        guard integration.enabled else { return .disabled }
        guard let test else { return .unchecked }
        if test.ok { return .connected(tools: test.tools.count) }
        return .failed(IntegrationFailure.classify(test.error))
    }
}
