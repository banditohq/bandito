import BanditoKit

/// The rules the agent forms, the inspector and the thread use to read the model lists (`runtimes.models`). Pure, so
/// they are tested without a view.
public enum RuntimeModelDisplay {
    /// The `error` a CLI that is not installed on the server reports.
    public static let notInstalledError = "not_installed"

    /// The name shown for a model id: the name from the runtime's list when the list names the model, the id otherwise.
    public static func name(id: String, runtime: RuntimeKind, lists: [String: RuntimeModelList]) -> String {
        lists[runtime.rawValue]?.models.first { $0.id == id }?.name ?? id
    }

    /// The effort levels a model accepts, lowest first. An empty `modelID` is the runtime's default model.
    /// Nil when the list does not say: there is no list for the runtime, or it does not name the model.
    /// Empty when the model takes no effort at all.
    public static func efforts(
        modelID: String, runtime: RuntimeKind, lists: [String: RuntimeModelList]
    ) -> [Effort]? {
        guard let list = lists[runtime.rawValue] else { return nil }
        let model = modelID.isEmpty ? list.defaultModel : list.models.first { $0.id == modelID }
        return model?.supportedEfforts
    }

    /// The effort levels offered for a model, lowest first: the model's own when its list says, else the runtime's.
    /// Empty when the model takes no effort at all.
    public static func effortLevels(
        modelID: String, runtime: RuntimeKind, lists: [String: RuntimeModelList]
    ) -> [Effort] {
        efforts(modelID: modelID, runtime: runtime, lists: lists) ?? runtime.supportedEfforts
    }

    /// The effort a model runs with: `chosen` moved to the nearest level the model takes. Nil when the model takes no
    /// effort, so none is sent. `chosen` itself when the list does not say.
    public static func effort(
        _ chosen: Effort, modelID: String, runtime: RuntimeKind, lists: [String: RuntimeModelList]
    ) -> Effort? {
        guard let levels = efforts(modelID: modelID, runtime: runtime, lists: lists) else { return chosen }
        return levels.isEmpty ? nil : chosen.nearest(in: levels)
    }

    /// The effort a model change writes, in the same request as the model. Nil when no effort is written.
    /// Only a change of the model writes: the lists arriving, or the inspector opening, write nothing. A model that
    /// takes no effort gets none written, and a saved effort the new model lacks moves to the nearest level it takes.
    public static func effortWrite(
        modelChangedFrom previous: String, to next: String, stored: Effort?, runtime: RuntimeKind,
        lists: [String: RuntimeModelList]
    ) -> Effort? {
        guard previous != next, let stored else { return nil }
        guard let levels = efforts(modelID: next, runtime: runtime, lists: lists), !levels.isEmpty else { return nil }
        guard let nearest = stored.nearest(in: levels), nearest != stored else { return nil }
        return nearest
    }

    /// The model field a runtime switch sends. Nil when the agent has no model. Otherwise the model is kept when the
    /// new runtime's list names it, and cleared when not. It is always sent when there is one: the daemon resets a
    /// model that a runtime change does not name.
    public static func modelChange(
        afterSwitchingTo runtime: RuntimeKind, current: String, lists: [String: RuntimeModelList]
    ) -> FieldChange<String>? {
        guard !current.isEmpty else { return nil }
        let kept = model(afterSwitchingTo: runtime, keeping: current, lists: lists)
        return kept.isEmpty ? .clear : .set(kept)
    }

    /// The model a runtime change keeps. The model is kept when the new runtime's list names it. Without a list,
    /// only a preset of that runtime is kept. Otherwise the result is "", the runtime's default model.
    public static func model(
        afterSwitchingTo runtime: RuntimeKind, keeping model: String, lists: [String: RuntimeModelList]
    ) -> String {
        guard !model.isEmpty else { return "" }
        if let list = lists[runtime.rawValue], !list.models.isEmpty {
            return list.models.contains { $0.id == model } ? model : ""
        }
        return NewAgentDraft.modelPresets(for: runtime).contains(model) ? model : ""
    }
}
