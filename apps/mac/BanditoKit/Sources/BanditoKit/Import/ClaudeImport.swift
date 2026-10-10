import Foundation

// Import from Claude Code and Codex: what the Mac holds that Bandito can take over (docs/ARCHITECTURE.md#import).
// Reads only the folders named below; changes and deletes nothing on the Mac; follows no symbolic link; reads no file
// over 256 KiB; never reads settings, credentials or keys.

public enum ImportKind: String, CaseIterable, Sendable {
    case agent, skill, command
}

/// Where an item was found.
public enum ImportOrigin: Hashable, Sendable {
    /// `~/.claude`
    case claudeUser
    /// `.claude` of a project folder the person chose; the folder's name.
    case claudeProject(String)
    /// `~/.codex/prompts`
    case codexPrompts
    /// `AGENTS.md` of a project folder; the folder's name.
    case projectInstructions(String)
}

/// A subagent file (`agents/<name>.md`) read for Bandito: the agent it would make.
public struct ImportedAgent: Equatable, Sendable {
    public var name: String
    /// The description cut short, for the agent's role.
    public var role: String
    /// The body of the file: the agent's system prompt.
    public var instructions: String
    /// The tools the file lists; nil when it lists none (the agent may use everything).
    public var tools: [String]?
    /// The model the file names, as written; nil when it names none or says `inherit`.
    public var model: String?

    /// The capabilities the tools stand for (see `ImportCapabilities`); nil when the file lists no tools.
    public var capabilities: [String]? { ImportCapabilities.wire(for: tools) }

    public init(name: String, role: String, instructions: String, tools: [String]?, model: String?) {
        self.name = name
        self.role = role
        self.instructions = instructions
        self.tools = tools
        self.model = model
    }
}

/// Why something found was not taken.
public enum ImportSkipReason: Error, Equatable, Sendable {
    /// A file over 256 KiB.
    case tooBig
    /// A file that is not text (not UTF-8, or holds a NUL byte) where text is needed.
    case notText
    /// A symbolic link; links are not followed.
    case link
    case tooManyFiles
    /// A skill folder over 2 MiB.
    case tooLarge
    /// A name the server cannot use.
    case badName
    /// A skill folder without `SKILL.md`.
    case noSkillFile
    case unreadable
    /// A subagent with no instructions.
    case empty
}

public struct ImportSkip: Equatable, Sendable, Identifiable {
    /// The path as shown (`~/.claude/agents/x.md`).
    public var path: String
    public var reason: ImportSkipReason
    public var id: String { path }
}

/// Something about an item the person should know before importing it.
public enum ImportWarning: Equatable, Sendable {
    /// Files of a skill folder that are not text; they are copied as they are.
    case nonTextFiles(Int)
    /// The text looks like it holds a key or a password.
    case looksLikeSecret
}

public struct ImportItem: Identifiable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case agent(ImportedAgent)
        case command(MacCommand)
    }

    public var kind: ImportKind
    public var origin: ImportOrigin
    public var name: String
    /// The description, one line.
    public var summary: String?
    /// The path as shown.
    public var path: String
    /// The front matter as `key: value` lines, for the preview.
    public var frontMatter: [String]
    /// The first lines of the body, for the preview.
    public var bodyPreview: String
    public var warnings: [ImportWarning]
    public var payload: Payload

    public var id: String { "\(kind.rawValue)|\(path)" }

    public init(
        kind: ImportKind, origin: ImportOrigin, name: String, summary: String?, path: String, frontMatter: [String],
        bodyPreview: String, warnings: [ImportWarning], payload: Payload
    ) {
        self.kind = kind
        self.origin = origin
        self.name = name
        self.summary = summary
        self.path = path
        self.frontMatter = frontMatter
        self.bodyPreview = bodyPreview
        self.warnings = warnings
        self.payload = payload
    }
}

public struct ImportScan: Equatable, Sendable {
    public var items: [ImportItem] = []
    public var skipped: [ImportSkip] = []

    public init() {}

    public func items(of kind: ImportKind) -> [ImportItem] { items.filter { $0.kind == kind } }
}

/// The tools of a Claude Code subagent as Bandito's capabilities: `Bash` is the terminal, `Edit`, `Write`, `MultiEdit` and
/// `NotebookEdit` are the files, `WebFetch` and `WebSearch` are the browser. Other tools (reading, searching, the todo
/// list, MCP tools) stand for nothing Bandito switches. A file that lists no tools leaves every capability on.
public enum ImportCapabilities {
    static let table: [String: String] = [
        "Bash": "terminal", "Edit": "files", "Write": "files", "MultiEdit": "files", "NotebookEdit": "files",
        "WebFetch": "browser", "WebSearch": "browser",
    ]
    /// The order of the wire list, as the chips have it.
    static let order = ["terminal", "files", "browser", "team", "screen"]

    /// `Bash(git:*)` is `Bash`.
    public static func toolName(_ raw: String) -> String {
        let name = raw.split(separator: "(", maxSplits: 1).first.map(String.init) ?? raw
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The wire list for the tools; nil when no tools are listed (everything on). A list of tools none of which stands for
    /// a capability gives an empty list: the agent keeps only what Claude Code's other tools do.
    public static func wire(for tools: [String]?) -> [String]? {
        guard let tools, !tools.isEmpty else { return nil }
        let wanted = Set(tools.compactMap { table[toolName($0)] })
        return order.filter(wanted.contains)
    }
}

/// Reads a subagent file.
public enum ImportAgentParser {
    /// The longest role.
    public static let maxRoleLength = 60
    /// The longest agent name the daemon takes.
    public static let maxNameLength = 32

    /// `text` is the file; `stem` its name without `.md`.
    public static func parse(stem: String, text: String) -> ImportedAgent {
        let matter = ImportFrontMatter.parse(text)
        let name = agentName(matter.text("name") ?? stem, fallback: stem)
        let model = matter.text("model").flatMap { $0.lowercased() == "inherit" ? nil : $0 }
        let tools = matter["tools"].map(\.asList).flatMap { $0.isEmpty ? nil : $0 }
        return ImportedAgent(
            name: name,
            role: role(from: matter.text("description") ?? ""),
            instructions: matter.body.trimmingCharacters(in: .whitespacesAndNewlines),
            tools: tools,
            model: model)
    }

    /// A name the daemon takes: letters, digits, spaces, `-` and `_`, at most 32. Anything else becomes a dash.
    public static func agentName(_ raw: String, fallback: String = "agent") -> String {
        let cleaned = String(raw.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        let cut = String(cleaned.prefix(maxNameLength)).trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
        if !cut.isEmpty { return cut }
        return fallback == raw ? "agent" : agentName(fallback, fallback: "agent")
    }

    /// The description cut to a short role: its first line, at most 60 characters, cut at a word and ended with `…`.
    public static func role(from description: String) -> String {
        let line = description.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.count > maxRoleLength else { return line }
        let head = String(line.prefix(maxRoleLength - 1))
        let atWord = head.lastIndex(of: " ").map { String(head[..<$0]) }
        let base = (atWord.map { $0.count >= 20 ? $0 : head } ?? head).trimmingCharacters(in: .whitespaces)
        return base + "…"
    }

    /// The model to send: the one the file names when the chosen runtime offers it (by its id, any case), or one of the
    /// aliases the Claude runtime takes; nil otherwise, and the agent uses the runtime's default.
    public static func model(_ raw: String?, runtime: RuntimeKind, lists: [String: RuntimeModelList]) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let offered = lists[runtime.rawValue]?.models.map(\.id) ?? []
        if let hit = offered.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) { return hit }
        if runtime == .claude, ["opus", "sonnet", "haiku"].contains(raw.lowercased()) { return raw.lowercased() }
        return nil
    }
}

/// Finds a key or a password in text, for a warning. A guess: it names only what is plainly one.
public enum ImportSecretCheck {
    private static let patterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"\bsk-[A-Za-z0-9_-]{20,}"#,
        #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        #"\bAKIA[0-9A-Z]{16}\b"#,
        #"\bxox[baprs]-[A-Za-z0-9-]{10,}"#,
        #"(?i)\b(api[_-]?key|secret|token|passw(or)?d)\b\s*[:=]\s*["']?[A-Za-z0-9/+_=.-]{16,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func looksLikeSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }
}

/// Reads the folders of Claude Code and Codex.
public enum ImportScanner {
    public static let maxFileBytes = MacCommandScanner.maxFileBytes
    public static let maxSkillFiles = MacCommandScanner.maxSkillFiles
    public static let maxSkillBytes = MacCommandScanner.maxSkillBytes
    /// Files looked at in one folder tree, so a huge tree cannot hold the screen.
    static let maxVisited = 5000
    /// Path components below `commands/`, the file included.
    static let maxDepth = 5
    static let previewLines = 12
    static let previewCharacters = 700

    /// `home` is the person's home folder; `project` a folder they chose, if any.
    public static func scan(home: URL, project: URL? = nil, fileManager: FileManager = .default) -> ImportScan {
        var result = ImportScan()
        let reader = Reader(home: home, fileManager: fileManager)
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        reader.agents(in: claude.appendingPathComponent("agents", isDirectory: true), origin: .claudeUser, into: &result)
        reader.skills(in: claude.appendingPathComponent("skills", isDirectory: true), origin: .claudeUser, into: &result)
        reader.commands(in: claude.appendingPathComponent("commands", isDirectory: true), origin: .claudeUser, into: &result)
        reader.prompts(in: home.appendingPathComponent(".codex/prompts", isDirectory: true), into: &result)
        if let project {
            let name = project.lastPathComponent
            let dot = project.appendingPathComponent(".claude", isDirectory: true)
            reader.agents(in: dot.appendingPathComponent("agents", isDirectory: true), origin: .claudeProject(name), into: &result)
            reader.skills(in: dot.appendingPathComponent("skills", isDirectory: true), origin: .claudeProject(name), into: &result)
            reader.commands(in: dot.appendingPathComponent("commands", isDirectory: true), origin: .claudeProject(name), into: &result)
            reader.instructions(project.appendingPathComponent("AGENTS.md"), folder: name, into: &result)
        }
        let order: [ImportKind: Int] = [.agent: 0, .skill: 1, .command: 2]
        result.items.sort { a, b in
            let left = (order[a.kind] ?? 0, a.name.lowercased(), a.path)
            let right = (order[b.kind] ?? 0, b.name.lowercased(), b.path)
            return left < right
        }
        return result
    }

    private struct Reader {
        let home: URL
        let fileManager: FileManager

        // MARK: pieces

        func shown(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            let base = home.standardizedFileURL.path
            return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
        }

        func isLink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        }

        func isRealDirectory(_ url: URL) -> Bool {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }

        /// A file's bytes, or why not.
        func read(_ url: URL) -> Result<Data, ImportSkipReason> {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                return .failure(.unreadable)
            }
            if values.isSymbolicLink == true { return .failure(.link) }
            guard values.isRegularFile == true else { return .failure(.unreadable) }
            if let size = values.fileSize, size > maxFileBytes { return .failure(.tooBig) }
            guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
            return data.count > maxFileBytes ? .failure(.tooBig) : .success(data)
        }

        func text(_ data: Data) -> String? {
            data.contains(0) ? nil : String(data: data, encoding: .utf8)
        }

        /// The regular files below `root` (relative paths), the links among them counted apart, within the limits.
        func walk(_ root: URL, maxDepth: Int) -> (files: [URL], links: [URL]) {
            guard isRealDirectory(root),
                let walker = fileManager.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles])
            else { return ([], []) }
            var files: [URL] = []
            var links: [URL] = []
            var visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited > ImportScanner.maxVisited { break }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    links.append(url)
                    walker.skipDescendants()
                    continue
                }
                if relative(url, to: root).split(separator: "/").count > maxDepth {
                    walker.skipDescendants()
                    continue
                }
                if values?.isRegularFile == true { files.append(url) }
            }
            return (files.sorted { $0.path < $1.path }, links)
        }

        func relative(_ url: URL, to root: URL) -> String {
            let base = root.standardizedFileURL.path + "/"
            let full = url.standardizedFileURL.path
            return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
        }

        func previewOf(_ matter: ImportFrontMatter) -> (front: [String], body: String) {
            let front = matter.keys.prefix(8).map { key -> String in
                let value = (matter[key]?.asText ?? "").replacingOccurrences(of: "\n", with: " ")
                return "\(key): \(value.count > 120 ? String(value.prefix(119)) + "…" : value)"
            }
            let lines = matter.body.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: false).prefix(ImportScanner.previewLines)
            var body = lines.joined(separator: "\n")
            if body.count > ImportScanner.previewCharacters { body = String(body.prefix(ImportScanner.previewCharacters - 1)) + "…" }
            return (front, body)
        }

        func oneLine(_ text: String?) -> String? {
            text?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        func skip(_ url: URL, _ reason: ImportSkipReason, into result: inout ImportScan) {
            result.skipped.append(ImportSkip(path: shown(url), reason: reason))
        }

        // MARK: agents

        func agents(in folder: URL, origin: ImportOrigin, into result: inout ImportScan) {
            guard isRealDirectory(folder) else { return }
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in names.sorted() where file.hasSuffix(".md") && !file.hasPrefix(".") {
                let url = folder.appendingPathComponent(file)
                switch read(url) {
                case .failure(let reason): skip(url, reason, into: &result)
                case .success(let data):
                    guard let content = text(data) else { skip(url, .notText, into: &result); continue }
                    let agent = ImportAgentParser.parse(stem: String(file.dropLast(3)), text: content)
                    if agent.instructions.isEmpty { skip(url, .empty, into: &result); continue }
                    result.items.append(agentItem(agent, content: content, origin: origin, url: url))
                }
            }
        }

        func agentItem(_ agent: ImportedAgent, content: String, origin: ImportOrigin, url: URL) -> ImportItem {
            let matter = ImportFrontMatter.parse(content)
            let preview = previewOf(matter)
            return ImportItem(
                kind: .agent, origin: origin, name: agent.name, summary: oneLine(matter.text("description")),
                path: shown(url), frontMatter: preview.front, bodyPreview: preview.body,
                warnings: ImportSecretCheck.looksLikeSecret(content) ? [.looksLikeSecret] : [], payload: .agent(agent))
        }

        /// `AGENTS.md` of a project: one agent made from it, named after the folder.
        func instructions(_ file: URL, folder: String, into result: inout ImportScan) {
            guard fileManager.fileExists(atPath: file.path) || isLink(file) else { return }
            switch read(file) {
            case .failure(let reason): skip(file, reason, into: &result)
            case .success(let data):
                guard let content = text(data) else { skip(file, .notText, into: &result); return }
                let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty { skip(file, .empty, into: &result); return }
                let agent = ImportedAgent(
                    name: ImportAgentParser.agentName(folder), role: "AGENTS.md", instructions: body, tools: nil, model: nil)
                let preview = previewOf(ImportFrontMatter.parse(content))
                result.items.append(
                    ImportItem(
                        kind: .agent, origin: .projectInstructions(folder), name: agent.name, summary: nil,
                        path: shown(file), frontMatter: preview.front, bodyPreview: preview.body,
                        warnings: ImportSecretCheck.looksLikeSecret(content) ? [.looksLikeSecret] : [],
                        payload: .agent(agent)))
            }
        }

        // MARK: commands

        func commands(in root: URL, origin: ImportOrigin, into result: inout ImportScan) {
            let found = walk(root, maxDepth: ImportScanner.maxDepth)
            for link in found.links { skip(link, .link, into: &result) }
            for url in found.files where url.pathExtension == "md" {
                switch read(url) {
                case .failure(let reason): skip(url, reason, into: &result)
                case .success(let data):
                    guard let content = text(data) else { skip(url, .notText, into: &result); continue }
                    guard let command = MacCommandParser.command(relativePath: relative(url, to: root), data: data) else {
                        skip(url, .badName, into: &result)
                        continue
                    }
                    result.items.append(commandItem(command, content: content, origin: origin, url: url))
                }
            }
        }

        /// `~/.codex/prompts/*.md`: each file is a command.
        func prompts(in folder: URL, into result: inout ImportScan) {
            guard isRealDirectory(folder) else { return }
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in names.sorted() where file.hasSuffix(".md") && !file.hasPrefix(".") {
                let url = folder.appendingPathComponent(file)
                switch read(url) {
                case .failure(let reason): skip(url, reason, into: &result)
                case .success(let data):
                    guard let content = text(data) else { skip(url, .notText, into: &result); continue }
                    guard let command = MacCommandParser.command(relativePath: file, data: data) else {
                        skip(url, .badName, into: &result)
                        continue
                    }
                    result.items.append(commandItem(command, content: content, origin: .codexPrompts, url: url))
                }
            }
        }

        func commandItem(_ command: MacCommand, content: String, origin: ImportOrigin, url: URL) -> ImportItem {
            let matter = ImportFrontMatter.parse(content)
            let preview = previewOf(matter)
            return ImportItem(
                kind: .command, origin: origin, name: command.name, summary: oneLine(matter.text("description")),
                path: shown(url), frontMatter: preview.front, bodyPreview: preview.body,
                warnings: ImportSecretCheck.looksLikeSecret(content) ? [.looksLikeSecret] : [], payload: .command(command))
        }

        // MARK: skills

        func skills(in root: URL, origin: ImportOrigin, into result: inout ImportScan) {
            guard isRealDirectory(root) else { return }
            let folders = ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
            for folderName in folders where !folderName.hasPrefix(".") {
                let folder = root.appendingPathComponent(folderName, isDirectory: true)
                if isLink(folder) { skip(folder, .link, into: &result); continue }
                guard isRealDirectory(folder) else { continue }
                if let item = skill(folder: folder, origin: origin, into: &result) { result.items.append(item) }
            }
        }

        func skill(folder: URL, origin: ImportOrigin, into result: inout ImportScan) -> ImportItem? {
            guard MacCommandParser.isValidSegment(folder.lastPathComponent) else {
                skip(folder, .badName, into: &result)
                return nil
            }
            let found = walk(folder, maxDepth: ImportScanner.maxDepth)
            if !found.links.isEmpty { skip(folder, .link, into: &result); return nil }
            guard found.files.contains(where: { relative($0, to: folder) == "SKILL.md" }) else {
                skip(folder, .noSkillFile, into: &result)
                return nil
            }
            if found.files.count > maxSkillFiles { skip(folder, .tooManyFiles, into: &result); return nil }
            var files: [MacCommandFile] = []
            var total = 0
            var nonText = 0
            for url in found.files {
                switch read(url) {
                case .failure(let reason): skip(folder, reason, into: &result); return nil
                case .success(let data):
                    total += data.count
                    let path = relative(url, to: folder)
                    if text(data) == nil {
                        // `SKILL.md` has to be text; other files may be pictures or data and travel as they are.
                        if path == "SKILL.md" { skip(folder, .notText, into: &result); return nil }
                        nonText += 1
                    }
                    files.append(MacCommandFile(path: path, data: data))
                }
            }
            if total > maxSkillBytes { skip(folder, .tooLarge, into: &result); return nil }
            guard let skill = MacCommandParser.skill(folder: folder.lastPathComponent, files: files),
                let main = files.first(where: { $0.path == "SKILL.md" })
            else { return nil }
            let content = text(main.data) ?? ""
            let matter = ImportFrontMatter.parse(content)
            let preview = previewOf(matter)
            var warnings: [ImportWarning] = []
            if nonText > 0 { warnings.append(.nonTextFiles(nonText)) }
            let secret = files.contains { file in text(file.data).map(ImportSecretCheck.looksLikeSecret) == true }
            if secret { warnings.append(.looksLikeSecret) }
            return ImportItem(
                kind: .skill, origin: origin, name: skill.name, summary: oneLine(matter.text("description")),
                path: shown(folder), frontMatter: preview.front, bodyPreview: preview.body, warnings: warnings,
                payload: .command(skill))
        }
    }
}
