import BanditoKit
import BanditoL10n
import Foundation

/// The rows of the card an agent shows to create another agent (docs/ARCHITECTURE.md#agents-creating-agents): a label
/// and a value each, worked out from the daemon's summary. Pure: the card only draws them.
enum AgentCreateRows {
    struct Row: Equatable, Identifiable {
        var id: String
        var label: String
        var value: String
        /// A path: drawn in the mono font.
        var mono = false
    }

    /// The summary of an `agent.create` approval; `nil` for any other approval, and for one whose input does not read.
    static func summary(for row: ApprovalRow) -> AgentCreateSummary? {
        row.tool == AgentCreateSummary.tool ? AgentCreateSummary(input: row.input) : nil
    }

    /// The row that holds the instructions: drawn in a scrolling box, never cut.
    static let instructionsID = "instructions"
    static let instructionsBoxHeight: CGFloat = 130
    /// Instructions longer than this (in characters), or with more lines than `scrollLines`, go in the scrolling box;
    /// a short text is drawn plainly, with no empty box around it.
    static let scrollCharacters = 360
    static let scrollLines = 6

    static func scrolls(_ instructions: String) -> Bool {
        instructions.count > scrollCharacters || instructions.split(separator: "\n", omittingEmptySubsequences: false).count > scrollLines
    }

    /// Longest name of a run in the list, in characters; the rest is cut.
    static let runNameLimit = 80

    static func rows(_ summary: AgentCreateSummary, languageCode: String = ModelDescription.currentLanguageCode) -> [Row] {
        var out: [Row] = []
        let role = summary.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { out.append(Row(id: "role", label: L10n.AgentCreate.role, value: role)) }
        out.append(Row(id: "runtime", label: L10n.AgentCreate.runsOn, value: runtimeLine(summary)))
        out.append(Row(id: "mode", label: L10n.AgentCreate.approvals, value: summary.approvalMode.title))
        out.append(Row(id: "can", label: L10n.AgentCreate.canUse, value: capabilitiesLine(summary)))
        out.append(Row(id: "services", label: L10n.AgentCreate.services, value: servicesLine(summary)))
        if !summary.runs.isEmpty {
            let lines = summary.runs.map { runLine($0, languageCode: languageCode) }
            out.append(Row(id: "runs", label: L10n.AgentCreate.schedules, value: lines.joined(separator: "\n")))
        }
        let folder = summary.folderIsNew ? L10n.AgentCreate.folderNew : summary.folderPath
        out.append(Row(id: "folder", label: L10n.AgentCreate.folder, value: folder, mono: !summary.folderIsNew))
        let instructions = summary.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            out.append(Row(id: instructionsID, label: L10n.AgentCreate.instructions, value: instructions))
        }
        return out
    }

    /// "Claude · sonnet": the runtime, and the model when one is chosen.
    static func runtimeLine(_ summary: AgentCreateSummary) -> String {
        var parts = [RuntimeSwitchNote.runtimeName(summary.runtime)]
        if let model = summary.model, !model.isEmpty { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    /// The capabilities in the order of the chips; a name this app does not know (a newer daemon's) is shown as sent.
    static func capabilitiesLine(_ summary: AgentCreateSummary) -> String {
        let known = AgentCapability.allCases.filter { summary.capabilities.contains($0.rawValue) }.map(\.title)
        let unknown = summary.capabilities.filter { AgentCapability(rawValue: $0) == nil }
        let all = known + unknown
        return all.isEmpty ? L10n.AgentCreate.nothingExtra : all.joined(separator: " · ")
    }

    static func servicesLine(_ summary: AgentCreateSummary) -> String {
        let names = summary.services.joined(separator: ", ")
        if summary.servicesAll {
            return names.isEmpty ? L10n.AgentCreate.servicesAll : "\(L10n.AgentCreate.servicesAll) · \(names)"
        }
        return names.isEmpty ? L10n.AgentCreate.servicesNone : names
    }

    static func runLine(_ run: AgentCreateSummary.Run, languageCode: String) -> String {
        let name = run.shownName.replacingOccurrences(of: "\n", with: " ")
        let shown = name.count > runNameLimit ? String(name.prefix(runNameLimit - 1)) + "…" : name
        let when = run.timing(languageCode: languageCode)
        return when.isEmpty ? shown : L10n.AgentCreate.runLine(when: when, what: shown)
    }

    /// The line a card folds into once it is over; `nil` while it waits.
    static func resolvedLine(for state: ApprovalState, name: String) -> String? {
        switch state {
        case .pending: nil
        case .approved: L10n.AgentCreate.allowed(name: name)
        case .denied(let by): by == .user ? L10n.AgentCreate.declined(name: name) : L10n.AgentCreate.expired(name: name)
        case .withdrawn: L10n.AgentCreate.expired(name: name)
        }
    }
}
