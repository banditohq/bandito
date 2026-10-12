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

    /// The app's language as a locale tag (`ru`, `zh-Hans`…): the one the strings are in.
    static var languageCode: String {
        L10n.bundle.preferredLocalizations.first ?? "en"
    }

    /// The text of a failure the screens show: the daemon's message, or the connection's.
    static func errorText(_ error: Error) -> String {
        (error as? RPCError)?.message ?? error.localizedDescription
    }
}
