import BanditoKit
import Foundation

/// A key and value found in a pasted config, already sorted into "secret or not".
struct ParsedPair: Equatable {
    var key: String
    /// The literal, or the secret's value when `isSecret` and the config held one. Empty for a placeholder.
    var value: String
    var isSecret: Bool
    /// `Bearer {secret}` for a header whose value is a scheme and a token; nil when the value is the secret itself.
    var template: String?
}

/// One MCP server found in a pasted config.
struct ParsedServer: Equatable {
    /// The name the config gave it, or one guessed from the package or the address. Nil when there is no clue.
    var name: String?
    var kind: IntegrationKind
    /// For a program: the command and its arguments. Empty for a web address.
    var command: String
    var args: [String]
    /// For a web address.
    var url: String
    var env: [ParsedPair]
    var headers: [ParsedPair]

    /// The command line as the sheet shows it.
    var commandLine: String { ShellWords.join(command.isEmpty ? [] : [command] + args) }
}

/// Why a pasted text is not a server.
enum ConfigParseFailure: Equatable {
    case empty
    /// Starts like JSON, but does not parse.
    case invalidJSON
    /// JSON, but with no server in it (no `command` and no `url`).
    case noServers
    /// A quote that is not closed.
    case unclosedQuote
    /// Text that is neither JSON, a URL, nor a command of a known program. Carries the first word.
    case notACommand(String)
}

enum ConfigParseResult: Equatable {
    case servers([ParsedServer])
    case failure(ConfigParseFailure)
}

/// Reads what the owner pastes from a server's documentation: a Claude Desktop or Cursor config, one server's object,
/// a command line, or a URL. Pure.
enum MCPConfigParser {
    static func parse(_ text: String) -> ConfigParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("\"") || trimmed.hasPrefix("[") {
            return parseJSON(trimmed)
        }
        return parseText(trimmed)
    }

    // MARK: - JSON

    private static let containerKeys = ["mcpServers", "servers", "context_servers"]

    private static func parseJSON(_ text: String) -> ConfigParseResult {
        guard let root = jsonObject(text) else { return .failure(.invalidJSON) }
        if let containers = serverContainer(root) {
            let servers = containers.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .compactMap { name in (containers[name] as? [String: Any]).flatMap { server($0, name: name) } }
            return servers.isEmpty ? .failure(.noServers) : .servers(servers)
        }
        if let single = server(root, name: nil) { return .servers([single]) }
        // A fragment such as `"github": { … }`, wrapped in braces by `jsonObject`.
        let named = root.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in (root[name] as? [String: Any]).flatMap { server($0, name: name) } }
        return named.isEmpty ? .failure(.noServers) : .servers(named)
    }

    /// The object, from text that is an object, or a `"name": { … }` fragment, with a trailing comma tolerated.
    private static func jsonObject(_ text: String) -> [String: Any]? {
        var candidates = [text]
        if text.hasPrefix("\"") { candidates = ["{" + text + "}"] }
        if text.hasPrefix("{") { candidates.append(text.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)) }
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
                let value = try? JSONSerialization.jsonObject(with: data),
                let object = value as? [String: Any]
            {
                return object
            }
        }
        return nil
    }

    private static func serverContainer(_ root: [String: Any]) -> [String: Any]? {
        for key in containerKeys {
            if let found = root[key] as? [String: Any] { return found }
        }
        // VS Code's user settings: `{ "mcp": { "servers": { … } } }`.
        if let mcp = root["mcp"] as? [String: Any], let found = mcp["servers"] as? [String: Any] { return found }
        return nil
    }

    /// A server from its object: `command` (with `args`, `env`) or `url` (with `headers`). Nil with neither.
    private static func server(_ object: [String: Any], name: String?) -> ParsedServer? {
        let url = ["url", "serverUrl", "httpUrl"].compactMap { object[$0] as? String }.first
        let type = (object["type"] as? String)?.lowercased()
        // Zed writes `"command": { "path": …, "args": […], "env": {…} }`.
        let zed = object["command"] as? [String: Any]
        let commandText = (object["command"] as? String) ?? (zed?["path"] as? String)
        if let commandText, type != "http", type != "sse" {
            var args = strings(object["args"] ?? zed?["args"])
            var command = commandText.trimmingCharacters(in: .whitespaces)
            // `"command": "npx -y pkg"` with no `args`: one line, as the documentation of some servers has it.
            if args.isEmpty, command.contains(" "), let words = ShellWords.split(command), words.count > 1 {
                command = words[0]
                args = Array(words.dropFirst())
            }
            let env = (object["env"] as? [String: Any]) ?? (zed?["env"] as? [String: Any]) ?? [:]
            return ParsedServer(
                name: name ?? guessName(command: command, args: args), kind: .stdio, command: command, args: args,
                url: "", env: pairs(env, header: false), headers: [])
        }
        if let url {
            let headers = (object["headers"] as? [String: Any]) ?? [:]
            return ParsedServer(
                name: name ?? guessName(url: url), kind: .http, command: "", args: [], url: url, env: [],
                headers: pairs(headers, header: true))
        }
        return nil
    }

    private static func strings(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            if let text = item as? String { return text }
            if let number = item as? NSNumber { return number.stringValue }
            return nil
        }
    }

    private static func pairs(_ map: [String: Any], header: Bool) -> [ParsedPair] {
        map.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { key in
            let value: String
            switch map[key] {
            case let text as String: value = text
            case let number as NSNumber: value = number.stringValue
            default: value = ""
            }
            return classify(key: key, value: value, header: header)
        }
    }

    // MARK: - values

    /// `${TOKEN}`, `$TOKEN`, `{{token}}`, `<your-token>`, or a `YOUR_…` / `…_HERE` filler.
    private static let placeholder = try? NSRegularExpression(
        pattern: #"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\{\{[^}]*\}\}|<[^<>\s][^<>]*>|YOUR[_-][A-Za-z0-9_-]+|[A-Za-z0-9_-]+_HERE"#)

    private static func looksSecret(_ key: String) -> Bool {
        let lower = key.lowercased()
        return ["key", "token", "secret", "password", "passwd", "auth", "credential", "bearer"].contains {
            lower.contains($0)
        }
    }

    /// Sorts one value: a placeholder is a secret to type in, a value under a key like `…_TOKEN` is a secret with its
    /// value, anything else is a plain literal.
    static func classify(key: String, value: String, header: Bool) -> ParsedPair {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return ParsedPair(key: key, value: "", isSecret: true, template: nil) }
        let range = NSRange(value.startIndex..., in: value)
        if let match = placeholder?.firstMatch(in: value, range: range), let swiftRange = Range(match.range, in: value) {
            var template = value
            template.replaceSubrange(swiftRange, with: "{secret}")
            return ParsedPair(key: key, value: "", isSecret: true, template: template == "{secret}" ? nil : template)
        }
        if looksSecret(key) {
            if header, let space = value.firstIndex(of: " "),
                ["bearer", "basic", "token"].contains(value[..<space].lowercased())
            {
                let rest = String(value[value.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                return ParsedPair(key: key, value: rest, isSecret: true, template: String(value[..<space]) + " {secret}")
            }
            return ParsedPair(key: key, value: value, isSecret: true, template: nil)
        }
        return ParsedPair(key: key, value: value, isSecret: false, template: nil)
    }

    // MARK: - text

    /// Programs a pasted command may start with. Anything with a path in it is accepted too.
    private static let launchers: Set<String> = [
        "npx", "uvx", "uv", "pipx", "bunx", "bun", "deno", "node", "npm", "pnpm", "yarn", "python", "python3",
        "docker", "podman", "java", "go", "cargo", "dotnet", "ruby", "php", "sh", "bash",
    ]

    private static func parseText(_ text: String) -> ConfigParseResult {
        var line = text
        for prompt in ["$ ", "> ", "% "] where line.hasPrefix(prompt) { line = String(line.dropFirst(prompt.count)) }
        guard var words = ShellWords.split(line) else { return .failure(.unclosedQuote) }
        guard let first = words.first else { return .failure(.empty) }
        if words.count == 1, isWebAddress(first) {
            return .servers([
                ParsedServer(
                    name: guessName(url: first), kind: .http, command: "", args: [], url: first, env: [], headers: [])
            ])
        }
        // `claude mcp add …` and `codex mcp add …`: the command that documentation gives to register a server.
        if words.count > 3, ["claude", "codex"].contains(first), words[1] == "mcp", words[2] == "add" {
            return registration(Array(words.dropFirst(3)))
        }
        // Leading `KEY=value` words (and `env`) are the program's environment.
        var env: [ParsedPair] = []
        if words.first == "env" { words.removeFirst() }
        while let word = words.first, let pair = assignment(word) {
            env.append(classify(key: pair.0, value: pair.1, header: false))
            words.removeFirst()
        }
        guard let program = words.first else { return .failure(.notACommand(first)) }
        let base = program.split(separator: "/").last.map(String.init) ?? program
        guard launchers.contains(program) || launchers.contains(base) || program.contains("/") || program.hasPrefix(".")
        else { return .failure(.notACommand(program)) }
        let args = Array(words.dropFirst())
        env += dockerVariables(command: base, args: args, existing: env)
        return .servers([
            ParsedServer(
                name: guessName(command: program, args: args), kind: .stdio, command: program, args: args, url: "",
                env: env, headers: [])
        ])
    }

    private static func isWebAddress(_ word: String) -> Bool {
        let lower = word.lowercased()
        return (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && !word.contains(" ")
    }

    private static func assignment(_ word: String) -> (String, String)? {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return nil }
        let key = String(word[..<eq])
        guard key.unicodeScalars.allSatisfy({ $0 == "_" || (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) }),
            !(48...57).contains(key.unicodeScalars.first?.value ?? 0)
        else { return nil }
        return (key, String(word[word.index(after: eq)...]))
    }

    /// `docker run -e NAME image`: NAME is passed from the environment, so it is a variable to fill in.
    private static func dockerVariables(command: String, args: [String], existing: [ParsedPair]) -> [ParsedPair] {
        guard ["docker", "podman"].contains(command) else { return [] }
        var found: [ParsedPair] = []
        var index = 0
        while index < args.count {
            if ["-e", "--env"].contains(args[index]), index + 1 < args.count {
                let name = args[index + 1]
                if !name.contains("="), assignment(name + "=") != nil,
                    !(existing + found).contains(where: { $0.key == name })
                {
                    found.append(classify(key: name, value: "", header: false))
                }
                index += 1
            }
            index += 1
        }
        return found
    }

    /// The words after `claude mcp add` or `codex mcp add`: flags, then a name, then the address or `-- command`.
    private static func registration(_ words: [String]) -> ConfigParseResult {
        var env: [ParsedPair] = []
        var headers: [ParsedPair] = []
        var positional: [String] = []
        var command: [String] = []
        var url: String?
        var type: String?
        var index = 0
        while index < words.count {
            let word = words[index]
            func value() -> String? {
                index += 1
                return index < words.count ? words[index] : nil
            }
            switch word {
            case "--":
                command = Array(words[(index + 1)...])
                index = words.count
                continue
            case "--transport", "-t":
                type = value()
            case "--scope", "-s":
                _ = value()
            case "--url":
                url = value()
            case "--env", "-e":
                // Variadic in Claude's CLI: `-e A=1 B=2`.
                while index + 1 < words.count, let pair = assignment(words[index + 1]) {
                    env.append(classify(key: pair.0, value: pair.1, header: false))
                    index += 1
                }
            case "--header", "-H":
                if let text = value(), let colon = text.firstIndex(of: ":") {
                    let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
                    headers.append(classify(key: key, value: String(text[text.index(after: colon)...]), header: true))
                }
            default:
                positional.append(word)
            }
            index += 1
        }
        let name = positional.first
        if command.isEmpty, positional.count > 1 {
            let rest = Array(positional.dropFirst())
            if url == nil, isWebAddress(rest[0]) { url = rest[0] } else { command = rest }
        }
        if let url, command.isEmpty, type != "stdio" {
            return .servers([
                ParsedServer(
                    name: name ?? guessName(url: url), kind: .http, command: "", args: [], url: url, env: [],
                    headers: headers)
            ])
        }
        guard let program = command.first else { return .failure(.noServers) }
        let args = Array(command.dropFirst())
        let base = program.split(separator: "/").last.map(String.init) ?? program
        env += dockerVariables(command: base, args: args, existing: env)
        return .servers([
            ParsedServer(
                name: name ?? guessName(command: program, args: args), kind: .stdio, command: program, args: args,
                url: "", env: env, headers: [])
        ])
    }

    // MARK: - names

    /// A short name from the package or image a command starts: `@scope/server-github` gives `github`.
    static func guessName(command: String, args: [String]) -> String? {
        let base = command.split(separator: "/").last.map(String.init) ?? command
        var candidate: String?
        if ["npx", "bunx", "pnpm", "yarn", "uvx", "pipx", "uv"].contains(base) {
            candidate = args.first { !$0.hasPrefix("-") && $0 != "dlx" && $0 != "run" && $0 != "tool" }
        } else if ["docker", "podman"].contains(base) {
            // The image is the first word after `run` that is not a flag or the value of one.
            var skip = false
            var seenRun = false
            for word in args {
                if !seenRun { seenRun = word == "run"; continue }
                if skip { skip = false; continue }
                if ["-e", "--env", "-v", "--volume", "--name", "-p", "--publish", "-w", "--workdir", "--network", "--mount"].contains(word) {
                    skip = true
                    continue
                }
                if word.hasPrefix("-") { continue }
                candidate = word
                break
            }
        }
        guard var name = candidate else { return nil }
        if let at = name.dropFirst().firstIndex(of: "@") { name = String(name[..<at]) }
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        name = name.split(separator: "/").last.map(String.init) ?? name
        return cleaned(name)
    }

    /// A short name from a host: `mcp.linear.app` gives `linear`.
    static func guessName(url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        let generic: Set<String> = ["mcp", "api", "www", "backend", "app", "server", "com", "net", "org", "io", "dev", "ai", "app", "co", "ru"]
        let labels = host.split(separator: ".").map(String.init).filter { !generic.contains($0) }
        return labels.first.flatMap(cleaned)
    }

    private static func cleaned(_ raw: String) -> String? {
        var name = raw.lowercased()
        for prefix in ["mcp-server-", "server-", "mcp-", "mcp_server_", "mcp_"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        for suffix in ["-mcp-server", "-mcp", "-server", "_mcp", ".git"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? nil : name
    }
}

/// The technical name of an integration, made from the title the owner types.
enum IntegrationSlug {
    /// Up to 40 characters of `a-z 0-9 _ -`. Letters of other alphabets are written in Latin (`Мой сервер` becomes
    /// `moi-server`), anything else turns into `-`. A taken slug gets `-2`, `-3`… So `GitHub` on a server that has
    /// `github` gives `github-2`.
    static func make(from title: String, taken: Set<String>) -> String {
        let base = base(of: title)
        if !taken.contains(base) { return base }
        var number = 2
        while true {
            let suffix = "-\(number)"
            let candidate = String(base.prefix(IntegrationDraft.nameLimit - suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + suffix
            if !taken.contains(candidate) { return candidate }
            number += 1
        }
    }

    static func base(of title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        var result = ""
        for scalar in latin.lowercased().unicodeScalars {
            let ok = (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar == "_"
            if ok {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        result = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(IntegrationDraft.nameLimit))
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty { return "mcp" }
        if result == "bandito" { return "bandito-mcp" }
        return result
    }
}
