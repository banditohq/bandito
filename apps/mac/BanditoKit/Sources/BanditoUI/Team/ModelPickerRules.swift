import BanditoKit

/// One item of the model menu.
struct ModelMenuOption: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String?
}

/// Why the model list is missing or incomplete. The menu and the field's help say it.
enum ModelListHint: Equatable {
    /// There is nothing to say: a list is there.
    case none
    /// The list is being asked for and has not come yet.
    case loading
    /// The daemon predates `runtime_models`. Not a failure: the daemon simply cannot list models.
    case unsupported
    /// The request itself failed. The text is the reason.
    case failed(String)
    /// The list came, but the CLI gave none. The text is the daemon's `error`: `not_installed` or a reason.
    case runtimeError(String)

    /// The menu says "could not get the list" first, and the help gives the reason.
    var isFailure: Bool {
        switch self {
        case .failed, .runtimeError: true
        case .none, .loading, .unsupported: false
        }
    }
}

/// The rules of the model field, pure so they are tested without a view.
enum ModelPickerRules {
    /// The menu items: the runtime's listed models, or the old presets when the list has none.
    static func options(list: RuntimeModelList?, runtime: RuntimeKind) -> [ModelMenuOption] {
        if let models = list?.models, !models.isEmpty {
            return models.map { ModelMenuOption(id: $0.id, name: $0.name, description: $0.description) }
        }
        return NewAgentDraft.modelPresets(for: runtime).map { ModelMenuOption(id: $0, name: $0, description: nil) }
    }

    /// The selection when no menu item names it: an id the list lacks, or an id kept from an older daemon. It is shown
    /// first in the menu, with the checkmark, so the person sees what is set. Nil when an item names it, or when the
    /// selection is the default.
    static func typedSelection(_ selection: String, options: [ModelMenuOption]) -> String? {
        guard !selection.isEmpty, !options.contains(where: { $0.id == selection }) else { return nil }
        return selection
    }

    /// The field's value when typing ends. A confirmed id (Return) is kept. Leaving the field without Return goes back
    /// to the value typing began from, which is the saved one.
    static func valueAfterTyping(_ typed: String, startedWith started: String, submitted: Bool) -> String {
        submitted ? typed : started
    }

    /// The hint for the menu and the help. A list that is there wins: its own `error` is then the only news.
    /// Without a list, the request's state says why there is none.
    static func hint(list: RuntimeModelList?, status: RuntimeModelsStatus) -> ModelListHint {
        if let list {
            if let error = list.error, !error.isEmpty {
                return .runtimeError(error)
            }
            return .none
        }
        switch status {
        case .unknown: return .loading
        case .unsupported: return .unsupported
        case .failed(let reason): return .failed(reason)
        case .loaded: return .none
        }
    }
}
