import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The model field of the agent forms and the inspector. The menu lists the models the runtime's CLI offers
/// (`runtimes.models`), each with its name and description. "Other model…" types an id the list does not have, for
/// example an API model. Without a list the menu falls back to the old presets. The field looks like the other fields.
struct ModelPicker: View {
    let runtime: RuntimeKind
    /// The model id. Empty means the runtime's default model.
    @Binding var selection: String
    /// The runtime's list. Nil while it is loading, or when the daemon cannot list models.
    let models: RuntimeModelList?
    /// What the last request for the lists came to. Tells "loading", "old daemon" and "failed" apart.
    let status: RuntimeModelsStatus
    /// Called when a model is picked, or a typed id is confirmed (Return). The inspector saves here.
    var onCommit: (String) -> Void = { _ in }

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
                menu
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

    // MARK: Menu

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            HStack(spacing: 10) {
                Text(titleText)
                    .font(BanditoFont.font(size: 13.5, weight: 400, mono: showsRawID))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .modifier(FieldBox())
        }
        .menuStyle(.button)
        .banditoButton(.row(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
        .help(helpText)
    }

    @ViewBuilder
    private var menuItems: some View {
        if hint.isFailure {
            Button(L10n.ModelPicker.failedMenu) {}
                .disabled(true)
            Divider()
        }
        choice(defaultMenuTitle, description: nil, selected: selection.isEmpty) { choose("") }
        Divider()
        if let typed = ModelPickerRules.typedSelection(selection, options: options) {
            choice(typed, description: nil, selected: true) { choose(typed) }
            Divider()
        }
        ForEach(options) { item in
            choice(item.name, description: item.description, selected: item.id == selection) { choose(item.id) }
        }
        Divider()
        Button(L10n.ModelPicker.other) { startTyping() }
    }

    /// One menu item. Every item reserves the checkmark's place, so the text does not move when the choice changes:
    /// the checkmark is clear on the items that are not chosen. The description, when there is one, is the subtitle.
    private func choice(
        _ title: String, description: String?, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "checkmark")
                    .opacity(selected ? 1 : 0)
            }
            if let description, !description.isEmpty {
                Text(description)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if hint == .loading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(L10n.ModelPicker.loading)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
        } else if let description = selectedModel?.description, !description.isEmpty {
            Text(description)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
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

    private var titleText: String {
        if selection.isEmpty {
            guard let model = models?.defaultModel else { return L10n.ModelPicker.defaultPlain }
            return L10n.ModelPicker.defaultLabel(name: model.name)
        }
        return selectedModel?.name ?? selection
    }

    /// The listed model the selection names. For the empty selection, the runtime's default model.
    private var selectedModel: RuntimeModel? {
        selection.isEmpty ? models?.defaultModel : models?.models.first { $0.id == selection }
    }

    /// An id the list does not name is shown as it is, in monospace.
    private var showsRawID: Bool {
        !selection.isEmpty && selectedModel == nil
    }

    /// The reason the list is missing or incomplete, for the help. Empty when there is nothing to say.
    private var helpText: String {
        switch hint {
        case .none, .loading: ""
        case .unsupported: L10n.ModelPicker.unsupported
        case .failed(let reason): L10n.ModelPicker.failed(reason: reason)
        case .runtimeError(let error):
            error == RuntimeModelDisplay.notInstalledError
                ? L10n.ModelPicker.notInstalled
                : L10n.ModelPicker.failed(reason: error)
        }
    }

    private func choose(_ id: String) {
        selection = id
        onCommit(id)
    }
}
