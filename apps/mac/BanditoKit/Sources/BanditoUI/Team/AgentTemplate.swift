import BanditoKit
import BanditoL10n

/// The starting points of the new agent sheet ("From template…"). Each sets the runtime, effort,
/// role and instructions; the name is left to the person.
public enum AgentTemplate: CaseIterable, Sendable {
    case builder, reviewer, oncall, assistant, researcher, scratch

    public var title: String {
        switch self {
        case .builder: L10n.Template.Builder.title
        case .reviewer: L10n.Template.Reviewer.title
        case .oncall: L10n.Template.Oncall.title
        case .assistant: L10n.Template.Assistant.title
        case .researcher: L10n.Template.Researcher.title
        case .scratch: L10n.Template.Scratch.title
        }
    }

    public var description: String {
        switch self {
        case .builder: L10n.Template.Builder.desc
        case .reviewer: L10n.Template.Reviewer.desc
        case .oncall: L10n.Template.Oncall.desc
        case .assistant: L10n.Template.Assistant.desc
        case .researcher: L10n.Template.Researcher.desc
        case .scratch: L10n.Template.Scratch.desc
        }
    }

    public var meta: String {
        switch self {
        case .builder: L10n.Template.Builder.meta
        case .reviewer: L10n.Template.Reviewer.meta
        case .oncall: L10n.Template.Oncall.meta
        case .assistant: L10n.Template.Assistant.meta
        case .researcher: L10n.Template.Researcher.meta
        case .scratch: L10n.Template.Scratch.meta
        }
    }

    /// Instructions the template starts with. Empty for "From scratch".
    public var instructions: String {
        switch self {
        case .builder: L10n.Template.Builder.instructions
        case .reviewer: L10n.Template.Reviewer.instructions
        case .oncall: L10n.Template.Oncall.instructions
        case .assistant: L10n.Template.Assistant.instructions
        case .researcher: L10n.Template.Researcher.instructions
        case .scratch: ""
        }
    }

    public var runtime: RuntimeKind {
        switch self {
        case .reviewer: .codex
        case .researcher: .grok
        case .builder, .oncall, .assistant, .scratch: .claude
        }
    }

    public var effort: Effort {
        switch self {
        case .reviewer, .researcher: .high
        case .oncall: .low
        case .builder, .assistant, .scratch: .medium
        }
    }

    /// Fills the draft's runtime, effort, role and instructions. The name and folder are kept.
    public func apply(to draft: inout NewAgentDraft) {
        draft.setRuntime(runtime)
        draft.effort = effort
        draft.role = self == .scratch ? "" : title
        draft.instructions = instructions
    }
}
