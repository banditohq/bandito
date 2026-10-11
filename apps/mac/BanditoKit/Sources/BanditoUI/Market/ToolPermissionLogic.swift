import BanditoKit
import BanditoL10n
import Foundation

/// The "Tools" section of a connected service: what the daemon does with each tool under the service's mode and the
/// owner's words (docs/ARCHITECTURE.md#tool-permissions). Pure, so the rules are easy to test; they are the daemon's.
enum ToolPermissionLogic {
    /// What a tool does, from its annotations. A tool that is not marked as reading changes something; one marked
    /// destructive deletes.
    enum Kind: Equatable {
        case reads, changes, deletes

        var title: String {
            switch self {
            case .reads: L10n.Market.Tools.Kind.reads
            case .changes: L10n.Market.Tools.Kind.changes
            case .deletes: L10n.Market.Tools.Kind.deletes
            }
        }
    }

    static func kind(of tool: IntegrationTool) -> Kind {
        if tool.destructive { return .deletes }
        return tool.readOnly ? .reads : .changes
    }

    /// What happens to a call of `tool` with no word of its own: `allow` runs it (as the agent's approval mode says),
    /// `ask` waits for the owner, `deny` refuses it.
    static func modeWord(_ mode: IntegrationToolMode, for tool: IntegrationTool) -> ToolWord {
        switch mode {
        case .all: .allow
        case .readOnly: kind(of: tool) == .reads ? .allow : .deny
        case .confirmWrites: kind(of: tool) == .reads ? .allow : .ask
        }
    }

    /// What happens to a call of `tool`: the owner's word, else the mode's.
    static func effectiveWord(of tool: IntegrationTool, mode: IntegrationToolMode, overrides: [String: ToolWord]) -> ToolWord {
        overrides[tool.name] ?? modeWord(mode, for: tool)
    }

    /// The words after the owner picked `word` for `tool`: a word equal to what the mode does anyway is not kept, so
    /// the list stays the owner's own exceptions. Words for tools that are not in the list stay as they are.
    static func overrides(
        setting word: ToolWord, for tool: IntegrationTool, mode: IntegrationToolMode, current: [String: ToolWord]
    ) -> [String: ToolWord] {
        var next = current
        if word == modeWord(mode, for: tool) {
            next[tool.name] = nil
        } else {
            next[tool.name] = word
        }
        return next
    }

    /// The tools in the order the section lists them: those that delete first, then those that change, then those that
    /// read; by name inside a group.
    static func sorted(_ tools: [IntegrationTool]) -> [IntegrationTool] {
        func rank(_ tool: IntegrationTool) -> Int {
            switch kind(of: tool) {
            case .deletes: 0
            case .changes: 1
            case .reads: 2
            }
        }
        return tools.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// How many tools of each kind the last check found, for the line under the mode.
    static func counts(_ tools: [IntegrationTool]) -> (reads: Int, changes: Int, deletes: Int) {
        var out = (reads: 0, changes: 0, deletes: 0)
        for tool in tools {
            switch kind(of: tool) {
            case .reads: out.reads += 1
            case .changes: out.changes += 1
            case .deletes: out.deletes += 1
            }
        }
        return out
    }

    /// The section's state: the service was never checked (no tools are known, so every call counts as a change), or
    /// it lists tools.
    enum Content: Equatable {
        case notChecked
        case tools([IntegrationTool])
    }

    static func content(_ tools: [IntegrationTool]) -> Content {
        tools.isEmpty ? .notChecked : .tools(sorted(tools))
    }

    /// The service is limited: a mode other than all, or a word that denies or asks. Only Claude sends the calls of such
    /// a service to the daemon, so the daemon does not give it to a session on Codex or Grok.
    static func isLimited(_ integration: Integration) -> Bool {
        integration.toolMode != .all || integration.toolOverrides.values.contains { $0 == .deny || $0 == .ask }
    }

    /// The agents that lose a limited service because they run on Codex or Grok: those that have it (its id is in their
    /// list, or they have no list and so have every service). Empty when the service is not limited.
    static func unreachedAgents(_ agents: [Agent], for integration: Integration) -> [String] {
        guard isLimited(integration) else { return [] }
        return agents.filter { agent in
            let runtime = agent.activeRuntime ?? agent.runtime
            guard runtime == .codex || runtime == .grok else { return false }
            return agent.integrations?.contains(integration.id) ?? true
        }.map(\.name)
    }
}
