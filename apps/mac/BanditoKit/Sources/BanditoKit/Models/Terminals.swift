import Foundation

// Wire models for `term.*` (docs/ARCHITECTURE.md#terminals).

/// Lifecycle of a terminal. On the wire: `{"state":"running"}` or
/// `{"state":"exited","code":…,"signal":…}` (code or signal may be null).
public enum TermState: Sendable, Hashable, Codable {
    case running
    case exited(code: Int?, signal: Int?)

    private struct Wire: Codable {
        var state: String
        var code: Int?
        var signal: Int?
    }

    public init(from decoder: Decoder) throws {
        let wire = try Wire(from: decoder)
        switch wire.state {
        case "exited": self = .exited(code: wire.code, signal: wire.signal)
        // A state this app doesn't know: a terminal is running until the daemon says otherwise.
        default: self = .running
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .running:
            try Wire(state: "running", code: nil, signal: nil).encode(to: encoder)
        case .exited(let code, let signal):
            try Wire(state: "exited", code: code, signal: signal).encode(to: encoder)
        }
    }
}

/// A terminal on the server (`TermInfo` on the wire).
public struct TermInfo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var cwd: String
    public var command: [String]
    public var pid: Int
    public var cols: Int
    public var rows: Int
    /// Unix milliseconds.
    public var createdAt: Int64
    public var state: TermState
    /// Total bytes of output so far (not only the retained part).
    public var offset: UInt64
}
