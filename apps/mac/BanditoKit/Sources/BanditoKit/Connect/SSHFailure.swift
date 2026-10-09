import Foundation

/// What went wrong with an ssh connection, named the way the person can act on it. Built from ssh's own stderr:
/// one message per class in the tests, copied from real ssh output.
public enum SSHFailure: Equatable, Sendable {
    /// `Host key verification failed`: the host is new to this Mac. Trust is offered, after the fingerprint is shown.
    case hostKeyUnknown
    /// `REMOTE HOST IDENTIFICATION HAS CHANGED`: the key differs from the one on file. Never offered for trust.
    case hostKeyChanged
    /// `Permission denied (publickey…)`: the server does not accept this Mac's key.
    case keyNotAccepted
    /// `Could not resolve hostname`: no such name.
    case unknownHost
    /// `Connection refused`: nothing listens on that port.
    case refused
    /// `Connection timed out` / `Operation timed out`: no answer.
    case timedOut
    /// `No route to host` / `Network is unreachable`.
    case noRoute
    /// Anything else. The payload is the last non-empty line of stderr.
    case other(String)

    public static func classify(stderr: String) -> SSHFailure {
        if stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged }
        if stderr.contains("Host key verification failed") { return .hostKeyUnknown }
        if stderr.contains("Permission denied") { return .keyNotAccepted }
        if stderr.contains("Could not resolve hostname") { return .unknownHost }
        if stderr.contains("Connection refused") { return .refused }
        if stderr.contains("timed out") { return .timedOut }
        if stderr.contains("No route to host") || stderr.contains("Network is unreachable") { return .noRoute }
        let lastLine = stderr.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        return .other(lastLine ?? "")
    }

    /// A short English description, for logs and the default error text. The app shows localized text instead.
    public var englishDescription: String {
        switch self {
        case .hostKeyUnknown: return "The server's host key is not known to this Mac."
        case .hostKeyChanged: return "The server's host key changed. Check the server before connecting."
        case .keyNotAccepted: return "The server does not accept this Mac's key."
        case .unknownHost: return "The host name does not resolve."
        case .refused: return "The server refused the connection."
        case .timedOut: return "The server did not answer."
        case .noRoute: return "There is no network route to the server."
        case .other(let detail): return detail.isEmpty ? "ssh failed." : detail
        }
    }
}
