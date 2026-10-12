import BanditoKit
import BanditoL10n
import Foundation

/// The rules of the agent forms on iPhone: the model a new agent starts on, its folder, the "may do" chips, and the
/// bodies of `agents.create` and `agents.create_bundle`. Pure, so the tests hold each rule without a server.
///
/// Ported from the Mac's `NewAgentModelRules`, `NewAgentFolderRules`, `ReadyTeamsLogic` and `AgentCapability`. Those live in
/// `BanditoUI`, which is macOS only; they move to `BanditoKit` in their own change, and then this file goes.
enum AgentRules {
    /// The longest folder name, in characters.
    static let nameLimit = 64
    /// How many names are tried (`Forge`, `Forge 2`, …) before the sheet gives up.
    static let attemptLimit = 200
    /// The agents folder when nothing else says where it is: `Bandito` in the home folder of the server's user.
    static let defaultRootName = "Bandito"
    /// The approval choices in the order the Mac shows them: about everything, only the risky ones, about nothing.
    static let approvalOrder: [ApprovalMode] = [.always, .risky, .never]

    /// The bundles offered as ready teams, in this order (the Mac's `ReadyTeamsLogic.ids`).
    static let readyTeamIDs = ["web-project", "server-duty", "morning-summary", "docs-upkeep"]

    /// The app's language as a locale tag (`ru`, `zh-Hans`…): the one the strings are in.
    static var languageCode: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }

    /// Whether the server offers ready teams: the bundles, with their model, folder and schedules.
    static func teamsSupported(_ supports: (String) -> Bool) -> Bool {
        supports("agent_bundles") && supports("bundle_schedules")
    }

    /// The text of a failure the sheets show: the daemon's message, or the connection's.
    static func errorText(_ error: Error) -> String {
        (error as? RPCError)?.message ?? error.localizedDescription
    }

    // MARK: runtime and model

    /// The runtime a new agent starts on: the first of Claude Code, Codex and Grok that is installed on the server.
    static func defaultRuntime(_ runtimes: [RuntimeStatus]) -> RuntimeKind? {
        [RuntimeKind.claude, .codex, .grok].first { kind in
            runtimes.contains { $0.kind == kind && $0.installed }
        }
    }

    /// The model Claude Code starts on: `haiku` when the list has it, else the newest model whose name starts with
    /// "Haiku" (by its version). Nil for the other runtimes, and when the list has no Haiku: the runtime's default stays.
    static func preferredModel(runtime: RuntimeKind, models: [RuntimeModel]) -> String? {
        guard runtime == .claude else { return nil }
        if models.contains(where: { $0.id == "haiku" }) {
            return "haiku"
        }
        return models
            .filter { $0.name.hasPrefix("Haiku") }
            .max { version(of: $0.name).lexicographicallyPrecedes(version(of: $1.name)) }?
            .id
    }

    /// The numbers in a model name, in order: "Haiku 4.5" is [4, 5]. A name with no number is [].
    static func version(of name: String) -> [Int] {
        name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    // MARK: folder

    /// The folder name for an agent's name: characters a folder cannot have, and control characters, become `-`.
    /// Spaces at the ends are trimmed and the name is cut to `nameLimit`. Empty, "." and ".." give "agent".
    static func folderName(for agentName: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var mapped = ""
        for scalar in agentName.unicodeScalars {
            if forbidden.contains(Character(scalar)) || CharacterSet.controlCharacters.contains(scalar) {
                mapped.append("-")
            } else {
                mapped.unicodeScalars.append(scalar)
            }
        }
        let cut = mapped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty || cut == "." || cut == ".." ? "agent" : cut
    }

    /// The name tried for an attempt: the name itself first, then ` 2`, ` 3`… The base is cut so the whole name stays
    /// within `nameLimit`.
    static func candidate(base: String, attempt: Int) -> String {
        guard attempt > 1 else { return base }
        let suffix = " \(attempt)"
        let head = base.prefix(nameLimit - suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return head + suffix
    }

    /// The path of a folder `name` inside `root`. A trailing slash on the root does not double.
    static func folderPath(root: String, name: String) -> String {
        let base = trimmedSlash(root)
        return (base == "/" ? "" : base) + "/" + name
    }

    /// The folder above `path`. Nil for the root or a relative path.
    static func parent(of path: String) -> String? {
        let trimmed = trimmedSlash(path)
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return nil }
        let head = String(trimmed[..<slash])
        return head.isEmpty ? "/" : head
    }

    /// The project folder of an agent: its `cwd`, unless the agent works in its own folder (`homeDir`).
    static func projectFolder(cwd: String, homeDir: String?) -> String? {
        let folder = trimmedSlash(cwd.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folder.isEmpty else { return nil }
        if let homeDir, trimmedSlash(homeDir) == folder { return nil }
        return folder
    }

    /// The agents folder a new agent goes into when the person has not chosen one on this server: the saved one; else
    /// the parent that holds the most project folders (at least two agents in it; a tie goes to the one listed first);
    /// else `Bandito` in the home folder. Nil when none of these is known.
    static func defaultRoot(saved: String?, projectFolders: [String], home: String?) -> String? {
        if let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return trimmedSlash(saved)
        }
        var counts: [(parent: String, count: Int)] = []
        for folder in projectFolders {
            guard let parent = parent(of: folder) else { continue }
            if let index = counts.firstIndex(where: { $0.parent == parent }) {
                counts[index].count += 1
            } else {
                counts.append((parent: parent, count: 1))
            }
        }
        var best: (parent: String, count: Int)?
        for entry in counts where entry.count >= 2 && entry.count > (best?.count ?? 0) {
            best = entry
        }
        if let best {
            return best.parent
        }
        guard let home, !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return folderPath(root: home, name: defaultRootName)
    }

    private static func trimmedSlash(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    // MARK: requests

    /// The body of `agents.create` for the one-agent form. The optional fields are sent only when set.
    static func newAgent(
        name: String, role: String, runtime: RuntimeKind, model: String?, folder: String, approval: ApprovalMode,
        effort: Effort?, permissions: Set<AgentPermission>
    ) -> NewAgent {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewAgent(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            runtime: runtime,
            model: trimmedModel?.isEmpty == false ? trimmedModel : nil,
            cwd: folder,
            approvalMode: approval,
            effort: effort,
            capabilities: AgentPermission.wire(permissions))
    }

    /// The body of `agents.create_bundle` for a ready team. Every schedule of the team is made, and only the keys in
    /// `enabled` start on. The folder is sent only when it is set. Nil without a runtime.
    static func teamRequest(
        bundleID: String, runtime: RuntimeKind?, languageCode: String, model: String?, folder: String,
        scheduleKeys: [String], enabled: Set<String>
    ) -> NewBundle? {
        guard let runtime else { return nil }
        let cwd = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewBundle(
            bundleId: bundleID, language: CatalogLanguage.requestCode(languageCode), runtime: runtime.rawValue,
            model: model, cwd: cwd.isEmpty ? nil : cwd,
            schedules: scheduleKeys.isEmpty ? nil : scheduleKeys.filter(enabled.contains).sorted())
    }

    /// The key of a template's schedule in `NewBundle.schedules`: `<template id>:<index>`.
    static func scheduleKey(templateID: String, index: Int) -> String {
        "\(templateID):\(index)"
    }

    /// Whether the one-agent form can be sent: a name, a runtime, and no request under way.
    static func canCreateOne(name: String, runtime: RuntimeKind?, folder: String, busy: Bool) -> Bool {
        guard !busy, runtime != nil, !folder.isEmpty else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What an agent may do on the server, as the "May do" chips show it. The raw values are the wire names of
/// `agents.create` and `agents.update` (`Agent.capabilities`).
enum AgentPermission: String, CaseIterable, Identifiable, Hashable {
    case terminal, files, browser, team, screen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: L10n.Capability.terminal
        case .files: L10n.Capability.files
        case .browser: L10n.Capability.browser
        case .team: L10n.Capability.crew
        case .screen: L10n.Capability.screen
        }
    }

    /// The set a wire list stands for. Nil (no list from the daemon) means everything; unknown names are ignored.
    static func set(from wire: [String]?) -> Set<AgentPermission> {
        guard let wire else { return Set(allCases) }
        return Set(wire.compactMap(AgentPermission.init(rawValue:)))
    }

    /// The wire list for a set, in the order of the chips.
    static func wire(_ enabled: Set<AgentPermission>) -> [String] {
        allCases.filter(enabled.contains).map(\.rawValue)
    }
}

/// One schedule of a ready team, as the team's preview lists it.
struct ReadyTeamSchedule: Identifiable, Equatable {
    let key: String
    let agentName: String
    /// The cron expression, as the template has it.
    let cron: String
    let promptsFirstLine: String
    var id: String { key }
}
