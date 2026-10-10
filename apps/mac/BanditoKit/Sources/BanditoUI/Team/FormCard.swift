import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// A form the agent asked in the thread. Waiting: a card with the fields and the buttons. Answered: a quiet line with
/// what was answered, which opens to the answers.
struct FormCard: View {
    var row: FormRow
    var agentName: String
    /// Sends the answer. The card shows a failure and stays open for another try.
    var onAnswer: (FormAction, [String: JSONValue]?, String?) async throws -> Void

    var body: some View {
        if let outcome = row.outcome {
            AnsweredFormLine(row: row, outcome: outcome)
        } else {
            PendingFormCard(row: row, agentName: agentName, onAnswer: onAnswer)
        }
    }
}

// MARK: - Answered

private struct AnsweredFormLine: View {
    var row: FormRow
    var outcome: FormOutcome

    @State private var expanded = false

    private var rows: [(label: String, value: String)] {
        if case .submitted(let values) = outcome { return FormPresentation.answerRows(spec: row.spec, values: values) }
        return []
    }

    private var icon: (name: String, tint: Color) {
        switch outcome {
        case .submitted: ("checkmark.circle", Color.Bandito.ok)
        case .rejected: ("xmark.circle", row.spec.kind == .confirm ? Color.Bandito.danger : Color.Bandito.text3)
        case .expired: ("clock.badge.xmark", Color.Bandito.text3)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The form is over: what was typed into it is no longer needed.
            Color.clear.frame(height: 0)
                .onAppear { FormDrafts.shared.clear(formId: row.formId) }
            if rows.isEmpty {
                line
            } else {
                Button {
                    expanded.toggle()
                } label: {
                    line
                        .contentShape(Rectangle())
                }
                .banditoButton(.row(cornerRadius: 8))
                .help(expanded ? L10n.Form.hideAnswers : L10n.Form.showAnswers)
            }
            if expanded, !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, answer in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(answer.label)
                                .foregroundStyle(Color.Bandito.text3)
                                .frame(width: 130, alignment: .leading)
                            Text(answer.value)
                                .foregroundStyle(Color.Bandito.text2)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(BanditoFont.font(size: 12.5, weight: 400))
                    }
                }
                .padding(12)
                .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.tint)
            Text(row.spec.title)
                .lineLimit(1)
                .foregroundStyle(Color.Bandito.text2)
            Text("·")
            Text(FormPresentation.line(spec: row.spec, outcome: outcome))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !rows.isEmpty {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .font(BanditoFont.font(size: 12.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 4)
    }
}

// MARK: - Waiting

private struct PendingFormCard: View {
    var row: FormRow
    var agentName: String
    var onAnswer: (FormAction, [String: JSONValue]?, String?) async throws -> Void

    private var drafts: FormDrafts { FormDrafts.shared }
    @State private var problems: [String: FormProblem] = [:]
    /// The person has tried to send: from then on the problems follow the edits.
    @State private var attempted = false
    @State private var busy = false
    @State private var failure: UserFacingMessage?

    private var draft: FormDrafts.Draft { drafts.draft(for: row.formId, spec: row.spec) }
    private var inputs: [String: FormInput] { draft.inputs }
    private var comment: Binding<String> {
        Binding(
            get: { draft.comment },
            set: { drafts.setComment($0, formId: row.formId, spec: row.spec) })
    }
    /// The fields and buttons wait: an answer is on its way or has been taken.
    private var locked: Bool { busy || draft.sent }

    private var spec: FormSpec { row.spec }
    private var isConfirm: Bool { spec.kind == .confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let intro = spec.intro, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(intro)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            fields
            if isConfirm {
                TextField(L10n.Form.whyPlaceholder, text: comment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1...3)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line))
                    .disabled(locked)
            }
            if let failure {
                UserFacingErrorView(message: failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if draft.sent {
                sentLine
            } else {
                buttons
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
        .onChange(of: inputs) { _, _ in
            if attempted { problems = FormAnswer.problems(spec: spec, inputs: inputs) }
        }
    }

    // MARK: Header and buttons

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(status: .needsYou, size: 7, ringColor: Color.Bandito.signal.opacity(0.15))
                    Text(L10n.Approval.needsYou)
                        .font(BanditoFont.font(size: 11.5, weight: 600))
                        .foregroundStyle(Color.Bandito.signalGlow)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.leading, 7).padding(.trailing, 9).padding(.vertical, 3)
                .background(Color.Bandito.signal.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(Color.Bandito.signal.opacity(0.3), lineWidth: 1))

                Text(isConfirm ? L10n.Form.confirms(name: agentName) : L10n.Form.asks(name: agentName))
                    .font(BanditoFont.font(size: 12, weight: 500))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(spec.title)
                .font(BanditoFont.font(size: 16, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                submitButton
                rejectButton
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                submitButton
                rejectButton
            }
        }
    }

    /// The answer is with the daemon; the card folds when its event comes.
    private var sentLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.Form.sent)
                .font(BanditoFont.font(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
        }
    }

    private var submitButton: some View {
        Button(action: submit) {
            Text(FormPresentation.submitTitle(spec))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .banditoButton(.signal())
        .disabled(locked)
        .help(FormPresentation.submitTitle(spec))
    }

    private var rejectButton: some View {
        Button(action: reject) {
            Text(FormPresentation.rejectTitle(spec))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .banditoButton(.quiet())
        .disabled(locked)
        .help(FormPresentation.rejectTitle(spec))
    }

    // MARK: Answering

    private func submit() {
        attempted = true
        switch FormAnswer.values(spec: spec, inputs: inputs) {
        case .failure(let found):
            problems = found.byField
            failure = nil
        case .success(let values):
            problems = [:]
            send(.submit, values: values, comment: nil)
        }
    }

    private func reject() {
        send(.reject, values: nil, comment: isConfirm ? FormAnswer.comment(draft.comment) : nil)
    }

    private func send(_ action: FormAction, values: [String: JSONValue]?, comment: String?) {
        guard !busy, !draft.sent else { return }
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await onAnswer(action, values, comment)
                drafts.markSent(formId: row.formId, spec: row.spec)
            } catch {
                failure = FormPresentation.message(for: error)
            }
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        if isConfirm {
            // A confirmation reads as a summary of what will happen; every line can still be edited.
            VStack(spacing: 0) {
                ForEach(Array(spec.fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { Divider().overlay(Color.Bandito.line) }
                    FormFieldView(
                        field: field, input: binding(field), problem: problems[field.id], summary: true, disabled: locked)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
            .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.Bandito.line))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(spec.fields) { field in
                    FormFieldView(
                        field: field, input: binding(field), problem: problems[field.id], summary: false,
                        disabled: locked)
                }
            }
        }
    }

    private func binding(_ field: FormField) -> Binding<FormInput> {
        Binding(
            get: { inputs[field.id] ?? FormAnswer.initialInput(for: field) },
            set: { drafts.setInput($0, field: field.id, formId: row.formId, spec: row.spec) })
    }
}

// MARK: - One field

private struct FormFieldView: View {
    var field: FormField
    @Binding var input: FormInput
    var problem: FormProblem?
    /// The field sits in the summary of a confirmation: a plain value, with the label above it.
    var summary: Bool
    var disabled: Bool

    init(field: FormField, input: Binding<FormInput>, problem: FormProblem?, summary: Bool, disabled: Bool) {
        self.field = field
        _input = input
        self.problem = problem
        self.summary = summary
        self.disabled = disabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.type == .boolean {
                booleanRow
            } else {
                label
                control
            }
            if let help = field.help, !help.isEmpty {
                Text(help)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(FormPresentation.text(for: problem))
                    .font(BanditoFont.font(size: 12, weight: 500))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(FormPresentation.text(for: problem))
            }
        }
        .disabled(disabled)
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(field.label)
                .font(BanditoFont.font(size: summary ? 11.5 : 12.5, weight: 600))
                .foregroundStyle(summary ? Color.Bandito.text3 : Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            requiredMark
        }
    }

    @ViewBuilder
    private var requiredMark: some View {
        if field.isRequired {
            Text("*")
                .font(BanditoFont.font(size: 12.5, weight: 600))
                .foregroundStyle(Color.Bandito.signal)
                .help(L10n.Form.requiredHelp)
                .accessibilityLabel(L10n.Form.requiredHelp)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.type {
        case .text, .email, .number:
            lineField
        case .textarea:
            areaField
        case .choice:
            choiceControl
        case .multichoice:
            multiControl
        case .date:
            dateControl
        case .boolean:
            EmptyView()
        }
    }

    // MARK: Text

    private var text: Binding<String> {
        Binding(
            get: { if case .text(let t) = input { return t } else { return "" } },
            set: { input = .text($0) })
    }

    private var lineField: some View {
        TextField(field.placeholder ?? "", text: text)
            .textFieldStyle(.plain)
            .font(
                field.type == .number
                    ? BanditoFont.font(size: 13.5, weight: 400).monospacedDigit()
                    : BanditoFont.font(size: 13.5, weight: 400))
            .foregroundStyle(Color.Bandito.text)
            .tint(Color.Bandito.signal)
            .modifier(FormFieldBox(plain: summary, failed: problem != nil, height: 40))
            .accessibilityLabel(field.label)
    }

    private var areaField: some View {
        TextField(field.placeholder ?? "", text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(BanditoFont.font(size: 13.5, weight: 400))
            .foregroundStyle(Color.Bandito.text)
            .tint(Color.Bandito.signal)
            .lineLimit(summary ? 2...12 : 3...10)
            .modifier(FormFieldBox(plain: summary, failed: problem != nil, height: nil))
            .accessibilityLabel(field.label)
    }

    // MARK: Choice

    private var selected: String? {
        if case .option(let o) = input { return o }
        return nil
    }

    @ViewBuilder
    private var choiceControl: some View {
        let options = field.options ?? []
        if FormPresentation.usesRadio(field) {
            VStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    RadioRow(title: option, isSelected: selected == option) {
                        // A second click on the chosen option of an optional field takes the choice back.
                        input = .option(selected == option && !field.isRequired ? nil : option)
                    }
                }
            }
        } else {
            BanditoSelect(
                selection: Binding<String?>(get: { selected }, set: { input = .option($0) }),
                sections: [
                    SelectSection(options: options.map { SelectOption<String?>(value: $0, title: $0) })
                ],
                label: field.label, placeholder: field.placeholder ?? L10n.Form.choose)
        }
    }

    // MARK: Several choices

    private var picked: [String] {
        if case .options(let o) = input { return o }
        return []
    }

    private var multiControl: some View {
        FlowLayout(spacing: 8) {
            ForEach(field.options ?? [], id: \.self) { option in
                let on = picked.contains(option)
                Button {
                    var next = Set(picked)
                    if on { next.remove(option) } else { next.insert(option) }
                    // Kept in the order of the field's options, whatever the order of the clicks.
                    input = .options((field.options ?? []).filter(next.contains))
                } label: {
                    HStack(spacing: 6) {
                        if on {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(option)
                            .font(BanditoFont.font(size: 13, weight: on ? 600 : 500))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 320, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(on ? Color.Bandito.signalGlow : Color.Bandito.text2)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(
                        Capsule().fill(on ? Color.Bandito.signal.opacity(0.14) : Color.Bandito.text.opacity(0.05))
                    )
                    .overlay(
                        Capsule().stroke(on ? Color.Bandito.signal.opacity(0.45) : Color.Bandito.line, lineWidth: 1))
                }
                .banditoButton(.row(cornerRadius: 16))
                .help(option)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: Yes or no

    private var booleanRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text(field.label)
                    .font(BanditoFont.font(size: summary ? 13 : 13.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
                requiredMark
            }
            Spacer(minLength: 8)
            Toggle(
                field.label,
                isOn: Binding(
                    get: { if case .flag(let b) = input { return b } else { return false } },
                    set: { input = .flag($0) })
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Color.Bandito.signalFill)
        }
    }

    // MARK: Date

    private var dateText: String? {
        if case .date(let d) = input { return d }
        return nil
    }

    @ViewBuilder
    private var dateControl: some View {
        if let text = dateText, let date = FormDates.date(from: text) {
            HStack(spacing: 10) {
                DatePicker(
                    field.label,
                    selection: Binding(
                        get: { date }, set: { input = .date(FormDates.string(from: $0)) }),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                if !field.isRequired {
                    Button {
                        input = .date(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    .banditoButton(.icon(size: 26, label: L10n.Form.clearDate))
                }
                Spacer(minLength: 0)
            }
        } else {
            Button {
                input = .date(FormDates.string(from: Date()))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(field.placeholder ?? L10n.Form.pickDate)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .banditoButton(.quiet())
        }
    }
}

/// The frame of a text field in a form: the filled field of the sheets, or no frame at all in the summary of a
/// confirmation (a thin underline shows that the line can be edited). A field with a problem has a red edge.
private struct FormFieldBox: ViewModifier {
    var plain: Bool
    var failed: Bool
    /// The fixed height of a one-line field; nil lets a multi-line field grow.
    var height: CGFloat?

    func body(content: Content) -> some View {
        let edge = failed ? Color.Bandito.danger : Color.Bandito.line
        if plain {
            content
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(failed ? Color.Bandito.danger : Color.Bandito.text.opacity(0.12)).frame(height: 1)
                }
        } else {
            content
                .padding(.horizontal, 13)
                .padding(.vertical, height == nil ? 10 : 0)
                .frame(minHeight: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(edge))
        }
    }
}
