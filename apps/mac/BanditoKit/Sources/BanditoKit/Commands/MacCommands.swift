import Foundation

/// A command or skill found on this Mac (`~/.claude/commands`, `~/.claude/skills`). Not sent anywhere
/// until the person runs it for the first time and agrees to install it on the server.
public struct MacCommand: Sendable, Identifiable, Hashable {
    /// The name after the slash, `git:commit` for `commands/git/commit.md`.
    public var name: String
    public var kind: CommandKind
    public var description: String?
    public var argsHint: String?
    /// A command has one file. A skill has every file of its folder, paths relative to the folder.
    public var files: [MacCommandFile]

    public var id: String { "\(kind.rawValue):\(name)" }

    public init(
        name: String, kind: CommandKind, description: String?, argsHint: String?, files: [MacCommandFile]
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.argsHint = argsHint
        self.files = files
    }
}

public struct MacCommandFile: Sendable, Hashable {
    /// Relative path, `/`-separated, e.g. `git/commit.md` or `scripts/run.sh`.
    public var path: String
    public var data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// Reads one command or skill from file contents. Pure, so it is tested without a file system.
public enum MacCommandParser {
    /// A command file: `commands/<folders>/<name>.md`. `relativePath` is relative to `commands/`.
    public static func command(relativePath: String, data: Data) -> MacCommand? {
        guard relativePath.hasSuffix(".md") else { return nil }
        let stem = String(relativePath.dropLast(3))
        let segments = stem.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.allSatisfy(isValidSegment) else { return nil }
        let fields = frontMatter(text(data))
        return MacCommand(
            name: segments.joined(separator: ":"),
            kind: .command,
            description: fields["description"],
            argsHint: fields["argument-hint"] ?? fields["args"],
            files: [MacCommandFile(path: relativePath, data: data)])
    }

    /// A skill folder: `skills/<folder>/SKILL.md` plus any files beside it.
    public static func skill(folder: String, files: [MacCommandFile]) -> MacCommand? {
        guard isValidSegment(folder), let main = files.first(where: { $0.path == "SKILL.md" }) else { return nil }
        let fields = frontMatter(text(main.data))
        let declared = fields["name"].flatMap { isValidSegment($0) ? $0 : nil }
        return MacCommand(
            name: declared ?? folder,
            kind: .skill,
            description: fields["description"],
            argsHint: nil,
            files: files.sorted { $0.path < $1.path })
    }

    /// Top-level `key: value` pairs of the YAML block between two `---` lines. Quotes are removed,
    /// nested and multi-line values are not read, and keys with an empty value are left out.
    public static func frontMatter(_ text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        guard lines.first == "---" else { return [:] }
        lines.removeFirst()
        guard let end = lines.firstIndex(of: "---") else { return [:] }
        var fields: [String: String] = [:]
        for line in lines[..<end] {
            guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    /// Names are one or more of `A-Z a-z 0-9 _ . -`, and do not start with a dot.
    static func isValidSegment(_ segment: String) -> Bool {
        guard !segment.isEmpty, !segment.hasPrefix(".") else { return false }
        return segment.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}

/// Finds the commands and skills under a `~/.claude` folder, with the daemon's limits: files up to
/// 256 KiB, a skill up to 50 files and 2 MiB, folders up to 4 levels deep, no symbolic links.
public enum MacCommandScanner {
    public static let maxFileBytes = 256 * 1024
    public static let maxSkillFiles = 50
    public static let maxSkillBytes = 2 * 1024 * 1024
    /// Path components below `commands/` or `skills/`, the file included.
    static let maxDepth = 5

    public static func scan(claudeHome: URL, fileManager: FileManager = .default) -> [MacCommand] {
        var found: [MacCommand] = []

        let commandsRoot = claudeHome.appendingPathComponent("commands", isDirectory: true)
        for file in regularFiles(under: commandsRoot, fileManager: fileManager) where file.path.hasSuffix(".md") {
            guard let size = fileSize(file), size <= maxFileBytes,
                let data = try? Data(contentsOf: file),
                let command = MacCommandParser.command(relativePath: relative(file, to: commandsRoot), data: data)
            else { continue }
            found.append(command)
        }

        let skillsRoot = claudeHome.appendingPathComponent("skills", isDirectory: true)
        let folders = (try? fileManager.contentsOfDirectory(at: skillsRoot, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where isRealDirectory(folder) {
            var files: [MacCommandFile] = []
            var total = 0
            var tooBig = false
            for file in regularFiles(under: folder, fileManager: fileManager) {
                guard let size = fileSize(file), size <= maxFileBytes else { tooBig = true; break }
                total += size
                guard let data = try? Data(contentsOf: file) else { continue }
                files.append(MacCommandFile(path: relative(file, to: folder), data: data))
            }
            guard !tooBig, files.count <= maxSkillFiles, total <= maxSkillBytes,
                let skill = MacCommandParser.skill(folder: folder.lastPathComponent, files: files)
            else { continue }
            found.append(skill)
        }

        return found.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    /// Regular files below `root`, skipping symbolic links and anything deeper than `maxDepth`.
    private static func regularFiles(under root: URL, fileManager: FileManager) -> [URL] {
        guard isRealDirectory(root),
            let walker = fileManager.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            let depth = relative(url, to: root).split(separator: "/").count
            if depth > maxDepth { walker.skipDescendants(); continue }
            if values?.isRegularFile == true { files.append(url) }
        }
        return files
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : url.lastPathComponent
    }
}
