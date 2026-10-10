import BanditoKit
import Foundation
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

/// Why "Create" cannot be pressed yet, and what the sheet shows under the button. Nil means it can.
public enum CreateBlocker: Equatable, Sendable {
    case runtimeMissing(RuntimeKind)
    /// The runtime is installed but not signed in; `command` is what to run on the server.
    case runtimeLogin(RuntimeKind, command: String)
    case folder
    case workplace
}

/// Everything the new agent sheet collects before `agents.create`. Pure: the sheet only binds to it.
public struct NewAgentDraft: Equatable, Sendable {
    public var name = ""
    public var role = ""
    public var color: AvatarColor = .peach
    /// A custom tile color as `#RRGGBB`; wins over `color` when set.
    public var customHex: String?
    public var face: AvatarFace = .chevronDash
    /// One emoji shown instead of the face when there is no picture.
    public var emoji: String?
    /// The framed picture as PNG. Sent right after the agent is created: `agents.avatar_image_set` needs its id.
    public var picture: Data?
    public var runtime: RuntimeKind = .claude
    /// Empty means the runtime's default model.
    public var model = ""
    public var effort: Effort = .medium
    public var instructions = ""
    /// The project folder on the server. Empty until one is picked.
    public var cwd = ""
    /// The server takes an agent without a folder (`agent_own_folder`): the agent then works in its own folder.
    public var folderOptional = false
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
    /// The "What it may do" chips. Sent with `agents.create` as `capabilities`; a daemon without the field ignores it,
    /// so nothing is enforced until the daemon has it.
    public var capabilities: Set<AgentCapability> = AgentCapability.allOn

    public init() {}

    /// "Agent N": the name of an agent created without one.
    public static func defaultName(_ number: Int) -> String {
        L10n.AgentSheet.autoName(number: "\(number)")
    }

    /// The project folder is required unless the server takes an agent without one (`folderOptional`); the name is
    /// optional, see `resolvedName`. A new container needs a valid name and limits. The runtime is checked by
    /// `createBlocker`.
    public var canCreate: Bool {
        (folderOptional || !trimmed(cwd).isEmpty) && workplaceReady
    }

    /// The first reason creation cannot happen, in the order the sheet explains it: the runtime, then the folder,
    /// then the workplace. `status` is nil while `runtimes.status` has not answered yet: nothing is blocked then.
    public func createBlocker(status: RuntimeStatus?) -> CreateBlocker? {
        if let status, !status.installed {
            return .runtimeMissing(runtime)
        }
        if let status, status.loggedIn == false {
            return .runtimeLogin(runtime, command: LoginCommand.arguments(for: runtime).joined(separator: " "))
        }
        if !folderOptional && trimmed(cwd).isEmpty {
            return .folder
        }
        if !workplaceReady {
            return .workplace
        }
        return nil
    }

    /// The name the agent is created with. A typed name wins. Otherwise the role is used when it is a valid name
    /// nobody has yet, and failing that "Agent N", where N is the first number no agent of the server has.
    public func resolvedName(existing: [String]) -> String {
        let typed = trimmed(name)
        if !typed.isEmpty {
            return typed
        }
        let role = trimmed(role)
        if !role.isEmpty, AgentNameRule.problem(for: role, existing: existing) == nil {
            return role
        }
        var number = 1
        while existing.contains(where: { $0.caseInsensitiveCompare(NewAgentDraft.defaultName(number)) == .orderedSame }) {
            number += 1
        }
        return NewAgentDraft.defaultName(number)
    }

    /// The chosen workplace can be used: the shared server, an existing container, or a new one with a valid form.
    public var workplaceReady: Bool {
        workplace != .new || newWorkplace.canCreate
    }

    /// Switches the runtime. The effort is lowered to a level the new runtime offers. The model is kept only when
    /// the new runtime offers it (see `RuntimeModelDisplay.model(afterSwitchingTo:keeping:lists:)`); `lists` are the
    /// server's model lists. Choosing the runtime that is already chosen changes nothing.
    public mutating func setRuntime(_ next: RuntimeKind, lists: [String: RuntimeModelList] = [:]) {
        let previous = runtime
        runtime = next
        effort = next.clampedEffort(effort)
        if next != previous {
            model = RuntimeModelDisplay.model(afterSwitchingTo: next, keeping: model, lists: lists)
        }
        // The fallback must be another runtime: a fallback that became the primary is dropped.
        if fallbackRuntime == next {
            fallbackRuntime = nil
            fallbackModel = ""
        }
    }

    /// Picks the fallback runtime (nil: do not switch). The fallback model is kept only when the new runtime offers it.
    public mutating func setFallbackRuntime(_ next: RuntimeKind?, lists: [String: RuntimeModelList] = [:]) {
        guard next != fallbackRuntime else { return }
        fallbackRuntime = next
        fallbackModel = next.map {
            RuntimeModelDisplay.model(afterSwitchingTo: $0, keeping: fallbackModel, lists: lists)
        } ?? ""
    }

    /// The runtimes that can be the fallback of `runtime`: the other pickable ones.
    public static func fallbackOptions(for runtime: RuntimeKind) -> [RuntimeKind] {
        RuntimeKind.pickable.filter { $0 != runtime }
    }

    /// The request for `agents.create`. `workspaceID` is the id of the container made for `.new` (see
    /// `WorkplaceCreation.prepare`); the other choices name their workspace themselves. `existingNames` are the
    /// names of the server's agents, used for the default name. `lists` are the server's model lists: a model that
    /// takes no effort is sent without one, and the effort is moved to a level the model takes.
    public func makeNewAgent(
        workspaceID: String? = nil, existingNames: [String] = [], lists: [String: RuntimeModelList] = [:]
    ) -> NewAgent {
        let model = trimmed(model)
        let instructions = trimmed(instructions)
        let workspace: String?
        switch workplace {
        case .shared: workspace = nil
        case .existing(let id): workspace = id
        case .new: workspace = workspaceID
        }
        return NewAgent(
            name: resolvedName(existing: existingNames),
            role: trimmed(role),
            runtime: runtime,
            model: model.isEmpty ? nil : model,
            cwd: trimmed(cwd),
            approvalMode: approval.mode,
            systemPrompt: instructions.isEmpty ? nil : instructions,
            effort: RuntimeModelDisplay.effort(effort, modelID: model, runtime: runtime, lists: lists),
            memoryMode: memory,
            fallbackRuntime: fallbackRuntime,
            fallbackModel: trimmed(fallbackModel).isEmpty ? nil : trimmed(fallbackModel),
            workspaceId: workspace,
            avatar: AvatarSpec(color: customHex ?? color.rawValue, face: face.rawValue, emoji: emoji),
            capabilities: AgentCapability.wire(capabilities))
    }

    /// Model names offered in the menu. Other runtimes take free text only.
    public static func modelPresets(for runtime: RuntimeKind) -> [String] {
        runtime == .claude ? ["opus", "sonnet", "haiku"] : []
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
