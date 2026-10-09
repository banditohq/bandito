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
    /// Where the agent's CLI runs. The shared server by default.
    public var workplace: WorkplaceChoice = .shared
    /// The container to make when `workplace` is `.new`.
    public var newWorkplace = NewWorkplaceDraft()

    public init() {}

    /// Name and folder are the only required fields. A new container needs a valid name and limits.
    public var canCreate: Bool {
        !trimmed(name).isEmpty && !trimmed(cwd).isEmpty && workplaceReady
    }

    /// The chosen workplace can be used: the shared server, an existing container, or a new one with a valid form.
    public var workplaceReady: Bool {
        workplace != .new || newWorkplace.canCreate
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

    /// The request for `agents.create`. `workspaceID` is the id of the container made for `.new` (see
    /// `WorkplaceCreation.prepare`); the other choices name their workspace themselves.
    public func makeNewAgent(workspaceID: String? = nil) -> NewAgent {
        let model = trimmed(model)
        let instructions = trimmed(instructions)
        let workspace: String?
        switch workplace {
        case .shared: workspace = nil
        case .existing(let id): workspace = id
        case .new: workspace = workspaceID
        }
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
            fallbackModel: trimmed(fallbackModel).isEmpty ? nil : trimmed(fallbackModel),
            workspaceId: workspace)
    }

    /// Model names offered in the menu. Other runtimes take free text only.
    public static func modelPresets(for runtime: RuntimeKind) -> [String] {
        runtime == .claude ? ["opus", "sonnet", "haiku"] : []
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
