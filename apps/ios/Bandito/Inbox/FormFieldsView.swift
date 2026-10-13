import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The fields of a form the agent asked (`FormSpec`), as the Inbox sheet and the chat's form card draw them: one control
/// for each kind of field, with its help line and the mark of a wrong answer. The answers live in `inputs`, owned by the
/// view that shows the form.
struct FormFieldsView: View {
    let fields: [FormField]
    @Binding var inputs: [String: FormInput]
    let problems: [String: FormProblem]

    var body: some View {
        ForEach(fields) { field in
            fieldView(field)
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
            if let problem = problems[field.id] {
                Text(FormPresentation.text(for: problem))
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
}
