import BanditoKit
import BanditoL10n

/// What the "Only risky / Everything / Nothing" control means, in the words of the approval policy.
public enum ApprovalChoice: CaseIterable, Sendable {
    case risky, always, never

    public var mode: ApprovalMode {
        switch self {
        case .risky: .risky
        case .always: .always
        case .never: .never
        }
    }

    public var title: String {
        switch self {
        case .risky: L10n.ApprovalMode.risky
        case .always: L10n.ApprovalMode.always
        case .never: L10n.ApprovalMode.never
        }
    }
}

/// Everything the new agent sheet collects before `agents.create`. Pure: the sheet only binds to it.
public struct NewAgentDraft: Equatable, Sendable {
    public var name = ""
    public var role = ""
    public var color: AvatarColor = .peach
    public var face: AvatarFace = .chevronDash
    public var runtime: RuntimeKind = .claude
    /// Empty means the runtime's default model.
    public var model = ""
    public var effort: Effort = .medium
    public var instructions = ""
    /// The project folder on the server. Empty until one is picked.
    public var cwd = ""
    public var approval: ApprovalChoice = .risky
    public var memory: MemoryMode = .smart
    /// "If the limit runs out": the runtime to continue on. `nil` = do not switch.
    public var fallbackRuntime: RuntimeKind?
    /// Empty means the fallback runtime's default model.
    public var fallbackModel = ""

    public init() {}

    /// Name and folder are the only required fields.
    public var canCreate: Bool {
        !trimmed(name).isEmpty && !trimmed(cwd).isEmpty
    }

    /// Switches the runtime. The effort is lowered to a level the new runtime offers.
    public mutating func setRuntime(_ next: RuntimeKind) {
        runtime = next
        effort = next.clampedEffort(effort)
        // The fallback must be another runtime: a fallback that became the primary is dropped.
        if fallbackRuntime == next {
            fallbackRuntime = nil
            fallbackModel = ""
        }
    }

    /// The runtimes that can be the fallback of `runtime`: the other pickable ones.
    public static func fallbackOptions(for runtime: RuntimeKind) -> [RuntimeKind] {
        RuntimeKind.pickable.filter { $0 != runtime }
    }

    public func makeNewAgent() -> NewAgent {
        let model = trimmed(model)
        let instructions = trimmed(instructions)
        return NewAgent(
            name: trimmed(name),
            role: trimmed(role),
            runtime: runtime,
            model: model.isEmpty ? nil : model,
            cwd: trimmed(cwd),
            approvalMode: approval.mode,
            systemPrompt: instructions.isEmpty ? nil : instructions,
            effort: effort,
            memoryMode: memory,
            fallbackRuntime: fallbackRuntime,
            fallbackModel: trimmed(fallbackModel).isEmpty ? nil : trimmed(fallbackModel))
    }

    /// Model names offered in the menu. Other runtimes take free text only.
    public static func modelPresets(for runtime: RuntimeKind) -> [String] {
        runtime == .claude ? ["opus", "sonnet", "haiku"] : []
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
