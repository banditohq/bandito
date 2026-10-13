import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// The cards of the chat that are made in SwiftUI: an approval, a form, a request to connect. They are rare rows (the
// frequent ones are drawn by the list itself), and they have controls the list would only repeat. Each card reports
// its height when it changes (a wrong answer shows a line under a field).

/// The height of a card, handed up to the list.
private struct ChatCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    func reportsHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: ChatCardHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ChatCardHeightKey.self) { height in
            if height > 0 { onChange(height) }
        }
    }

    /// The card surface: the raised color with a quiet edge, as the Inbox's rows.
    func chatCardSurface() -> some View {
        padding(BanditoSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.Bandito.surface1))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.Bandito.text.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 12)
    }
}

// MARK: - approval

/// An approval the agent waits for: what it wants to run, why it asks, and the two answers. A risky one asks for Face ID
/// when the setting says so (the same check the Inbox makes).
struct ChatApprovalCard: View {
    let row: ApprovalRow
    let agentName: String
    let faceIDNeeded: Bool
    let onAnswer: (_ allow: Bool, _ remember: Bool) async -> InboxAnswer.Outcome
    let onHeight: (CGFloat) -> Void

    @State private var remember = false
    @State private var busy = false
    @State private var message: String?

    private var risky: Bool { ApprovalReason.isRisky(row.reason) }

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            HStack(alignment: .firstTextBaseline, spacing: BanditoSpace.s2) {
                Text(L10n.Approval.wants(name: agentName))
                    .font(BanditoFont.display(size: 15, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
                if risky { RiskMark() }
            }
            Text(row.command ?? row.title)
                .font(BanditoFont.mono(size: 13))
                .foregroundStyle(Color.Bandito.text)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BanditoSpace.s3)
                .background(RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous).fill(Color.Bandito.bg))
            Text(ApprovalReason.text(row.reason))
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            if faceIDNeeded {
                Text(L10n.Ios.Inbox.faceIDHint)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Toggle(L10n.Approval.alwaysHere, isOn: $remember)
                .font(BanditoFont.text(size: 13.5, weight: 400))
                .tint(Color.Bandito.signal)
            if let message {
                Text(message)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: BanditoSpace.s3) {
                Button(L10n.Approval.deny) { Task { await answer(false) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("chat.approval.deny.\(row.approvalId)")
                Button(L10n.Approval.approve) { Task { await answer(true) } }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("chat.approval.allow.\(row.approvalId)")
            }
        }
        .chatCardSurface()
        .reportsHeight(onHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.approval")
    }

    private func answer(_ allow: Bool) async {
        busy = true
        defer { busy = false }
        switch await onAnswer(allow, remember) {
        case .sent: message = nil
        case .notConfirmed: message = L10n.Ios.Settings.Security.failed
        case .cannotConfirm: message = L10n.Ios.Settings.Security.unavailable
        case .failed: message = L10n.Ios.Chat.Approval.failed
        }
    }
}

// MARK: - form

/// A form the agent asked: its fields, and Send or Skip. What was typed is kept (`FormDrafts`) while the row scrolls away.
struct ChatFormCard: View {
    let row: FormRow
    let agentName: String
    let onAnswer: (_ action: FormAction, _ values: [String: JSONValue]?) async -> Bool
    let onHeight: (CGFloat) -> Void

    @State private var inputs: [String: FormInput]
    @State private var problems: [String: FormProblem] = [:]
    @State private var busy = false
    @State private var failed = false

    init(
        row: FormRow, agentName: String, onAnswer: @escaping (FormAction, [String: JSONValue]?) async -> Bool,
        onHeight: @escaping (CGFloat) -> Void
    ) {
        self.row = row
        self.agentName = agentName
        self.onAnswer = onAnswer
        self.onHeight = onHeight
        _inputs = State(initialValue: FormDrafts.shared.draft(for: row.formId, spec: row.spec).inputs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            Text(row.spec.kind == .confirm ? L10n.Form.confirms(name: agentName) : L10n.Form.asks(name: agentName))
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text3)
            Text(row.spec.title)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            if let intro = row.spec.intro {
                Text(intro)
                    .font(BanditoFont.text(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FormFieldsView(
                fields: row.spec.fields,
                inputs: Binding(
                    get: { inputs },
                    set: { new in
                        inputs = new
                        for (field, input) in new where FormDrafts.shared.draft(for: row.formId, spec: row.spec).inputs[field] != input {
                            FormDrafts.shared.setInput(input, field: field, formId: row.formId, spec: row.spec)
                        }
                    }),
                problems: problems)
            if failed {
                Text(L10n.Ios.Inbox.failed)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: BanditoSpace.s3) {
                Button(FormPresentation.rejectTitle(row.spec)) { Task { await send(.reject) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("chat.form.reject")
                Button(FormPresentation.submitTitle(row.spec)) { Task { await send(.submit) } }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(busy)
                    .accessibilityIdentifier("chat.form.submit")
            }
        }
        .chatCardSurface()
        .reportsHeight(onHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.form")
    }

    private func send(_ action: FormAction) async {
        var values: [String: JSONValue]?
        if action == .submit {
            switch FormAnswer.values(spec: row.spec, inputs: inputs) {
            case .success(let found):
                problems = [:]
                values = found
            case .failure(let found):
                problems = found.byField
                return
            }
        }
        busy = true
        defer { busy = false }
        failed = !(await onAnswer(action, values))
    }
}

// MARK: - connect

/// A service the agent asked to connect: on the phone it can only be declined for now.
struct ChatConnectCard: View {
    let row: ConnectRow
    let agentName: String
    let onDecline: () async -> Bool
    let onHeight: (CGFloat) -> Void

    @State private var busy = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            Text(L10n.Ios.Inbox.connect(name: agentName, service: row.service))
                .font(BanditoFont.display(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = row.shownReason {
                Text(reason)
                    .font(BanditoFont.text(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.Ios.Inbox.connectOnMac)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            if failed {
                Text(L10n.Ios.Inbox.failed)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
            }
            Button(L10n.Approval.deny) {
                Task {
                    busy = true
                    failed = !(await onDecline())
                    busy = false
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(busy)
        }
        .chatCardSurface()
        .reportsHeight(onHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.connect")
    }
}

// MARK: - empty

/// A chat with nothing in it yet: the raccoon, a line, and what to start with.
struct ChatEmptyView: View {
    let name: String
    let look: CrewLook
    let suggestions: [ThreadEmptyRules.Suggestion]
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s3) {
            CrewAvatar(name: name, look: look, mood: .idle, size: 76)
            Text(L10n.Ios.Chat.Empty.title(name: name))
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Ios.Chat.Empty.message(name: name))
                .font(BanditoFont.text(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: BanditoSpace.s2) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onPick(suggestion.text)
                    } label: {
                        HStack(spacing: BanditoSpace.s2) {
                            Image(systemName: suggestion.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.Bandito.text3)
                                .frame(width: 18)
                            Text(suggestion.text)
                                .font(BanditoFont.text(size: 14, weight: 450))
                                .foregroundStyle(Color.Bandito.text)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, BanditoSpace.s3)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous).fill(Color.Bandito.surface1))
                        .overlay(
                            RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                                .stroke(Color.Bandito.text.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.suggestion")
                }
            }
            .padding(.top, BanditoSpace.s2)
        }
        .padding(.horizontal, BanditoSpace.s6)
        .frame(maxWidth: 420)
    }
}
