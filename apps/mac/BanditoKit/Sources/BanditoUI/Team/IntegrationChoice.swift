import BanditoKit
import Foundation

/// Which integrations an agent may use: every enabled one (the default, sent as `null`), or the picked ones.
/// Pure: the chips bind to it, and the request is built from it.
public enum IntegrationChoice: Equatable, Sendable {
    case all
    case picked(Set<String>)

    /// The choice an agent's wire list stands for. `nil` (every enabled one) is `.all`.
    public static func from(_ ids: [String]?) -> IntegrationChoice {
        guard let ids else { return .all }
        return .picked(Set(ids))
    }

    /// The choice without the ids the server does not have (an integration removed since it was picked). A picked
    /// id that is gone must not be sent: the daemon refuses an unknown id. `.all` stays `.all`.
    public func limited(to existing: Set<String>) -> IntegrationChoice {
        switch self {
        case .all: .all
        case .picked(let ids): .picked(ids.intersection(existing))
        }
    }

    /// The ids for `agents.create`: nil when every enabled one is meant, so the field is left out.
    public var wireIDs: [String]? {
        switch self {
        case .all: nil
        case .picked(let ids): ids.sorted()
        }
    }

    /// The change for `agents.update`: `.clear` sends `null` (every enabled one), a set sends the picked ids.
    public var patchChange: FieldChange<[String]> {
        switch self {
        case .all: .clear
        case .picked(let ids): .set(ids.sorted())
        }
    }

    /// Whether a chip is on. In `.all`, the enabled integrations are on; a disabled one never is.
    public func isOn(_ id: String, enabled: Set<String>) -> Bool {
        switch self {
        case .all: enabled.contains(id)
        case .picked(let ids): ids.contains(id)
        }
    }

    /// The choice after one chip is clicked. Leaving the picked set equal to the enabled integrations is `.all` again.
    public func toggled(_ id: String, enabled: Set<String>) -> IntegrationChoice {
        var ids: Set<String>
        switch self {
        case .all: ids = enabled
        case .picked(let picked): ids = picked
        }
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        return ids == enabled ? .all : .picked(ids)
    }
}
