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
    let onAct: (InboxAct) async -> InboxAnswer.Outcome

    @Environment(\.dismiss) private var dismiss
    @State private var remember = false
    @State private var inputs: [String: FormInput]
    @State private var problems: [String: FormProblem] = [:]
    /// How the last answer ended, when it did not go through: the sheet stays open and says why.
    @State private var message: String?
    @State private var busy = false

    init(item: InboxItem, riskyNeedsFaceID: Bool, onAct: @escaping (InboxAct) async -> InboxAnswer.Outcome) {
        self.item = item
        self.riskyNeedsFaceID = riskyNeedsFaceID
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
            HStack(spacing: BanditoSpace.s3) {
                Button(L10n.Approval.deny) { Task { await send(.deny) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(busy)
                Button(L10n.Approval.approve) { Task { await send(.allow(remember: remember)) } }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(busy)
            }
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
            ForEach(row.spec.fields) { field in
                fieldView(field)
            }
            if !problems.isEmpty {
                Text(L10n.Ios.Inbox.invalidForm)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
            }
            HStack(spacing: BanditoSpace.s3) {
                Button(row.spec.rejectLabel ?? L10n.Approval.deny) { Task { await send(.deny) } }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(busy)
                Button(row.spec.submitLabel ?? L10n.Ios.Inbox.send) { Task { await submitForm(row.spec) } }
                    .buttonStyle(SignalButtonStyle())
                    .disabled(busy)
            }
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

    @ViewBuilder private func fieldView(_ field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch field.type {
            case .boolean:
                Toggle(field.label, isOn: flagBinding(field.id))
                    .font(BanditoFont.text(size: 14, weight: 400))
                    .tint(Color.Bandito.signal)
            case .choice:
                HStack {
                    Text(field.label)
                        .font(BanditoFont.text(size: 14, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                    Spacer()
                    Picker(field.label, selection: choiceBinding(field.id)) {
                        Text("—").tag("")
                        ForEach(field.options ?? [], id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .labelsHidden()
                }
            case .multichoice:
                Text(field.label)
                    .font(BanditoFont.text(size: 14, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                ForEach(field.options ?? [], id: \.self) { option in
                    Toggle(option, isOn: optionBinding(field.id, option: option, all: field.options ?? []))
                        .font(BanditoFont.text(size: 14, weight: 400))
                        .tint(Color.Bandito.signal)
                }
            case .date:
                labeled(field) {
                    TextField(field.placeholder ?? "YYYY-MM-DD", text: dateBinding(field.id))
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
            case .number:
                labeled(field) {
                    TextField(field.placeholder ?? "", text: textBinding(field.id))
                        .keyboardType(.decimalPad)
                }
            case .email:
                labeled(field) {
                    TextField(field.placeholder ?? "", text: textBinding(field.id))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            case .textarea:
                labeled(field) {
                    TextField(field.placeholder ?? "", text: textBinding(field.id), axis: .vertical)
                        .lineLimit(3...6)
                }
            case .text:
                labeled(field) {
                    TextField(field.placeholder ?? "", text: textBinding(field.id))
                }
            }
            if let help = field.help {
                Text(help)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            if problems[field.id] != nil {
                Text(L10n.Ios.Inbox.invalidForm)
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
            }
        }
    }

    private func labeled<Field: View>(_ field: FormField, @ViewBuilder _ input: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.label)
                .font(BanditoFont.text(size: 14, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            input()
                .font(BanditoFont.text(size: 15, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .padding(BanditoSpace.s3)
                .background(RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous).fill(Color.Bandito.surface1))
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        CrewSectionLabel(title: title)
    }

    // MARK: bindings to the form's inputs

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(
            get: {
                switch inputs[id] {
                case .text(let t)?: t
                default: ""
                }
            },
            set: { inputs[id] = .text($0) })
    }

    private func dateBinding(_ id: String) -> Binding<String> {
        Binding(
            get: {
                if case .date(let d)? = inputs[id] { return d ?? "" }
                return ""
            },
            set: { inputs[id] = .date($0.isEmpty ? nil : $0) })
    }

    private func flagBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: {
                if case .flag(let b)? = inputs[id] { return b }
                return false
            },
            set: { inputs[id] = .flag($0) })
    }

    private func choiceBinding(_ id: String) -> Binding<String> {
        Binding(
            get: {
                if case .option(let o)? = inputs[id] { return o ?? "" }
                return ""
            },
            set: { inputs[id] = .option($0.isEmpty ? nil : $0) })
    }

    private func optionBinding(_ id: String, option: String, all: [String]) -> Binding<Bool> {
        Binding(
            get: {
                if case .options(let picked)? = inputs[id] { return picked.contains(option) }
                return false
            },
            set: { on in
                var picked: [String] = []
                if case .options(let current)? = inputs[id] { picked = current }
                picked.removeAll { $0 == option }
                if on { picked.append(option) }
                // In the order of the field's options, as the answer is sent.
                inputs[id] = .options(all.filter(picked.contains))
            })
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.display(size: 14, weight: 600))
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(Capsule().fill(Color.Bandito.surface2))
            .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.14), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
