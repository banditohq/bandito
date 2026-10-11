import BanditoKit

/// The model a new agent starts on when the person has not picked one. Pure: the sheet calls it when the runtime or
/// the runtime's model list changes, and the tests call it directly.
enum NewAgentModelRules {
    /// The model the Claude Code runtime starts on: `haiku` when the list has that id, else the newest model whose
    /// name starts with "Haiku" (by its version: "Haiku 5.5" over "Haiku 4.5"). Nil for the other runtimes, and when the
    /// list has no Haiku at all: then the runtime's own default stays.
    static func preferredModel(runtime: RuntimeKind, models: [RuntimeModel]) -> String? {
        guard runtime == .claude else { return nil }
        if models.contains(where: { $0.id == "haiku" }) {
            return "haiku"
        }
        return models
            .filter { $0.name.hasPrefix("Haiku") }
            .max { version(of: $0.name).lexicographicallyPrecedes(version(of: $1.name)) }?
            .id
    }

    /// The model the field holds after a change. It becomes the preferred model only when the person has not chosen
    /// one and the field is empty (the runtime's default). Otherwise the current value stays, so a choice the person
    /// made, including "Default", is never replaced.
    static func startingModel(
        current: String, chosen: Bool, runtime: RuntimeKind, models: [RuntimeModel]
    ) -> String {
        guard !chosen, current.isEmpty, let preferred = preferredModel(runtime: runtime, models: models) else {
            return current
        }
        return preferred
    }

    /// The numbers in a model name, in order: "Haiku 4.5" is [4, 5]. A name with no number is [].
    static func version(of name: String) -> [Int] {
        name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
