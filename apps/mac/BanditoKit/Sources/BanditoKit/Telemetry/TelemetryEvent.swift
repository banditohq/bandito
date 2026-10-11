import Foundation

/// What the app counts. The names are the contract's whitelist (`counters` of `telemetry/pulse`): a use of a
/// feature becomes one of these names and a day's count. Nothing else leaves the Mac: no text, no ids of
/// agents or files, no addresses.
public enum TelemetryEvent: Hashable, Sendable {
    /// A main section was opened (`screen.<name>.open`).
    case screen(Screen)
    /// An agent was created: plain, from a template, from a bundle (a set), or from a link.
    case agentCreate(AgentCreateSource)
    /// A service was connected by its catalog id; the connect worked (`ok`) or failed (`fail`).
    case integration(CatalogCounterID, ok: Bool)
    case skillInstall
    case sharePublish
    case shareInstall
    case dictationUse
    /// The person answered an approval: allowed or denied.
    case approval(ApprovalChoice)
    case telegramLink
    case importRun
    case formReply
    /// An agent turn ended (any status), counted once per turn.
    case turnComplete
    /// An agent turn ended without `ok`: `turn.fail.<kind>`.
    case turnFail(TurnFailure)

    public enum Screen: String, CaseIterable, Sendable {
        case team, market, settings, terminals, files, browser
    }

    public enum AgentCreateSource: String, CaseIterable, Sendable {
        case plain, template, bundle, shared
    }

    public enum ApprovalChoice: String, CaseIterable, Sendable {
        case allow, deny
    }

    /// How a turn ended badly. Only these names leave the Mac; a status the app does not know counts as `other`.
    public enum TurnFailure: String, CaseIterable, Sendable {
        case error, interrupted, other

        init(status: TurnStatus) {
            switch status {
            case .error: self = .error
            case .interrupted: self = .interrupted
            case .ok: self = .other
            }
        }
    }

    /// The counter name, as the server knows it.
    public var name: String {
        switch self {
        case .screen(let screen): "screen.\(screen.rawValue).open"
        case .agentCreate(.plain): "agent.create"
        case .agentCreate(let source): "agent.create.\(source.rawValue)"
        case .integration(let id, let ok): "integration.connect.\(id.value).\(ok ? "ok" : "fail")"
        case .skillInstall: "skill.install"
        case .sharePublish: "share.publish"
        case .shareInstall: "share.install"
        case .dictationUse: "dictation.use"
        case .approval(let choice): "approval.\(choice.rawValue)"
        case .telegramLink: "telegram.link"
        case .importRun: "import.run"
        case .formReply: "form.reply"
        case .turnComplete: "turn.complete"
        case .turnFail(let kind): "turn.fail.\(kind.rawValue)"
        }
    }

    /// The names without a catalog id. The integration names are checked by shape in `isAllowedName`.
    private static let fixedNames: Set<String> = {
        var names = Set(Screen.allCases.map { "screen.\($0.rawValue).open" })
        names.formUnion([
            "agent.create", "agent.create.template", "agent.create.bundle", "agent.create.shared",
            "skill.install", "share.publish", "share.install", "dictation.use", "approval.allow", "approval.deny",
            "telegram.link", "import.run", "form.reply", "turn.complete",
        ])
        names.formUnion(TurnFailure.allCases.map { "turn.fail.\($0.rawValue)" })
        return names
    }()

    /// Whether `name` is one of the counters the contract accepts. The payload builder drops every other name.
    public static func isAllowedName(_ name: String) -> Bool {
        if fixedNames.contains(name) { return true }
        // integration.connect.<catalog id>.(ok|fail)
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "integration", parts[1] == "connect",
            parts[3] == "ok" || parts[3] == "fail"
        else { return false }
        return CatalogCounterID(String(parts[2])) != nil
    }
}

/// A catalog id as it may appear in a counter name: 1 to 40 characters of lowercase latin letters, digits, `-` and
/// `_`, starting with a letter or a digit. Anything else (spaces, paths, uppercase) is not a catalog id.
public struct CatalogCounterID: Hashable, Sendable {
    public let value: String

    public init?(_ raw: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        guard (1...40).contains(raw.count), let first = raw.first, first != "-", first != "_",
            raw.allSatisfy(allowed.contains)
        else { return nil }
        value = raw
    }
}
