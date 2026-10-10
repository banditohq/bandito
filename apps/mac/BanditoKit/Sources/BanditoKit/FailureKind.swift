import Foundation
import Network

/// What went wrong, in terms an interface can word. This file only classifies; the words for each kind
/// live in BanditoUI (`UserFacingError`), so the Kit keeps no text for people.
public enum FailureKind: Hashable, Sendable {
    /// The server does not answer: no socket, refused or reset connection, a timeout, a lost link.
    case noAnswer
    /// The server no longer accepts this device (`RPCError.unauthorized`).
    case deviceRevoked
    /// The server answers, and refuses this device's key at the WebSocket handshake (HTTP 401/403): it lost its data,
    /// was reinstalled, or the device was removed. Not the same as `.noAnswer`: retrying cannot help.
    case keyRejected
    /// A short reason from the daemon: `data.reason`, or the word before the colon in an RPC message
    /// (`not_found: terminal not found`). Always lower-case snake_case.
    case reason(String)
    /// Anything else. `technical` is the raw text, shown only on request.
    case other(technical: String)

    /// Classifies any error the app meets. Transport errors (`NWError`, POSIX and URL network codes) become
    /// `.noAnswer`; RPC errors keep their code or reason; the rest keep their technical description.
    public static func classify(_ error: Error) -> FailureKind {
        if let rpc = error as? RPCError {
            switch rpc.code {
            case RPCError.disconnected, RPCError.timedOut: return .noAnswer
            case RPCError.unauthorized: return .deviceRevoked
            case RPCError.keyRejected: return .keyRejected
            default: break
            }
            if let reason = rpc.reason ?? leadingReason(of: rpc.message) { return .reason(reason) }
            return .other(technical: rpc.message)
        }
        if isTransport(error) { return .noAnswer }
        return .other(technical: String(describing: error))
    }

    /// The reason at the start of a message, when the message starts with `snake_case:`.
    static func leadingReason(of message: String) -> String? {
        guard let colon = message.firstIndex(of: ":") else { return nil }
        let token = message[..<colon]
        guard !token.isEmpty, token.allSatisfy({ ($0.isASCII && $0.isLowercase) || $0 == "_" }) else { return nil }
        return String(token)
    }

    static func isTransport(_ error: Error) -> Bool {
        if error is NWError { return true }
        if let url = error as? URLError { return transportURLCodes.contains(url.code) }
        let nsError = error as NSError
        if nsError.domain == "Network.NWError" { return true }
        if nsError.domain == NSPOSIXErrorDomain { return transportPOSIXCodes.contains(nsError.code) }
        return false
    }

    private static let transportURLCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
        .networkConnectionLost, .notConnectedToInternet,
    ]

    private static let transportPOSIXCodes: Set<Int> = [
        Int(ENOENT), Int(ECONNREFUSED), Int(ECONNRESET), Int(ECONNABORTED), Int(ETIMEDOUT),
        Int(EPIPE), Int(ENOTCONN), Int(EHOSTUNREACH), Int(ENETUNREACH), Int(ENETDOWN),
    ]
}
