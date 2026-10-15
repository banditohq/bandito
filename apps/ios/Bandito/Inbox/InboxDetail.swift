import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the person did in an Inbox item, as the screen sends it to `InboxAnswer`.
enum InboxAct: Equatable {
    case allow(remember: Bool)
    case deny
    case submit([String: JSONValue])
    case reply(String)
}

/// The sheet of one Inbox item: the full command or the reason, the form's fields, the question's buttons. The answer is
/// given through `onAct`, which says how it ended; the sheet closes when it was sent.
struct InboxDetailSheet: View {
    let item: InboxItem
    let riskyNeedsFaceID: Bool
    /// Opens the agent's chat (closing the sheet first); nil leaves the button out.
    var openChat: (() -> Void)?
    let onAct: (InboxAct) async -> InboxAnswer.Outcome

    @Environment(\.dismiss) private var dismiss
    @State private var remember = false
    @State private var inputs: [String: FormInput]
    @State private var problems: [String: FormProblem] = [:]
    /// How the last answer ended, when it did not go through: the sheet stays open and says why.
    @State private var message: String?
    @State private var busy = false

    init(
        item: InboxItem, riskyNeedsFaceID: Bool, openChat: (() -> Void)? = nil,
        onAct: @escaping (InboxAct) async -> InboxAnswer.Outcome
    ) {
        self.item = item
        self.riskyNeedsFaceID = riskyNeedsFaceID
        self.openChat = openChat
        self.onAct = onAct
        if case .form(let row) = item.kind {
            _inputs = State(initialValue: FormAnswer.initialInputs(for: row.spec))
        } else {
            _inputs = State(initialValue: [:])
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BanditoSpace.s4) {
                    content
                    if let message {
                        Text(message)
                            .font(BanditoFont.text(size: 13.5, weight: 500))
                            .foregroundStyle(Color.Bandito.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(BanditoSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(item.agentName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
                if let openChat {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            dismiss()
                            openChat()
                        } label: {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                        }
                        .accessibilityLabel(L10n.Ios.Crew.openChat(name: item.agentName))
                        .accessibilityIdentifier("inbox.openChat")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .approval(let row):
            approval(row)
        case .form(let row):
            form(row)
        case .connect(let row):
            connect(row)
        case .question(let text, let buttons):
            question(text: text, buttons: buttons)
        }
    }

    // MARK: approval

    private func approval(_ row: ApprovalRow) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s4) {
            Text(L10n.Approval.wants(name: item.agentName))
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            sectionLabel(L10n.Ios.Inbox.command)
            Text(row.command ?? row.title)
                .font(BanditoFont.mono(size: 14))
                .foregroundStyle(Color.Bandito.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BanditoSpace.s3)
                .background(RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous).fill(Color.Bandito.surface1))
            sectionLabel(L10n.Ios.Inbox.reason)
            HStack(alignment: .firstTextBaseline, spacing: BanditoSpace.s2) {
                Text(ApprovalReason.text(row.reason))
                    .font(BanditoFont.text(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                if item.isRisky {
                    RiskMark()
                }
            }
            if InboxAnswer.needsFaceID(item, riskyNeedsFaceID: riskyNeedsFaceID) {
                Text(L10n.Ios.Inbox.faceIDHint)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Toggle(L10n.Approval.alwaysHere, isOn: $remember)
                .font(BanditoFont.text(size: 14, weight: 400))
                .tint(Color.Bandito.signal)
            AnswerPair(
                quiet: L10n.Approval.deny, main: L10n.Approval.approve, disabled: busy,
                quietAction: { Task { await send(.deny) } },
                mainAction: { Task { await send(.allow(remember: remember)) } }
            )
            .padding(.top, BanditoSpace.s2)
        }
    }

    // MARK: connect

    private func connect(_ row: ConnectRow) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s4) {
            Text(L10n.Ios.Inbox.connect(name: item.agentName, service: row.service))
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            sectionLabel(L10n.Ios.Inbox.service)
            Text(row.service)
                .font(BanditoFont.mono(size: 14))
                .foregroundStyle(Color.Bandito.text)
            if let reason = row.shownReason {
                sectionLabel(L10n.Ios.Inbox.reason)
                Text(reason)
                    .font(BanditoFont.text(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.Ios.Inbox.connectOnMac)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Button(L10n.Approval.deny) { Task { await send(.deny) } }
                .buttonStyle(QuietButtonStyle())
                .disabled(busy)
                .padding(.top, BanditoSpace.s2)
        }
    }

    // MARK: question

    private func question(text: String?, buttons: [QuickReplyButton]) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s4) {
            Text(L10n.Ios.Crew.waitingAnswer(name: item.agentName))
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            if let text {
                Text(text)
                    .font(BanditoFont.text(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(buttons, id: \.label) { button in
                Button(button.label) { Task { await send(.reply(button.reply)) } }
                    .buttonStyle(QuietButtonStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(busy)
            }
        }
    }

    // MARK: form

    private func form(_ row: FormRow) -> some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s4) {
            Text(row.spec.title)
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            if let intro = row.spec.intro {
                Text(intro)
                    .font(BanditoFont.text(size: 14, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FormFieldsView(fields: row.spec.fields, inputs: $inputs, problems: problems)
            if !problems.isEmpty {
                Text(L10n.Ios.Inbox.invalidForm)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
            }
            AnswerPair(
                quiet: row.spec.rejectLabel ?? L10n.Approval.deny,
                main: row.spec.submitLabel ?? L10n.Ios.Inbox.send, disabled: busy,
                quietAction: { Task { await send(.deny) } },
                mainAction: { Task { await submitForm(row.spec) } }
            )
            .padding(.top, BanditoSpace.s2)
        }
    }

    /// Checks the answers the way the daemon does (`FormAnswer`); a wrong one is marked and nothing is sent.
    private func submitForm(_ spec: FormSpec) async {
        switch FormAnswer.values(spec: spec, inputs: inputs) {
        case .success(let values):
            problems = [:]
            await send(.submit(values))
        case .failure(let found):
            problems = found.byField
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        CrewSectionLabel(title: title)
    }

    // MARK: answering

    /// Sends the answer; a sent one closes the sheet, any other says how it ended.
    private func send(_ action: InboxAct) async {
        busy = true
        defer { busy = false }
        let outcome = await onAct(action)
        switch outcome {
        case .sent:
            dismiss()
        case .notConfirmed:
            message = L10n.Ios.Settings.Security.failed
        case .cannotConfirm:
            message = L10n.Ios.Settings.Security.unavailable
        case .failed:
            message = L10n.Ios.Inbox.failed
        }
    }
}

/// The secondary button of the sheets: a quiet capsule with a hairline, as the Mac's quiet button.
struct QuietButtonStyle: ButtonStyle {
    /// The capsule takes the whole width it is offered (a stacked pair of answers), not its label's.
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.display(size: 14, weight: 600))
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(Capsule().fill(Color.Bandito.surface2))
            .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.14), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
