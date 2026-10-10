import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// What the owner pastes into "Своя интеграция": every format, quotes, empty text, rubbish, several servers, and the
/// placeholders (`${VAR}`) that stand for a secret. All values here are made up.
@Suite struct MCPConfigParserTests {
    private func one(_ text: String) -> ParsedServer? {
        if case .servers(let list) = MCPConfigParser.parse(text), list.count == 1 { return list[0] }
        return nil
    }

    // MARK: - Claude Desktop / Cursor config

    @Test func readsAClaudeDesktopProgramServer() {
        let text = """
            {
              "mcpServers": {
                "github": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-github"],
                  "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "<YOUR_TOKEN>" }
                }
              }
            }
            """
        let server = one(text)
        #expect(server?.name == "github")
        #expect(server?.kind == .stdio)
        #expect(server?.command == "npx")
        #expect(server?.args == ["-y", "@modelcontextprotocol/server-github"])
        #expect(server?.env == [ParsedPair(key: "GITHUB_PERSONAL_ACCESS_TOKEN", value: "", isSecret: true, template: nil)])
        #expect(server?.commandLine == "npx -y @modelcontextprotocol/server-github")
    }

    @Test func readsAWebServerWithHeaders() {
        let text = #"""
            {"mcpServers": {"linear": {"url": "https://mcp.example.test/mcp", "headers": {"Authorization": "Bearer ${LINEAR_KEY}", "X-Region": "eu"}}}}
            """#
        let server = one(text)
        #expect(server?.kind == .http)
        #expect(server?.url == "https://mcp.example.test/mcp")
        #expect(server?.headers.count == 2)
        #expect(server?.headers[0] == ParsedPair(key: "Authorization", value: "", isSecret: true, template: "Bearer {secret}"))
        #expect(server?.headers[1] == ParsedPair(key: "X-Region", value: "eu", isSecret: false, template: nil))
    }

    @Test func severalServersAreAllReturnedInNameOrder() {
        let text = #"{"mcpServers": {"b-tool": {"command": "uvx", "args": ["b"]}, "a-tool": {"url": "https://a.example.test/mcp"}}}"#
        guard case .servers(let list) = MCPConfigParser.parse(text) else {
            Issue.record("expected servers")
            return
        }
        #expect(list.map(\.name) == ["a-tool", "b-tool"])
        #expect(list.map(\.kind) == [.http, .stdio])
    }

    @Test func otherContainersAreUnderstood() {
        let vscode = #"{"servers": {"fs": {"type": "stdio", "command": "npx", "args": ["-y", "pkg"]}}}"#
        #expect(one(vscode)?.command == "npx")
        let settings = #"{"mcp": {"servers": {"w": {"type": "http", "url": "https://w.example.test/mcp"}}}}"#
        #expect(one(settings)?.url == "https://w.example.test/mcp")
        let zed = #"{"context_servers": {"z": {"command": {"path": "npx", "args": ["-y", "z"], "env": {"K": "v"}}}}}"#
        let server = one(zed)
        #expect(server?.command == "npx")
        #expect(server?.args == ["-y", "z"])
        #expect(server?.env.first?.key == "K")
    }

    // MARK: - one server's object

    @Test func readsOneServersObject() {
        let program = one(#"{"command": "uvx", "args": ["mcp-server-fetch"]}"#)
        #expect(program?.kind == .stdio)
        #expect(program?.name == "fetch")
        let web = one(#"{"url": "https://mcp.linear.example.test/mcp"}"#)
        #expect(web?.kind == .http)
        #expect(web?.name == "linear")
    }

    @Test func aFragmentWithANameAndATrailingCommaIsRead() {
        let server = one(#""github": {"command": "npx", "args": ["-y", "x"]}"#)
        #expect(server?.name == "github")
        let trailing = one(#"{"command": "npx", "args": ["-y", "x",],}"#)
        #expect(trailing?.args == ["-y", "x"])
    }

    @Test func aCommandWrittenInOneStringIsSplit() {
        let server = one(#"{"command": "npx -y @scope/pkg --flag"}"#)
        #expect(server?.command == "npx")
        #expect(server?.args == ["-y", "@scope/pkg", "--flag"])
    }

    // MARK: - command lines

    @Test func readsNpxUvxAndDockerLines() {
        let npx = one("npx -y @modelcontextprotocol/server-filesystem /Users/me/work")
        #expect(npx?.command == "npx")
        #expect(npx?.args == ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/work"])
        #expect(npx?.name == "filesystem")
        let uvx = one("uvx mcp-server-fetch")
        #expect(uvx?.command == "uvx")
        #expect(uvx?.name == "fetch")
        let docker = one("docker run -i --rm -e API_TOKEN -e MODE=fast ghcr.io/example/example-mcp-server:1.2")
        #expect(docker?.command == "docker")
        #expect(docker?.name == "example")
        // `-e NAME` takes the value from the environment: it becomes a secret to fill in. `-e MODE=fast` has its value.
        #expect(docker?.env == [ParsedPair(key: "API_TOKEN", value: "", isSecret: true, template: nil)])
    }

    @Test func quotesInACommandKeepTheirSpaces() {
        let server = one(#"npx -y pkg --root "/Users/me/My Files" --name 'it''s' --empty "" a\ b"#)
        #expect(server?.args == ["-y", "pkg", "--root", "/Users/me/My Files", "--name", "its", "--empty", "", "a b"])
        // The line the sheet shows round-trips to the same words.
        #expect(ShellWords.split(server?.commandLine ?? "") == ["npx", "-y", "pkg", "--root", "/Users/me/My Files", "--name", "its", "--empty", "", "a b"])
    }

    @Test func aPromptAndLineContinuationsAreIgnored() {
        let server = one("$ npx -y \\\n  @scope/pkg \\\n  --flag")
        #expect(server?.args == ["-y", "@scope/pkg", "--flag"])
    }

    @Test func leadingAssignmentsAreTheEnvironment() {
        let server = one("API_KEY=abc123 DEBUG=1 npx -y pkg")
        #expect(server?.command == "npx")
        #expect(server?.env.map(\.key) == ["API_KEY", "DEBUG"])
        #expect(server?.env[0] == ParsedPair(key: "API_KEY", value: "abc123", isSecret: true, template: nil))
        #expect(server?.env[1] == ParsedPair(key: "DEBUG", value: "1", isSecret: false, template: nil))
    }

    @Test func claudeMcpAddIsUnderstood() {
        let program = one("claude mcp add --transport stdio -e TOKEN=abc github -- npx -y @scope/server-github")
        #expect(program?.name == "github")
        #expect(program?.command == "npx")
        #expect(program?.args == ["-y", "@scope/server-github"])
        #expect(program?.env == [ParsedPair(key: "TOKEN", value: "abc", isSecret: true, template: nil)])
        let web = one(#"claude mcp add --transport http linear https://mcp.example.test/mcp --header "Authorization: Bearer ${KEY}""#)
        #expect(web?.name == "linear")
        #expect(web?.url == "https://mcp.example.test/mcp")
        #expect(web?.headers == [ParsedPair(key: "Authorization", value: "", isSecret: true, template: "Bearer {secret}")])
    }

    // MARK: - URL

    @Test func aBareUrlIsAWebServer() {
        let server = one("  https://mcp.example.test/mcp  ")
        #expect(server?.kind == .http)
        #expect(server?.url == "https://mcp.example.test/mcp")
        #expect(server?.name == "example")
        #expect(one("http://localhost:8080/mcp")?.kind == .http)
    }

    // MARK: - nothing, rubbish

    @Test func emptyAndBlankTextIsEmpty() {
        #expect(MCPConfigParser.parse("") == .failure(.empty))
        #expect(MCPConfigParser.parse(" \n\t ") == .failure(.empty))
    }

    @Test func rubbishIsRefusedWithAReason() {
        #expect(MCPConfigParser.parse("hello world") == .failure(.notACommand("hello")))
        #expect(MCPConfigParser.parse("{not json") == .failure(.invalidJSON))
        #expect(MCPConfigParser.parse(#"{"name": "x"}"#) == .failure(.noServers))
        #expect(MCPConfigParser.parse(#"{"mcpServers": {}}"#) == .failure(.noServers))
        #expect(MCPConfigParser.parse(#"{"mcpServers": {"x": {"note": 1}}}"#) == .failure(.noServers))
        #expect(MCPConfigParser.parse(#"npx -y "pkg"#) == .failure(.unclosedQuote))
        #expect(MCPConfigParser.parse("[1, 2]") == .failure(.invalidJSON))
    }

    // MARK: - values

    @Test func placeholdersAreSecretsToFillIn() {
        for placeholder in ["${GITHUB_TOKEN}", "$GITHUB_TOKEN", "<your-token>", "{{token}}", "YOUR_API_KEY", "PASTE_KEY_HERE", ""] {
            let pair = MCPConfigParser.classify(key: "ANY_NAME", value: placeholder, header: false)
            #expect(pair.isSecret, "\(placeholder)")
            #expect(pair.value.isEmpty, "\(placeholder)")
            #expect(pair.template == nil, "\(placeholder)")
        }
    }

    @Test func aPlaceholderInsideAValueBecomesATemplate() {
        let pair = MCPConfigParser.classify(key: "Authorization", value: "Bearer ${TOKEN}", header: true)
        #expect(pair == ParsedPair(key: "Authorization", value: "", isSecret: true, template: "Bearer {secret}"))
        let url = MCPConfigParser.classify(key: "X", value: "prefix-${A}-suffix", header: false)
        #expect(url.template == "prefix-{secret}-suffix")
    }

    @Test func aValueUnderASecretLookingKeyIsASecretWithItsValue() {
        let token = MCPConfigParser.classify(key: "API_TOKEN", value: "abc123", header: false)
        #expect(token == ParsedPair(key: "API_TOKEN", value: "abc123", isSecret: true, template: nil))
        let bearer = MCPConfigParser.classify(key: "Authorization", value: "Bearer abc123", header: true)
        #expect(bearer == ParsedPair(key: "Authorization", value: "abc123", isSecret: true, template: "Bearer {secret}"))
        let plain = MCPConfigParser.classify(key: "REGION", value: "eu-west", header: false)
        #expect(plain == ParsedPair(key: "REGION", value: "eu-west", isSecret: false, template: nil))
    }

    @Test func envWithAVariableReferenceInAConfigIsASecret() {
        let text = #"{"mcpServers": {"x": {"command": "npx", "args": ["x"], "env": {"KEY": "${MY_KEY}", "MODE": "fast"}}}}"#
        let server = one(text)
        #expect(server?.env == [
            ParsedPair(key: "KEY", value: "", isSecret: true, template: nil),
            ParsedPair(key: "MODE", value: "fast", isSecret: false, template: nil),
        ])
    }

    // MARK: - names

    @Test func namesAreGuessedFromPackagesImagesAndHosts() {
        #expect(MCPConfigParser.guessName(command: "npx", args: ["-y", "@scope/server-github@1.0.0"]) == "github")
        #expect(MCPConfigParser.guessName(command: "npx", args: ["-y", "some-mcp"]) == "some")
        #expect(MCPConfigParser.guessName(command: "uvx", args: ["mcp-server-time"]) == "time")
        #expect(MCPConfigParser.guessName(command: "docker", args: ["run", "-i", "--rm", "-e", "X", "ghcr.io/o/thing:1"]) == "thing")
        #expect(MCPConfigParser.guessName(command: "/usr/bin/tool", args: []) == nil)
        #expect(MCPConfigParser.guessName(url: "https://mcp.linear.example.test/mcp") == "linear")
        #expect(MCPConfigParser.guessName(url: "not a url") == nil)
    }
}

@Suite struct ShellWordsTests {
    @Test func splitsLikeAShell() {
        #expect(ShellWords.split("a b  c") == ["a", "b", "c"])
        #expect(ShellWords.split("  ") == [])
        #expect(ShellWords.split(#"a "b c" 'd e' f\ g"#) == ["a", "b c", "d e", "f g"])
        #expect(ShellWords.split(#""a\"b" 'a\b'"#) == [#"a"b"#, #"a\b"#])
        #expect(ShellWords.split("a\nb") == ["a", "b"])
        #expect(ShellWords.split("x\"\"y") == ["xy"])
    }

    @Test func anOpenQuoteOrALoneBackslashIsNil() {
        #expect(ShellWords.split(#"a "b"#) == nil)
        #expect(ShellWords.split("a 'b") == nil)
        #expect(ShellWords.split("a \\") == nil)
        #expect(ShellWords.lenientSplit(#"a "b c"#) == ["a", "\"b", "c"])
    }

    @Test func joinAndSplitRoundTrip() {
        let words = ["npx", "-y", "has space", "it's", "", "$HOME", "a\"b", "plain-1.2_x/y:z"]
        #expect(ShellWords.split(ShellWords.join(words)) == words)
        #expect(ShellWords.join(["a", "b c"]) == "a 'b c'")
    }
}

@Suite struct IntegrationSlugTests {
    @Test func titlesBecomeTechnicalNames() {
        #expect(IntegrationSlug.base(of: "GitHub") == "github")
        #expect(IntegrationSlug.base(of: "My Cool_Server!") == "my-cool_server")
        #expect(IntegrationSlug.base(of: "  --x--  ") == "x")
        #expect(IntegrationSlug.base(of: "Мой сервер").hasSuffix("-server"))
        #expect(IntegrationDraft.isValidName(IntegrationSlug.base(of: "Мой сервер 日本")))
        #expect(IntegrationSlug.base(of: "Café") == "cafe")
        #expect(IntegrationSlug.base(of: "!!!") == "mcp")
        #expect(IntegrationSlug.base(of: "") == "mcp")
        #expect(IntegrationSlug.base(of: "bandito") == "bandito-mcp")
        #expect(IntegrationSlug.base(of: String(repeating: "a", count: 80)).count == 40)
    }

    @Test func aTakenNameGetsANumber() {
        #expect(IntegrationSlug.make(from: "GitHub", taken: []) == "github")
        #expect(IntegrationSlug.make(from: "GitHub", taken: ["github"]) == "github-2")
        #expect(IntegrationSlug.make(from: "GitHub", taken: ["github", "github-2"]) == "github-3")
        let long = String(repeating: "a", count: 40)
        let made = IntegrationSlug.make(from: long, taken: [long])
        #expect(made.count <= 40 && made.hasSuffix("-2"))
        #expect(IntegrationDraft.isValidName(made))
    }
}

@Suite struct IntegrationPasteTests {
    @Test func aParsedProgramFillsTheDraft() {
        var draft = IntegrationDraft.custom(kind: .http)
        draft.url = "https://stale.example.test"
        draft.apply(
            ParsedServer(
                name: "Brave", kind: .stdio, command: "npx", args: ["-y", "@brave/x", "--root", "My Files"], url: "",
                env: [ParsedPair(key: "BRAVE_API_KEY", value: "", isSecret: true, template: nil)], headers: []),
            existingNames: ["brave"])
        #expect(draft.kind == .stdio)
        #expect(draft.command == "npx")
        #expect(draft.args == ["-y", "@brave/x", "--root", "My Files"])
        #expect(draft.url.isEmpty)
        #expect(draft.title == "Brave")
        #expect(draft.name == "brave-2")
        #expect(draft.env.count == 1 && draft.env[0].isSecret)
        #expect(draft.problem(existingNames: ["brave"]) == .secretMissing("BRAVE_API_KEY"))
    }

    @Test func aParsedWebServerFillsTheDraftAndKeepsATypedTitle() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.setTitle("Mine", existingNames: [])
        draft.apply(
            ParsedServer(
                name: "linear", kind: .http, command: "", args: [], url: "https://x.example.test/mcp", env: [],
                headers: [ParsedPair(key: "Authorization", value: "", isSecret: true, template: "Bearer {secret}")]),
            existingNames: [])
        #expect(draft.kind == .http)
        #expect(draft.url == "https://x.example.test/mcp")
        #expect(draft.commandLine.isEmpty)
        #expect(draft.title == "Mine")
        #expect(draft.name == "mine")
        #expect(draft.headers[0].template == "Bearer {secret}")
    }

    @Test func theNameFollowsTheTitleUntilTheOwnerEditsIt() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.setTitle("GitHub", existingNames: ["github"])
        #expect(draft.name == "github-2")
        draft.setTitle("Notes", existingNames: ["github"])
        #expect(draft.name == "notes")
        draft.setName("my-notes")
        draft.setTitle("Other", existingNames: [])
        #expect(draft.name == "my-notes")
        draft.setTitle("", existingNames: [])
        #expect(draft.name == "my-notes")
        var empty = IntegrationDraft.custom(kind: .stdio)
        empty.setTitle("  ", existingNames: [])
        #expect(empty.name.isEmpty)
    }

    @Test func theCommandLineIsOneFieldWithQuotes() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.setTitle("x", existingNames: [])
        draft.commandLine = #"npx -y pkg "/My Files""#
        #expect(draft.command == "npx")
        #expect(draft.args == ["-y", "pkg", "/My Files"])
        #expect(draft.build().create?.args == ["-y", "pkg", "/My Files"])
        draft.commandLine = #"npx "open"#
        #expect(draft.problem(existingNames: []) == .quoteUnclosed)
        draft.commandLine = "   "
        #expect(draft.problem(existingNames: []) == .commandEmpty)
    }

    @Test func aTrialIsAddedTurnedOffAndAddEnablesIt() {
        var draft = IntegrationDraft.custom(kind: .stdio)
        draft.setTitle("x", existingNames: [])
        draft.commandLine = "npx pkg"
        #expect(draft.build(enabled: false).create?.enabled == false)
        #expect(draft.build().create?.enabled == true)
        draft.markSaved(id: "i1")
        #expect(draft.build().patch?.enabled == nil)
        #expect(draft.build(enabled: true).patch?.enabled == true)
    }
}
