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
    /// A browser sign-in the service no longer accepts: the owner signs in again.
    case needsLogin

    /// The status from the row and the last check the app ran in this session (`nil` when there was none).
    /// `connection` is the daemon's word on a browser sign-in (`integrations.oauth_status`), when it gave one.
    public static func of(
        _ integration: Integration, test: IntegrationTest?, connection: OAuthConnection? = nil
    ) -> IntegrationStatus {
        guard integration.enabled else { return .disabled }
        if integration.auth == .oauth {
            if connection == .needsLogin || connection == .notConnected || test?.needsLogin == true {
                return .needsLogin
            }
        }
        guard let test else { return .unchecked }
        if test.ok { return .connected(tools: test.tools.count) }
        return .failed(IntegrationFailure.classify(test.error))
    }
}
