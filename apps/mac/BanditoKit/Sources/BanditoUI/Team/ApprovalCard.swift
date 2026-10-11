import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// An approval request in the thread. Pending: a card with a gradient frame, the command and the buttons.
/// Resolved: a quiet line. The card does not handle keys itself: ⌘↵ and esc are menu commands (see `BanditoCommands`).
struct ApprovalCard: View {
    var row: ApprovalRow
    var agentName: String
    /// Decides the request. The flag is the "always allow here" checkbox, meaningful only for allow.
    var onDecide: (Decision, Bool) -> Void

    @State private var remember = false

    /// The summary of an agent the asking agent wants to create; `nil` for every other approval.
    private var createSummary: AgentCreateSummary? { AgentCreateRows.summary(for: row) }

    var body: some View {
        if let summary = createSummary, let line = AgentCreateRows.resolvedLine(for: row.state, name: summary.name) {
            createResolvedLine(line)
        } else {
            standardBody
        }
    }

    @ViewBuilder
    private var standardBody: some View {
        switch row.state {
        case .pending:
            pendingCard
        case .approved(let by, _):
            resolvedLine(
                icon: "checkmark.circle", tint: Color.Bandito.ok,
                text: by == .user ? L10n.Team.resolvedAllowed : L10n.Approval.approvedByPolicy)
        case .denied(let by):
            resolvedLine(
                icon: "xmark.circle", tint: Color.Bandito.danger,
                text: by == .user ? L10n.Team.resolvedDenied : L10n.Approval.deniedByPolicy)
        case .withdrawn:
            // The CLI took the request back: a quiet line in the history, nothing to answer.
            resolvedLine(icon: "arrow.uturn.backward.circle", tint: Color.Bandito.text3, text: L10n.Approval.withdrawn)
        }
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(status: .needsYou, size: 7, ringColor: Color.Bandito.signal.opacity(0.15))
                    Text(L10n.Approval.needsYou)
                        .font(BanditoFont.text(size: 11.5, weight: 600))
                        .foregroundStyle(Color.Bandito.signalGlow)
                }
                .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 3)
                .background(Color.Bandito.signal.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(Color.Bandito.signal.opacity(0.3), lineWidth: 1))

                Text(createSummary != nil ? L10n.AgentCreate.wants(name: agentName) : L10n.Approval.wants(name: agentName))
                    .font(BanditoFont.text(size: 14.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 8)
                // A creation says what it is in its title: the reason would only repeat it, and take the room of the name.
                if createSummary == nil {
                    Text(ApprovalReason.text(row.reason))
                        .help(row.reason)
                        .font(BanditoFont.text(size: 11.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }

            if let summary = createSummary {
                AgentCreateDetails(summary: summary)
            } else {
                commandBlock
            }

            if createSummary == nil, let diff = row.diff, !diff.isEmpty {
                ScrollView {
                    Text(diff)
                        .font(BanditoFont.mono(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 180)
                .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if createSummary != nil {
                // Nothing is remembered for a creation: Decline and Create only.
                ActionRow {
                    createDeclineButton
                    createButton
                }
            } else {
                standardActions
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color(hex: 0x221C16), Color(hex: 0x1A1612)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
        .padding(1)
        .background(
            LinearGradient(
                colors: [
                    BanditoPalette.peach.opacity(0.75),
                    Color.Bandito.signalFill.opacity(0.35),
                    Color.Bandito.text.opacity(0.08),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: Color.Bandito.signal.opacity(0.3), radius: 24, x: 0, y: 14)
    }

    /// Deny and Approve with the "always allow here" checkbox.
    private var standardActions: some View {
        // Wide: the checkbox sits beside the buttons. Narrow: the checkbox takes a line of its own above them.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                denyButton
                approveButton
                Spacer(minLength: 8)
                rememberBox
            }
            VStack(alignment: .leading, spacing: 10) {
                rememberBox
                ActionRow {
                    denyButton
                    approveButton
                }
            }
        }
        // ViewThatFits takes all the height on offer; the card is only as tall as its chosen variant.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var denyButton: some View {
        Button {
            onDecide(.deny, false)
        } label: {
            HStack(spacing: 8) {
                Text(L10n.Approval.deny)
                KeyCap(text: "esc")
            }
        }
        .banditoButton(.quiet())
    }

    private var approveButton: some View {
        Button {
            onDecide(.allow, remember)
        } label: {
            HStack(spacing: 8) {
                Text(L10n.Approval.approve)
                KeyCap(text: "⌘↵")
            }
        }
        .banditoButton(.signal())
    }

    private var createDeclineButton: some View {
        Button {
            onDecide(.deny, false)
        } label: {
            HStack(spacing: 8) {
                Text(L10n.AgentCreate.decline)
                KeyCap(text: "esc")
            }
        }
        .banditoButton(.quiet())
    }

    private var createButton: some View {
        Button {
            onDecide(.allow, false)
        } label: {
            HStack(spacing: 8) {
                Text(L10n.AgentCreate.create)
                KeyCap(text: "⌘↵")
            }
        }
        .banditoButton(.signal())
    }

    /// The quiet line a creation folds into once it is answered or over.
    private func createResolvedLine(_ text: String) -> some View {
        var icon = "checkmark.circle"
        var tint = Color.Bandito.ok
        switch row.state {
        case .approved, .pending: break
        case .denied(let by):
            icon = "xmark.circle"
            tint = by == .user ? Color.Bandito.danger : Color.Bandito.text3
        case .withdrawn:
            icon = "arrow.uturn.backward.circle"
            tint = Color.Bandito.text3
        }
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .lineLimit(2)
        }
        .font(BanditoFont.text(size: 12.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 4)
    }

    /// The "always allow here" checkbox. Its label is one line in both layouts: it never breaks letter by letter.
    private var rememberBox: some View {
        CheckBoxRow(isOn: $remember, label: L10n.Approval.alwaysHere)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var commandBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("$")
                .foregroundStyle(Color.Bandito.text3)
            Text(row.command ?? row.title)
                .foregroundStyle(Color.Bandito.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(BanditoFont.font(size: 13.5, weight: 400, mono: row.command != nil))
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }

    private func resolvedLine(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .lineLimit(1)
            Text(row.command ?? row.title)
                .font(BanditoFont.font(size: 12, weight: 400, mono: row.command != nil))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
        }
        .font(BanditoFont.text(size: 12.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 4)
    }
}

/// A keyboard key drawn as a small outlined cap, like the hints in the design.
struct KeyCap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.mono(size: 10.5, weight: 500))
            .foregroundStyle(Color.Bandito.text2)
            .padding(.horizontal, 5)
            .frame(minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.Bandito.text.opacity(0.22)))
    }
}

/// Square checkbox with a label, drawn with the palette so it looks the same in every render.
struct CheckBoxRow: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Color.Bandito.signalFill : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isOn ? Color.Bandito.signalFill : Color.Bandito.text.opacity(0.3), lineWidth: 1.2)
                    }
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.Bandito.onSignal)
                        }
                    }
                    .frame(width: 15, height: 15)
                Text(label)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 6))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The daemon's reason for asking, in words: `risky: rm -r` → "deletes a whole folder". An unknown reason is shown as
/// it came, after "rule:".
enum ApprovalReason {
    static func text(_ reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("risky: ") {
            let rule = String(r.dropFirst("risky: ".count))
            switch rule {
            case "rm -r": return L10n.Approval.Why.deleteFolder
            case "git push": return L10n.Approval.Why.gitPush
            case "sql": return L10n.Approval.Why.sql
            case "sudo": return L10n.Approval.Why.sudo
            case "npm publish", "cargo publish": return L10n.Approval.Why.publish
            default: return L10n.Approval.Why.risky(rule: rule)
            }
        }
        if r.hasPrefix("reads credentials: ") {
            return L10n.Approval.Why.credentials(folder: String(r.dropFirst("reads credentials: ".count)))
        }
        if r.hasPrefix("writes outside ") { return L10n.Approval.Why.outside }
        if r.hasPrefix("can't check") { return L10n.Approval.Why.cantCheck }
        if r == "approval required for every action" { return L10n.Approval.Why.always }
        if r.hasPrefix("rule: ") { return L10n.Approval.Why.yourRule(rule: String(r.dropFirst("rule: ".count))) }
        if r == "touches Bandito's files by name" { return L10n.Approval.Why.bandito }
        if r == "agent: create" { return L10n.AgentCreate.why }
        if r == "service: confirm changes" { return L10n.Approval.Why.serviceConfirm }
        if r == "service: confirm tool" { return L10n.Approval.Why.serviceTool }
        return L10n.Approval.rule(rule: r)
    }
}

/// What an agent that asks to create another agent is going to make, one row each: the person reads all of it before
/// pressing Create. Rows come from `AgentCreateRows`; a label sits above its value, so no column is squeezed.
struct AgentCreateDetails: View {
    var summary: AgentCreateSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(summary.name)
                .font(BanditoFont.text(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentCreateRows.rows(summary)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(BanditoFont.text(size: 11.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text3)
                    if row.id == AgentCreateRows.instructionsID, AgentCreateRows.scrolls(row.value) {
                        // All of it, in a box that scrolls: what the new agent is told is what the person allows.
                        ScrollView {
                            valueText(row)
                        }
                        .frame(height: AgentCreateRows.instructionsBoxHeight)
                    } else {
                        valueText(row)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }

    private func valueText(_ row: AgentCreateRows.Row) -> some View {
        Text(row.value)
            .font(BanditoFont.font(size: 13, weight: 400, mono: row.mono))
            .foregroundStyle(Color.Bandito.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
