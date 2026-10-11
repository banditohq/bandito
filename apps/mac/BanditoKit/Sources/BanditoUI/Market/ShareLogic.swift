import BanditoKit
import BanditoL10n
import Foundation

/// What a share sheet is about: a bot of a server, or a skill in the daemon user's folder.
public enum ShareSubject: Hashable, Sendable {
    case bot(agentID: String)
    case skill(name: String)

    public var kind: ShareKind {
        switch self {
        case .bot: .bot
        case .skill: .skill
        }
    }
}

/// Where a shared item came from, kept per share on this Mac. "Update to the current version" exports again from it.
public struct ShareSource: Codable, Equatable, Sendable {
    public var kind: ShareKind
    /// The `Server.id` (UUID string) the item was exported from.
    public var serverID: String
    /// The agent of a bot share.
    public var agentID: String?
    /// The folder name of a skill share.
    public var skillName: String?

    public init(kind: ShareKind, serverID: String, agentID: String? = nil, skillName: String? = nil) {
        self.kind = kind
        self.serverID = serverID
        self.agentID = agentID
        self.skillName = skillName
    }
}

/// The sources of the shares of this Mac, per share id, in the app's own defaults.
public enum ShareSourceStore {
    static let key = "share.sources.v1"

    public static func load(defaults: UserDefaults = .standard) -> [String: ShareSource] {
        guard let data = defaults.data(forKey: key),
            let sources = try? JSONDecoder().decode([String: ShareSource].self, from: data)
        else { return [:] }
        return sources
    }

    public static func remember(_ source: ShareSource, for shareID: String, defaults: UserDefaults = .standard) {
        var sources = load(defaults: defaults)
        sources[shareID] = source
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: key)
        }
    }

    public static func forget(_ shareID: String, defaults: UserDefaults = .standard) {
        var sources = load(defaults: defaults)
        sources.removeValue(forKey: shareID)
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: key)
        }
    }
}

/// What a bot or skill payload shows on screen: its name, what it does, and what it would change on this Mac.
/// Read from the payload as JSON, so the screen shows exactly what the daemon will install.
public struct SharedPayloadInfo: Equatable, Sendable {
    public var kind: ShareKind
    public var name: String
    /// Bot: the role line.
    public var role: String?
    /// Bot: the system prompt, the text the agent runs on.
    public var systemPrompt: String?
    /// Bot: the capability names it asks for.
    public var capabilities: [String]
    /// Bot: how many catalog services it names.
    public var serviceCount: Int
    /// Bot: how many schedules it carries.
    public var scheduleCount: Int
    /// Bot: the first message, put in the input field.
    public var starter: String?
    /// Skill: the description line.
    public var description: String?
    /// Skill: the license the owner chose.
    public var license: String?
    /// Skill: the file paths, in order.
    public var files: [String]
    /// Skill: the paths of the scripts agents may run.
    public var executables: [String]

    public init?(kind: ShareKind, payload: JSONValue) {
        guard let name = payload["name"]?.string, !name.isEmpty else { return nil }
        self.kind = kind
        self.name = name
        role = payload["role"]?.string
        systemPrompt = payload["system_prompt"]?.string
        capabilities = Self.strings(payload["capabilities"])
        serviceCount = Self.count(payload["services"])
        scheduleCount = Self.count(payload["schedules"])
        starter = payload["starter"]?.string
        description = payload["description"]?.string
        license = payload["license"]?.string
        files = Self.files(payload["files"])
        executables = Self.strings(payload["executable"])
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.string)
    }

    private static func count(_ value: JSONValue?) -> Int {
        guard case .array(let items)? = value else { return 0 }
        return items.count
    }

    private static func files(_ value: JSONValue?) -> [String] {
        guard case .object(let map)? = value else { return [] }
        return map.keys.sorted()
    }
}

/// Logic of the share screens: ids and links, the limits of a draft, the texts of the failures and the states of the
/// buttons. Pure, so the rules are tested without a server.
public enum ShareLogic {
    public static let titleLimit = 80
    public static let summaryLimit = 280
    /// The number of lines of a payload shown before "Show all".
    public static let previewLineLimit = 12
    /// The licenses a skill can be shared under (the platform's list).
    public static let licenses = [
        "MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "MPL-2.0", "CC-BY-4.0", "CC0-1.0", "Unlicense",
    ]
    public static let defaultLicense = "MIT"
    public static let host = "bandito.dev"

    // MARK: capabilities of a shared bot

    /// The capabilities that stay off unless the owner turns them on: running commands, seeing the screen, managing
    /// other agents.
    public static let riskyCapabilities: Set<String> = [
        AgentCapability.terminal.rawValue, AgentCapability.screen.rawValue, AgentCapability.team.rawValue,
    ]

    /// The capabilities of a payload the app offers, in the order of the chips: only the known names, each once.
    public static func offeredCapabilities(_ names: [String]) -> [AgentCapability] {
        AgentCapability.allCases.filter { names.contains($0.rawValue) }
    }

    /// The name of a capability in the install sheet. The risky ones say what they let the bot do.
    public static func capabilityTitle(_ capability: AgentCapability) -> String {
        switch capability {
        case .files: L10n.Share.Capability.files
        case .browser: L10n.Share.Capability.browser
        case .terminal: L10n.Share.Capability.terminal
        case .team: L10n.Share.Capability.team
        case .screen: L10n.Share.Capability.screen
        }
    }

    /// What is on before the owner touches the list: every offered capability except the risky ones.
    public static func defaultCapabilities(_ offered: [AgentCapability]) -> Set<AgentCapability> {
        Set(offered.filter { !riskyCapabilities.contains($0.rawValue) })
    }

    /// The list sent with `agents.create_from_shared`: the chosen ones, in the order of the chips. Always a subset of
    /// the payload's capabilities.
    public static func chosenCapabilities(_ chosen: Set<AgentCapability>, offered: [AgentCapability]) -> [String] {
        offered.filter(chosen.contains).map(\.rawValue)
    }

    // MARK: links

    /// The id in `https://bandito.dev/s/<id>`, or nil for any other text. The text is trimmed first; the scheme must be
    /// `https`, the host `bandito.dev`, with no port, user or query.
    public static func shareID(fromLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            url.host?.lowercased() == host, url.port == nil, url.user == nil, url.query == nil, url.fragment == nil
        else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "s" else { return nil }
        let id = String(parts[2])
        return ShareID.isValid(id) ? id : nil
    }

    /// The id in `bandito://install?share=<id>`, or nil for any other URL.
    public static func installID(fromURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "bandito", url.host?.lowercased() == "install" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = items.filter { $0.name == "share" }.compactMap(\.value)
        guard values.count == 1, let id = values.first, ShareID.isValid(id) else { return nil }
        return id
    }

    public static func pageURL(id: String) -> String {
        "https://\(host)/s/\(id)"
    }

    // MARK: draft

    /// A title of 1 to 80 characters once trimmed.
    public static func isTitleValid(_ title: String) -> Bool {
        let count = title.trimmingCharacters(in: .whitespacesAndNewlines).count
        return (1...titleLimit).contains(count)
    }

    public static func isSummaryValid(_ summary: String) -> Bool {
        summary.count <= summaryLimit
    }

    /// The publish button: a signed-in owner, a valid draft, a payload read from the daemon, and no request running.
    public static func canPublish(
        title: String, summary: String, hasPayload: Bool, signedIn: Bool, inFlight: Bool
    ) -> Bool {
        signedIn && hasPayload && !inFlight && isTitleValid(title) && isSummaryValid(summary)
    }

    /// The install button: a server, a loaded item, no install running, and for a skill with scripts the owner's tick.
    public static func canInstall(
        hasServer: Bool, hasItem: Bool, executables: [String], acknowledged: Bool, inFlight: Bool
    ) -> Bool {
        guard hasServer, hasItem, !inFlight else { return false }
        return executables.isEmpty || acknowledged
    }

    /// The payload as text for the preview and the install sheet: pretty, sorted keys, the exact JSON that is sent.
    public static func payloadText(_ payload: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public struct Preview: Equatable, Sendable {
        /// The first lines (up to `previewLineLimit`) or the whole text when it is short.
        public var shown: String
        /// True when lines were left out and "Show all" is offered.
        public var isCollapsed: Bool
    }

    /// The text cut to `previewLineLimit` lines, for the collapsed view.
    public static func preview(of text: String, lineLimit: Int = previewLineLimit) -> Preview {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > lineLimit else { return Preview(shown: text, isCollapsed: false) }
        return Preview(shown: lines.prefix(lineLimit).joined(separator: "\n"), isCollapsed: true)
    }

    // MARK: failures

    /// The text of a failed publish. `secret` names the field; the owner removes it and publishes again.
    public static func publishMessage(for failure: ShareFailure) -> String {
        switch failure {
        case .looksLikeSecret(let field): L10n.Share.Problem.secret(field: field)
        case .rate: L10n.Share.Problem.rate
        case .tooMany: L10n.Share.Problem.tooMany
        case .hidden: L10n.Share.Problem.hidden
        case .notFound: L10n.Share.Problem.notFound
        case .unauthorized: L10n.Share.Problem.unauthorized
        case .invalid: L10n.Share.Problem.invalid
        case .network: L10n.Share.Problem.network
        case .api, .badResponse: L10n.Share.Problem.generic
        }
    }

    /// The text of a failed read of a shared item (the install sheet, "My shares").
    public static func fetchMessage(for failure: ShareFailure) -> String {
        switch failure {
        case .notFound: L10n.Share.Problem.notFound
        case .hidden: L10n.Share.Problem.hidden
        case .network: L10n.Share.Problem.network
        case .unauthorized: L10n.Share.Problem.unauthorized
        default: L10n.Share.Problem.generic
        }
    }

    /// The text of a daemon refusal on install or export. Nothing is overwritten when the reason is `exists_not_ours`.
    public static func installMessage(for failure: SharedInstallFailure) -> String {
        switch failure {
        case .reason(let reason):
            switch reason {
            case "catalog_skill": L10n.Share.Daemon.catalogSkill
            case "not_yours": L10n.Share.Daemon.notYours
            case "license_required": L10n.Share.Daemon.licenseRequired
            case "no_skill": L10n.Share.Daemon.noSkill
            case "unsafe_path": L10n.Share.Daemon.unsafePath
            case "bad_path": L10n.Share.Daemon.badPath
            case "not_utf8": L10n.Share.Daemon.notUtf8
            case "too_large": L10n.Share.Daemon.tooLarge
            case "exists_not_ours": L10n.Share.Daemon.existsNotOurs
            default: L10n.Share.Daemon.io
            }
        case .invalid(let field): L10n.Share.Daemon.invalid(field: field)
        case .other: L10n.Share.Problem.payload
        }
    }

    // MARK: labels

    public static func kindLabel(_ kind: ShareKind) -> String {
        switch kind {
        case .bot: L10n.Share.Kind.bot
        case .skill: L10n.Share.Kind.skill
        }
    }

    public static func reportLabel(_ reason: ShareReportReason) -> String {
        switch reason {
        case .spam: L10n.Share.Report.spam
        case .malicious: L10n.Share.Report.malicious
        case .secrets: L10n.Share.Report.secrets
        case .offensive: L10n.Share.Report.offensive
        case .other: L10n.Share.Report.other
        }
    }

    public static func visibilityLabel(_ visibility: ShareVisibility) -> String {
        switch visibility {
        case .everyone: L10n.Share.Visibility.everyone
        case .link: L10n.Share.Visibility.link
        }
    }

    public static func visibilityHint(_ visibility: ShareVisibility) -> String {
        switch visibility {
        case .everyone: L10n.Share.Visibility.everyoneHint
        case .link: L10n.Share.Visibility.linkHint
        }
    }

    /// "Update to the current version" needs the bot or skill this share was made from, on this Mac.
    public static func canUpdate(_ item: ShareSummary, sources: [String: ShareSource]) -> Bool {
        sources[item.id] != nil
    }

    /// The version a share is at, for the lists: "Version 3".
    public static func versionLabel(_ version: Int) -> String {
        L10n.Share.Install.version(number: String(version))
    }
}
