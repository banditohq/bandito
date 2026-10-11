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
        /// A long text the new agent is given (its instructions, what a run says): drawn whole, in a box that scrolls
        /// when it is long, and the person must have scrolled it to the end before Create is offered.
        var isBlock = false

        /// True when this row is drawn in a scrolling box.
        var scrolls: Bool { isBlock && AgentCreateRows.scrolls(value) }
    }

    /// Whether Create is offered: every block that scrolls has been scrolled to its end (`reached` holds their ids).
    static func canCreate(_ rows: [Row], reached: Set<String>) -> Bool {
        rows.filter(\.scrolls).allSatisfy { reached.contains($0.id) }
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

    static func rows(_ summary: AgentCreateSummary, languageCode: String = ModelDescription.currentLanguageCode) -> [Row] {
        var out: [Row] = []
        let role = summary.role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { out.append(Row(id: "role", label: L10n.AgentCreate.role, value: role)) }
        out.append(Row(id: "runtime", label: L10n.AgentCreate.runsOn, value: runtimeLine(summary)))
        out.append(Row(id: "mode", label: L10n.AgentCreate.approvals, value: summary.approvalMode.title))
        out.append(Row(id: "can", label: L10n.AgentCreate.canUse, value: capabilitiesLine(summary)))
        out.append(Row(id: "services", label: L10n.AgentCreate.services, value: servicesLine(summary)))
        let folder = summary.folderIsNew ? L10n.AgentCreate.folderNew : summary.folderPath
        out.append(Row(id: "folder", label: L10n.AgentCreate.folder, value: folder, mono: !summary.folderIsNew))
        let instructions = summary.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            out.append(
                Row(id: instructionsID, label: instructionsLabel(instructions), value: instructions, isBlock: true))
        }
        // Each run says when, its name, and, in full, what it tells the agent to do.
        for (index, run) in summary.runs.enumerated() {
            let when = run.timing(languageCode: languageCode)
            let name = run.title.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            let label = [L10n.AgentCreate.schedules, when, name].compactMap { $0 }.filter { !$0.isEmpty }
            out.append(
                Row(
                    id: "run-\(index)", label: label.joined(separator: " · "),
                    value: run.prompt.trimmingCharacters(in: .whitespacesAndNewlines), isBlock: true))
        }
        return out
    }

    /// "Instructions · 480 characters · 7 lines": how much text there is to read.
    static func instructionsLabel(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return [L10n.AgentCreate.instructions, L10n.AgentCreate.chars(count: text.count), L10n.AgentCreate.lines(count: lines)]
            .joined(separator: " · ")
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
