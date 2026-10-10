import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The model field of the agent forms and the inspector. The panel lists the models the runtime's CLI offers
/// (`runtimes.models`), each with its name and a description in the interface language. The short aliases come first,
/// the full versions under "Other versions". "Other model…" types an id the list does not have, for example an API
/// model. Without a list the panel falls back to the old presets.
struct ModelPicker: View {
    let runtime: RuntimeKind
    /// The model id. Empty means the runtime's default model.
    @Binding var selection: String
    /// The runtime's list. Nil while it is loading, or when the daemon cannot list models.
    let models: RuntimeModelList?
    /// What the last request for the lists came to. Tells "loading", "old daemon" and "failed" apart.
    let status: RuntimeModelsStatus
    /// Called when a model is picked, or a typed id is confirmed (Return or leaving the field). The inspector saves here.
    var onCommit: (String) -> Void = { _ in }

    /// What the panel chooses between.
    private enum Choice: Hashable {
        case automatic
        case model(String)
    }

    /// Asks the server for its lists again ("Повторить"). Nil when there is no server to ask.
    var onRetry: (() -> Void)?
    /// Updates this Mac's server to the app's daemon, for an old daemon. Nil for another server: then the line only says so.
    var onUpdate: (() -> Void)?

    @State private var typing = false
    /// The value the field had when typing began. Leaving the field without Return goes back to it.
    @State private var typingStart = ""
    @FocusState private var focused: Bool

    private var options: [ModelMenuOption] {
        ModelPickerRules.options(list: models, runtime: runtime)
    }

    private var hint: ModelListHint {
        ModelPickerRules.hint(list: models, status: status)
    }

    var body: some View {
        Group {
            if typing {
                typingField
            } else {
                select
            }
        }
        // A typed id belongs to the runtime it was typed for: another runtime starts again with the list.
        .onChange(of: runtime) { _, _ in
            typing = false
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                finishTyping(submitted: false)
            }
        }
    }

    // MARK: Panel

    private var select: some View {
        VStack(alignment: .leading, spacing: 6) {
            BanditoSelect(
                selection: choice, sections: sections, label: L10n.AgentSheet.model,
                placeholder: L10n.ModelPicker.defaultPlain,
                field: { option in fieldView(for: option) },
                footer: { close in footerView(close: close) }
            )
            .optionalHelp(helpText)
            hintLine
        }
    }

    /// Under the field: why the list is missing, in full (it wraps, it is not cut), and the one action that helps.
    @ViewBuilder
    private var hintLine: some View {
        switch hint {
        case .unsupported:
            hintText(L10n.ModelPicker.oldDaemon, action: onUpdate.map { (L10n.ModelPicker.updateButton, $0) })
        case .failed:
            hintText(L10n.ModelPicker.loadFailed, action: onRetry.map { (L10n.Banner.retry, $0) })
        case .runtimeError(let error) where error != RuntimeModelDisplay.notInstalledError:
            hintText(L10n.ModelPicker.loadFailed, action: onRetry.map { (L10n.Banner.retry, $0) })
        case .none, .loading, .runtimeError:
            EmptyView()
        }
    }

    private func hintText(_ text: String, action: (String, () -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(text)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
                    .banditoButton(.link)
                    .fixedSize()
            }
        }
    }

    /// The selection as the panel sees it. Choosing commits the change, as picking in the old menu did.
    private var choice: Binding<Choice> {
        Binding(
            get: { selection.isEmpty ? .automatic : .model(selection) },
            set: { next in
                switch next {
                case .automatic:
                    selection = ""
                case .model(let id):
                    selection = id
                }
                onCommit(selection)
            })
    }

    private var sections: [SelectSection<Choice>] {
        let grouped = ModelPickerRules.grouped(options)
        var main: [SelectOption<Choice>] = []
        main.append(SelectOption(value: .automatic, title: defaultMenuTitle))
        if let typed = ModelPickerRules.typedSelection(selection, options: options) {
            main.append(SelectOption(value: .model(typed), title: typed, monospaced: true))
        }
        main += grouped.main.map(option)
        var result = [SelectSection(options: main)]
        if !grouped.others.isEmpty {
            result.append(SelectSection(title: L10n.ModelPicker.otherVersions, options: grouped.others.map(option)))
        }
        return result
    }

    private func option(_ item: ModelMenuOption) -> SelectOption<Choice> {
        SelectOption(
            value: .model(item.id), title: item.name,
            subtitle: ModelDescription.localized(item.description, languageCode: ModelDescription.currentLanguageCode))
    }

    /// The field. A chosen model uses its own option (title, description, monospace for an unlisted id). The automatic
    /// choice reads "Default · Opus 5.5" with the default model's description, or the loading line while the list
    /// comes.
    private func fieldView(for option: SelectOption<Choice>?) -> SelectFieldView {
        if case .model? = option?.value {
            return SelectFieldView(option: option, placeholder: L10n.ModelPicker.defaultPlain)
        }
        return SelectFieldView(option: automaticField, placeholder: L10n.ModelPicker.defaultPlain)
    }

    private var automaticField: SelectOption<String> {
        SelectOption(
            value: "", title: defaultLabelText,
            subtitle: hint == .loading
                ? L10n.ModelPicker.loading
                : ModelDescription.localized(
                    models?.defaultModel?.description, languageCode: ModelDescription.currentLanguageCode))
    }

    private func footerView(close: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.vertical, 6)
            Button {
                close()
                startTyping()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.Bandito.text2)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(L10n.ModelPicker.other)
                        .font(BanditoFont.font(size: 13, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 9))
        }
    }

    // MARK: Typing an id

    private var typingField: some View {
        HStack(spacing: 6) {
            TextField(L10n.ModelPicker.typePlaceholder, text: $selection)
                .textFieldStyle(.plain)
                .font(BanditoFont.font(size: 13.5, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .focused($focused)
                .onSubmit { finishTyping(submitted: true) }
            Button {
                finishTyping(submitted: false)
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .banditoButton(.icon(size: 26, label: L10n.ModelPicker.backToList))
            .help(L10n.ModelPicker.backToList)
        }
        .modifier(FieldBox())
        .onAppear { focused = true }
    }

    private func startTyping() {
        typingStart = selection
        typing = true
    }

    /// Ends typing once: a confirmed id is saved, anything else puts the value back. Called from Return, the back
    /// button and the field losing focus, so it does nothing when typing has already ended.
    private func finishTyping(submitted: Bool) {
        guard typing else { return }
        typing = false
        selection = ModelPickerRules.valueAfterTyping(selection, startedWith: typingStart, submitted: submitted)
        if submitted {
            onCommit(selection)
        }
    }

    // MARK: Text

    private var defaultMenuTitle: String {
        guard let model = models?.defaultModel else { return L10n.ModelPicker.defaultPlain }
        return L10n.ModelPicker.defaultMenu(name: model.name)
    }

    private var defaultLabelText: String {
        guard let model = models?.defaultModel else { return L10n.ModelPicker.defaultPlain }
        return L10n.ModelPicker.defaultLabel(name: model.name)
    }

    /// The reason the list is missing or incomplete, for the help. Empty when there is nothing to say.
    private var helpText: String? {
        switch hint {
        case .none, .loading: nil
        case .unsupported: L10n.ModelPicker.unsupported
        case .failed(let reason): L10n.ModelPicker.failed(reason: reason)
        case .runtimeError(let error):
            error == RuntimeModelDisplay.notInstalledError
                ? L10n.ModelPicker.notInstalled
                : L10n.ModelPicker.failed(reason: error)
        }
    }
}
