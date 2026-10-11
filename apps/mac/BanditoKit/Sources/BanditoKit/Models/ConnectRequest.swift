import Foundation

// The agent's request to connect a catalog service: docs/ARCHITECTURE.md#connect-requests.

/// How a connect request ended (`status` of `integration_request_ended`).
public enum ConnectStatus: String, ForwardCompatibleEnum, CaseIterable {
    case connected, declined, expired

    /// A way of ending this app does not know has closed the request all the same: `expired` offers nothing more.
    public static var fallback: ConnectStatus { .expired }
}

/// The end of a connect request, as the thread keeps it.
public enum ConnectOutcome: Sendable, Hashable {
    /// The person connected the service; `integration` is the name of the integration the daemon made or found.
    case connected(integration: String?)
    case declined
    case expired
}

/// A connect request in the thread. `outcome` is nil while the agent waits for the person.
public struct ConnectRow: Sendable, Hashable {
    public var requestId: String
    /// The catalog id of the service (`github`, `composio`).
    public var service: String
    /// Why the agent needs it, in its own words. Nil or empty when it gave none.
    public var reason: String?
    public var outcome: ConnectOutcome?
    /// Unix milliseconds of the request.
    public var ts: Int64

    public init(requestId: String, service: String, reason: String? = nil, outcome: ConnectOutcome? = nil, ts: Int64) {
        self.requestId = requestId
        self.service = service
        self.reason = reason
        self.outcome = outcome
        self.ts = ts
    }

    public var isPending: Bool { outcome == nil }

    /// The reason without blanks around it; nil when there is nothing to show.
    public var shownReason: String? {
        let text = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
