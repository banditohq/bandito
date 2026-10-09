import Foundation

// Slash commands as the daemon lists them (`commands.list`) and as it installs them (`commands.install`).
// Source of truth: daemon/src/commands.rs, docs/ARCHITECTURE.md#commands.

/// Where a daemon-listed command comes from.
public enum CommandSource: String, ForwardCompatibleEnum, CaseIterable {
    /// `<agent folder>/.claude/commands/**/*.md`
    case project
    /// `~/.claude/commands/**/*.md` on the server
    case user
    /// `~/.claude/skills/<name>/SKILL.md` or the agent folder's `.claude/skills`
    case skill
    /// `~/.codex/prompts/*.md`
    case codexPrompt = "codex_prompt"

    public static var fallback: CommandSource { .user }
}

/// What a command file holds: one Markdown prompt, or a skill folder with `SKILL.md`.
public enum CommandKind: String, ForwardCompatibleEnum, CaseIterable {
    case command, skill

    public static var fallback: CommandKind { .command }
}

/// One slash command the agent can run, as listed by the daemon. No file content.
public struct AgentCommand: Codable, Sendable, Identifiable, Hashable {
    /// The name after the slash, e.g. `git:commit`.
    public var name: String
    public var description: String?
    /// Hint for the arguments, e.g. `[message]`.
    public var argsHint: String?
    public var source: CommandSource
    public var path: String
    /// True when the CLI runs the command itself (Claude), so `/name args` goes to it as typed.
    public var runtimeNative: Bool

    public var id: String { "\(source.rawValue):\(name)" }

    public init(
        name: String, description: String?, argsHint: String?, source: CommandSource, path: String,
        runtimeNative: Bool
    ) {
        self.name = name
        self.description = description
        self.argsHint = argsHint
        self.source = source
        self.path = path
        self.runtimeNative = runtimeNative
    }
}

/// One file of an install request. `content` is standard base64.
public struct CommandFile: Codable, Sendable, Hashable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// Body of `commands.install`. Scope `user` writes under the server user's home.
public struct CommandInstallRequest: Codable, Sendable, Hashable {
    public var scope: String
    /// Only for scope `project`.
    public var agentId: String?
    public var kind: CommandKind
    public var name: String
    public var files: [CommandFile]
    public var overwrite: Bool

    public init(
        scope: String, agentId: String? = nil, kind: CommandKind, name: String, files: [CommandFile],
        overwrite: Bool = false
    ) {
        self.scope = scope
        self.agentId = agentId
        self.kind = kind
        self.name = name
        self.files = files
        self.overwrite = overwrite
    }

    /// Install request for a command or skill found on this Mac, into the server user's home.
    public static func user(_ command: MacCommand, overwrite: Bool = false) -> CommandInstallRequest {
        CommandInstallRequest(
            scope: "user",
            kind: command.kind,
            name: command.name,
            files: command.files.map { CommandFile(path: $0.path, content: $0.data.base64EncodedString()) },
            overwrite: overwrite)
    }
}
