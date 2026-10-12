import BanditoKit
import BanditoL10n
import Foundation

/// The glue of the agent forms on iPhone that is not shared: the runtime a new agent starts on, the body of the one-agent
/// request from the form's fields, the approval order, the language of the strings, and the text of a failure. The rules
/// themselves (the model, the folder, the rights, the ready teams) are BanditoKit's.
enum AgentForms {
    /// The runtimes a person can run an agent on, in the Mac's order.
    static let runtimes = [RuntimeKind.claude, .codex, .grok]

    /// The approval choices in the order the Mac shows them: about everything, only the risky ones, about nothing.
    static let approvalOrder: [ApprovalMode] = [.always, .risky, .never]

    /// The runtime a new agent starts on: the first of `runtimes` that the server has installed.
    static func defaultRuntime(_ statuses: [RuntimeStatus]) -> RuntimeKind? {
        runtimes.first { kind in statuses.contains { $0.kind == kind && $0.installed } }
    }

    /// Whether the one-agent form can be sent: a name, an installed runtime, a folder, and no request under way.
    static func canCreateOne(name: String, runtime: RuntimeKind?, folder: String, busy: Bool) -> Bool {
        guard !busy, runtime != nil, !folder.isEmpty else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The body of `agents.create` for the one-agent form. The optional fields are sent only when set.
    static func newAgent(
        name: String, role: String, runtime: RuntimeKind, model: String?, folder: String, approval: ApprovalMode,
        effort: Effort?, permissions: Set<AgentCapability>
    ) -> NewAgent {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewAgent(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role.trimmingCharacters(in: .whitespacesAndNewlines),
            runtime: runtime,
            model: trimmedModel?.isEmpty == false ? trimmedModel : nil,
            cwd: folder,
            approvalMode: approval,
            effort: effort,
            capabilities: AgentCapability.wire(permissions))
    }

    /// The model and the effort of the one-agent form after the runtime changed, as the Mac's sheet does it: a picked model
    /// stays only when the new runtime's list names it (else the runtime's default comes back), and the effort moves to the
    /// nearest level the new runtime takes.
    static func afterRuntimeChange(
        to runtime: RuntimeKind, pickedModel: String?, effort: Effort?, lists: [String: RuntimeModelList]
    ) -> (pickedModel: String?, effort: Effort?) {
        var model = pickedModel
        if let picked = pickedModel, !picked.isEmpty, let list = lists[runtime.rawValue], !list.models.isEmpty,
           !list.models.contains(where: { $0.id == picked })
        {
            model = nil
        }
        return (model, effort.flatMap { $0.nearest(in: runtime.supportedEfforts) })
    }

    /// The patch that moves an agent to another runtime, as the Mac's `switchRuntime` does it: a fallback that becomes the
    /// primary is cleared in the same patch, and the model is kept only when the new runtime's list names it. Without a
    /// list the model goes to the runtime's default (the Mac also keeps a preset here; the iPhone has no presets).
    static func runtimeSwitch(of agent: Agent, to kind: RuntimeKind, lists: [String: RuntimeModelList]) -> AgentPatch {
        var patch = AgentPatch(runtime: kind)
        if agent.fallbackRuntime == kind {
            patch.fallbackRuntime = .clear
            patch.fallbackModel = .clear
        }
        if let current = agent.model, !current.isEmpty {
            let kept: String
            if let list = lists[kind.rawValue], list.models.contains(where: { $0.id == current }) {
                kept = current
            } else {
                kept = ""
            }
            patch.model = kept.isEmpty ? .clear : .set(kept)
        }
        return patch
    }

    /// The app's language as a locale tag (`ru`, `zh-Hans`…): the one the strings are in.
    static var languageCode: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }

    /// The text of a failure the screens show: the daemon's message, or the connection's.
    static func errorText(_ error: Error) -> String {
        (error as? RPCError)?.message ?? error.localizedDescription
    }
}
