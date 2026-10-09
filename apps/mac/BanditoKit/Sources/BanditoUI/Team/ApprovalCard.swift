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

    var body: some View {
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
        }
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(status: .needsYou, size: 7, ringColor: Color.Bandito.signal.opacity(0.15))
                    Text(L10n.Approval.needsYou)
                        .font(BanditoFont.font(size: 11.5, weight: 600))
                        .foregroundStyle(Color.Bandito.signalGlow)
                }
                .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 3)
                .background(Color.Bandito.signal.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(Color.Bandito.signal.opacity(0.3), lineWidth: 1))

                Text(L10n.Approval.wants(name: agentName))
                    .font(BanditoFont.font(size: 14.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 8)
                Text(L10n.Approval.rule(rule: row.reason))
                    .font(BanditoFont.font(size: 11.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }

            commandBlock

            if let diff = row.diff, !diff.isEmpty {
                ScrollView {
                    Text(diff)
                        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 180)
                .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    onDecide(.deny, false)
                } label: {
                    HStack(spacing: 8) {
                        Text(L10n.Approval.deny)
                        KeyCap(text: "esc")
                    }
                }
                .buttonStyle(QuietButtonStyle())

                Button {
                    onDecide(.allow, remember)
                } label: {
                    HStack(spacing: 8) {
                        Text(L10n.Approval.approve)
                        KeyCap(text: "⌘↵")
                    }
                }
                .buttonStyle(SignalButtonStyle())

                Spacer(minLength: 8)

                CheckBoxRow(isOn: $remember, label: L10n.Approval.alwaysHere)
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

    private var commandBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("$")
                .foregroundStyle(Color.Bandito.text3)
            Text(row.command ?? row.title)
                .foregroundStyle(Color.Bandito.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(BanditoFont.font(size: 13.5, weight: 400, mono: true))
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
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
        }
        .font(BanditoFont.font(size: 12.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 4)
    }
}

/// A keyboard key drawn as a small outlined cap, like the hints in the design.
struct KeyCap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.font(size: 10.5, weight: 500, mono: true))
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
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
