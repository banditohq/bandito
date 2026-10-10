import Foundation
import Testing

@testable import BanditoKit

/// Reading the files of Claude Code and Codex: front matter, subagents, tools, and the scan with its limits.
@Suite struct ClaudeImportTests {
    // MARK: front matter

    @Test func aPlainBlockGivesItsKeysAndTheBody() {
        let m = ImportFrontMatter.parse("---\nname: reviewer\ndescription: Reviews code\n---\nYou review.\nBe brief.\n")
        #expect(m.keys == ["name", "description"])
        #expect(m.text("name") == "reviewer")
        #expect(m.body == "You review.\nBe brief.\n")
        #expect(m.raw == "name: reviewer\ndescription: Reviews code")
    }

    @Test func quotesAreTakenOffAndTheirEscapesRead() {
        let m = ImportFrontMatter.parse("---\na: \"say \\\"hi\\\"\"\nb: 'it''s'\nc: \"x: y\"\n---\nbody")
        #expect(m.text("a") == "say \"hi\"")
        #expect(m.text("b") == "it's")
        #expect(m.text("c") == "x: y")
    }

    @Test func toolsMayBeACommaTextAnInlineListOrAYAMLList() {
        let comma = ImportFrontMatter.parse("---\ntools: Read, Grep, Bash(git:*)\n---\nx")
        #expect(comma["tools"]?.asList == ["Read", "Grep", "Bash(git:*)"])
        let inline = ImportFrontMatter.parse("---\ntools: [Read, \"Edit\", 'Write']\n---\nx")
        #expect(inline["tools"]?.asList == ["Read", "Edit", "Write"])
        let block = ImportFrontMatter.parse("---\ntools:\n  - Read\n  - Edit\n  - \"Bash\"\nmodel: opus\n---\nx")
        #expect(block["tools"]?.asList == ["Read", "Edit", "Bash"])
        #expect(block.text("model") == "opus", "the key after a list is still read")
    }

    @Test func blockTextAndFoldedTextAreRead() {
        let m = ImportFrontMatter.parse("---\nliteral: |\n  one\n  two\nfolded: >\n  a\n  b\nplain: start\n  more\n---\nx")
        #expect(m.text("literal") == "one\ntwo")
        #expect(m.text("folded") == "a b")
        #expect(m.text("plain") == "start more")
    }

    @Test func emptyValuesCommentsAndUnclosedBlocksAreLeftAlone() {
        let m = ImportFrontMatter.parse("---\n# a comment\ntools:\nname: x\n---\nbody")
        #expect(m["tools"] == nil && m.text("name") == "x")
        let unclosed = ImportFrontMatter.parse("---\nname: x\nno end")
        #expect(unclosed.fields.isEmpty && unclosed.body.hasPrefix("---"))
        let none = ImportFrontMatter.parse("just text")
        #expect(none.body == "just text" && none.keys.isEmpty)
        let crlf = ImportFrontMatter.parse("---\r\nname: x\r\n---\r\nbody")
        #expect(crlf.text("name") == "x" && crlf.body == "body")
    }

    // MARK: subagents

    @Test func aSubagentBecomesAnAgent() {
        let file = """
            ---
            name: code-reviewer
            description: Expert code reviewer. Use proactively after any change to the code.
            tools: Read, Grep, Glob, Bash
            model: sonnet
            ---
            You are a senior reviewer.
            """
        let agent = ImportAgentParser.parse(stem: "file", text: file)
        #expect(agent.name == "code-reviewer")
        #expect(agent.role.hasPrefix("Expert code reviewer") && agent.role.count <= ImportAgentParser.maxRoleLength)
        #expect(agent.instructions == "You are a senior reviewer.")
        #expect(agent.tools == ["Read", "Grep", "Glob", "Bash"])
        #expect(agent.model == "sonnet")
        #expect(agent.capabilities == ["terminal"])
    }

    @Test func theNameFallsBackToTheFileAndIsMadeValid() {
        #expect(ImportAgentParser.parse(stem: "my-helper", text: "---\ndescription: d\n---\nbody").name == "my-helper")
        #expect(ImportAgentParser.agentName("Code Review / PR!") == "Code Review - PR")
        #expect(ImportAgentParser.agentName(String(repeating: "a", count: 50)).count == 32)
        #expect(ImportAgentParser.agentName("!!!", fallback: "x") == "x")
        #expect(ImportAgentParser.agentName("!!!", fallback: "!!!") == "agent")
    }

    @Test func theRoleIsTheFirstLineCutShort() {
        #expect(ImportAgentParser.role(from: "Short one") == "Short one")
        #expect(ImportAgentParser.role(from: "First line\nSecond line") == "First line")
        let long = ImportAgentParser.role(
            from: "Expert code review specialist that checks quality, security and maintainability of every change")
        #expect(long.count <= ImportAgentParser.maxRoleLength)
        #expect(long.hasSuffix("…"))
        #expect(!long.contains("maintainability"))
        let oneWord = ImportAgentParser.role(from: String(repeating: "x", count: 100))
        #expect(oneWord.count == ImportAgentParser.maxRoleLength && oneWord.hasSuffix("…"))
        #expect(ImportAgentParser.role(from: "") == "")
    }

    @Test func inheritAndNoToolsMeanNoModelAndEverything() {
        let agent = ImportAgentParser.parse(stem: "a", text: "---\nmodel: inherit\n---\nbody")
        #expect(agent.model == nil && agent.tools == nil && agent.capabilities == nil)
        let empty = ImportAgentParser.parse(stem: "a", text: "---\ntools:\n---\nbody")
        #expect(empty.tools == nil && empty.capabilities == nil)
    }

    // MARK: tools to capabilities

    @Test func theToolsOfClaudeCodeStandForCapabilities() {
        #expect(ImportCapabilities.wire(for: ["Bash"]) == ["terminal"])
        #expect(ImportCapabilities.wire(for: ["Edit"]) == ["files"])
        #expect(ImportCapabilities.wire(for: ["Write", "MultiEdit", "NotebookEdit"]) == ["files"])
        #expect(ImportCapabilities.wire(for: ["WebFetch"]) == ["browser"])
        #expect(ImportCapabilities.wire(for: ["WebSearch"]) == ["browser"])
        #expect(ImportCapabilities.wire(for: ["WebSearch", "Bash", "Edit"]) == ["terminal", "files", "browser"])
        // Arguments of a tool are not part of its name.
        #expect(ImportCapabilities.wire(for: ["Bash(npm test:*)"]) == ["terminal"])
        // Tools that switch nothing in Bandito leave an empty list; no list leaves everything on.
        #expect(ImportCapabilities.wire(for: ["Read", "Grep", "Glob", "TodoWrite", "mcp__x__y"]) == [])
        #expect(ImportCapabilities.wire(for: nil) == nil)
        #expect(ImportCapabilities.wire(for: []) == nil)
    }

    @Test func aModelIsKeptOnlyWhenTheRuntimeOffersIt() {
        let list = RuntimeModelList(
            runtime: .codex, models: [RuntimeModel(id: "gpt-5.5", name: "GPT"), RuntimeModel(id: "o3", name: "o3")], fetchedAt: 1)
        let lists = ["codex": list]
        #expect(ImportAgentParser.model("GPT-5.5", runtime: .codex, lists: lists) == "gpt-5.5")
        #expect(ImportAgentParser.model("opus", runtime: .codex, lists: lists) == nil)
        #expect(ImportAgentParser.model("opus", runtime: .claude, lists: [:]) == "opus")
        #expect(ImportAgentParser.model("claude-9", runtime: .claude, lists: [:]) == nil)
        #expect(ImportAgentParser.model(nil, runtime: .claude, lists: [:]) == nil)
        #expect(ImportAgentParser.model("  ", runtime: .claude, lists: [:]) == nil)
    }

    // MARK: secrets

    @Test func plainKeysAndPasswordsAreNoticed() {
        #expect(ImportSecretCheck.looksLikeSecret("-----BEGIN OPENSSH PRIVATE KEY-----\nabc"))
        #expect(ImportSecretCheck.looksLikeSecret("use sk-abcdefghijklmnopqrstuvwx for it"))
        #expect(ImportSecretCheck.looksLikeSecret("export API_KEY=\"abcdef1234567890abcd\""))
        #expect(ImportSecretCheck.looksLikeSecret("token: ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!ImportSecretCheck.looksLikeSecret("Read the token from the environment, never write a password down."))
        #expect(!ImportSecretCheck.looksLikeSecret("api_key: short"))
    }

    @Test func aBigFileOfLettersIsCheckedQuickly() {
        let big = String(repeating: "a", count: 300_000) + String(repeating: "key", count: 20_000)
        let started = Date()
        #expect(!ImportSecretCheck.looksLikeSecret(big))
        #expect(Date().timeIntervalSince(started) < 5, "a pattern that backtracks without limit would take minutes")
    }

    @Test func variableAssignmentsAndKeyFormatsAreNoticedWithoutWordBoundaries() {
        let secrets: [String] = [
            "DB_PASSWORD=hunter2hunter2", "MY_SECRET_X=abcdefgh1234", "STRIPE_TOKEN=abcd1234efgh", "OPENAI_API_KEY=abcdef123456",
            "export GITHUB_TOKEN=\"ghp_x1234567890abcdef\"", "client_secret: 'zzzzzzzzzzzz'", "xoxb-123456789012-abcdefghijkl",
            "AKIAIOSFODNN7EXAMPLE", "prefix_sk-abcdefghijklmnopqrstuv", "-----BEGIN RSA PRIVATE KEY-----",
        ]
        let more: [String] = [
            "-----BEGIN PRIVATE KEY-----", "xoxp-1234567890-abcdefgh", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345",
            "passwd = longvalue12345",
        ]
        for text in secrets + more {
            #expect(ImportSecretCheck.looksLikeSecret(text), Comment(rawValue: text))
        }
        let harmless: [String] = [
            "API_KEY=$API_KEY", "TOKEN=<your token here>", "SECRET={{secret}}", "KEY=short",
            "Set the password in the settings screen.", "keyboard shortcuts: use the arrows to move around",
        ]
        for text in harmless {
            #expect(!ImportSecretCheck.looksLikeSecret(text), Comment(rawValue: text))
        }
    }

    // MARK: the scan

    /// A folder tree for a test; removed with it.
    private final class Tree {
        let root: URL
        init() {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("bandito-import-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func put(_ path: String, _ text: String) {
            put(path, Data(text.utf8))
        }
        func put(_ path: String, _ data: Data) {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        func link(_ path: String, to target: String) {
            let url = root.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }

    @Test func theUsersFoldersAreRead() {
        let t = Tree()
        t.put(".claude/agents/reviewer.md", "---\nname: reviewer\ndescription: Reviews\ntools: Bash\n---\nReview it.")
        t.put(".claude/skills/pdf/SKILL.md", "---\nname: pdf\ndescription: Make PDFs\n---\nSteps")
        t.put(".claude/skills/pdf/scripts/run.sh", "echo hi")
        t.put(".claude/commands/git/commit.md", "---\ndescription: Commit\nargument-hint: [msg]\n---\nDo it $ARGUMENTS")
        t.put(".claude/commands/top.md", "Top")
        t.put(".codex/prompts/plan.md", "---\ndescription: Plan\n---\nPlan it")
        let scan = ImportScanner.scan(home: t.root)
        #expect(scan.skipped.isEmpty)
        #expect(scan.items(of: .agent).map(\.name) == ["reviewer"])
        #expect(scan.items(of: .skill).map(\.name) == ["pdf"])
        #expect(scan.items(of: .command).map(\.name).sorted() == ["git:commit", "plan", "top"])
        let skill = scan.items(of: .skill)[0]
        guard case .command(let payload) = skill.payload else {
            Issue.record("no payload")
            return
        }
        #expect(payload.files.map(\.path) == ["SKILL.md", "scripts/run.sh"])
        let agent = scan.items(of: .agent)[0]
        #expect(agent.path == "~/.claude/agents/reviewer.md")
        #expect(agent.summary == "Reviews")
        #expect(agent.frontMatter.contains("name: reviewer"))
        #expect(agent.bodyPreview == "Review it.")
        let prompt = scan.items(of: .command).first { $0.name == "plan" }
        #expect(prompt?.origin == .codexPrompts)
        #expect(prompt?.path == "~/.codex/prompts/plan.md")
    }

    @Test func aProjectFolderAddsItsOwnAndItsAgentsFile() {
        let t = Tree()
        let project = t.root.appendingPathComponent("shop")
        t.put("shop/.claude/agents/helper.md", "---\ndescription: d\n---\nHelp.")
        t.put("shop/.claude/commands/deploy.md", "Deploy")
        t.put("shop/AGENTS.md", "# Rules\nUse tabs.")
        let scan = ImportScanner.scan(home: t.root.appendingPathComponent("nobody"), project: project)
        #expect(scan.items(of: .agent).map(\.name).sorted() == ["helper", "shop"])
        let instructions = scan.items(of: .agent).first { $0.name == "shop" }
        #expect(instructions?.origin == .projectInstructions("shop"))
        guard case .agent(let made)? = instructions?.payload else {
            Issue.record("no agent")
            return
        }
        #expect(made.instructions == "# Rules\nUse tabs.")
        #expect(made.role == "AGENTS.md" && made.tools == nil)
        #expect(scan.items(of: .command).first?.origin == .claudeProject("shop"))
    }

    @Test func bigAndBinaryFilesAreSkippedWithAReason() {
        let t = Tree()
        t.put(".claude/agents/big.md", String(repeating: "x", count: ImportScanner.maxFileBytes + 1))
        t.put(".claude/agents/edge.md", String(repeating: "x", count: ImportScanner.maxFileBytes))
        t.put(".claude/agents/bin.md", Data([0x41, 0x00, 0x42]))
        t.put(".claude/agents/latin.md", Data([0xFF, 0xFE, 0x41]))
        t.put(".claude/agents/empty.md", "---\nname: e\n---\n   \n")
        let scan = ImportScanner.scan(home: t.root)
        func reason(_ name: String) -> ImportSkipReason? { scan.skipped.first { $0.path.hasSuffix(name) }?.reason }
        #expect(reason("big.md") == .tooBig)
        #expect(reason("bin.md") == .notText)
        #expect(reason("latin.md") == .notText)
        #expect(reason("empty.md") == .empty)
        #expect(scan.items(of: .agent).map(\.name) == ["edge"], "a file of exactly 256 KiB is taken")
    }

    @Test func linksAreNeverFollowed() {
        let t = Tree()
        t.put("elsewhere/secret.md", "---\nname: s\n---\nbody")
        t.link(".claude/agents/linked.md", to: t.root.appendingPathComponent("elsewhere/secret.md").path)
        t.link(".claude/skills/linkdir", to: t.root.appendingPathComponent("elsewhere").path)
        t.put(".claude/skills/has/SKILL.md", "x")
        t.link(".claude/skills/has/inside.md", to: t.root.appendingPathComponent("elsewhere/secret.md").path)
        t.link(".claude/commands/cmd.md", to: t.root.appendingPathComponent("elsewhere/secret.md").path)
        let scan = ImportScanner.scan(home: t.root)
        #expect(scan.items.isEmpty)
        func reason(_ suffix: String) -> ImportSkipReason? { scan.skipped.first { $0.path.hasSuffix(suffix) }?.reason }
        #expect(reason("agents/linked.md") == .link)
        #expect(reason("skills/linkdir") == .link)
        #expect(reason("skills/has") == .link, "a skill that holds a link is not taken")
        #expect(reason("commands/cmd.md") == .link)
    }

    @Test func aSkillKeepsToTheDaemonsLimits() {
        let t = Tree()
        t.put(".claude/skills/many/SKILL.md", "x")
        for i in 0..<ImportScanner.maxSkillFiles { t.put(".claude/skills/many/f\(i).txt", "x") }
        t.put(".claude/skills/atlimit/SKILL.md", "x")
        for i in 0..<(ImportScanner.maxSkillFiles - 1) { t.put(".claude/skills/atlimit/f\(i).txt", "x") }
        t.put(".claude/skills/heavy/SKILL.md", "x")
        for i in 0..<9 { t.put(".claude/skills/heavy/part\(i).bin", Data(repeating: 65, count: 250_000)) }
        t.put(".claude/skills/bigfile/SKILL.md", "x")
        t.put(".claude/skills/bigfile/data.txt", String(repeating: "x", count: ImportScanner.maxFileBytes + 1))
        t.put(".claude/skills/nofile/readme.md", "x")
        t.put(".claude/skills/.hidden/SKILL.md", "x")
        let scan = ImportScanner.scan(home: t.root)
        func reason(_ suffix: String) -> ImportSkipReason? { scan.skipped.first { $0.path.hasSuffix(suffix) }?.reason }
        #expect(reason("skills/many") == .tooManyFiles)
        #expect(reason("skills/heavy") == .tooLarge)
        #expect(reason("skills/bigfile") == .tooBig)
        #expect(reason("skills/nofile") == .noSkillFile)
        #expect(scan.items(of: .skill).map(\.name) == ["atlimit"], "50 files is allowed")
        #expect(!scan.skipped.contains { $0.path.contains(".hidden") })
    }

    @Test func aSkillThatPointsAtPicturesIsTakenWithoutThemAndWithAWarning() {
        let t = Tree()
        t.put(".claude/skills/art/SKILL.md", "---\ndescription: d\n---\nUse the pictures in a.png")
        t.put(".claude/skills/art/notes.txt", "text stays")
        t.put(".claude/skills/art/a.png", Data([0x89, 0x50, 0x00, 0x47]))
        t.put(".claude/skills/art/b.png", Data([0x00, 0x01]))
        t.put(".claude/skills/binmain/SKILL.md", Data([0x00, 0x01]))
        let scan = ImportScanner.scan(home: t.root)
        let art = scan.items(of: .skill).first
        #expect(art?.warnings == [.leftOutFiles(2)])
        guard case .command(let made)? = art?.payload else {
            Issue.record("no skill")
            return
        }
        #expect(made.files.map(\.path) == ["SKILL.md", "notes.txt"], "the files that are not text are not sent")
        #expect(scan.skipped.filter { $0.reason == .notText && $0.path.hasSuffix(".png") }.count == 2)
        #expect(scan.skipped.first { $0.path.hasSuffix("skills/binmain") }?.reason == .notText)
    }

    @Test func filesNamedLikeKeysAreNeverSentWhateverTheyHold() {
        let t = Tree()
        t.put(".claude/skills/deploy/SKILL.md", "---\ndescription: d\n---\nDeploy")
        t.put(".claude/skills/deploy/run.sh", "echo hi")
        let names: [String] = [
            "deploy.pem", "server.key", "id_rsa", "id_rsa.pub", "id_ed25519", "credentials.json", "cert.p12", "env.production",
        ]
        for name in names {
            t.put(".claude/skills/deploy/" + name, "harmless text")
        }
        let scan = ImportScanner.scan(home: t.root)
        guard case .command(let made)? = scan.items(of: .skill).first?.payload else {
            Issue.record("no skill")
            return
        }
        let sent: [String] = made.files.map(\.path)
        #expect(sent == ["SKILL.md", "run.sh"])
        let flagged = scan.skipped.filter { $0.reason == .sensitiveFile }
        let left: Set<String> = Set(flagged.map { String($0.path.split(separator: "/").last ?? "") })
        #expect(left == Set(names))
        #expect(scan.items(of: .skill).first?.warnings == [.leftOutFiles(8)])
    }

    @Test func theNamesOfKeyFilesAreRecognised() {
        let keys: [String] = [
            ".env", ".env.local", "x.pem", "x.KEY", "id_rsa", "id_rsa.pub", "id_ed25519", "id_ed25519.pub", "credentials",
            "credentials.json", "a.p12", "a.pfx", "store.jks",
        ]
        for name in keys {
            #expect(ImportSensitiveName.matches(name), Comment(rawValue: name))
        }
        let plain: [String] = [
            "SKILL.md", "run.sh", "keyboard.md", "monkey.txt", "environment.md", "credits.md", "notes.pem.txt", "idea.md",
        ]
        for name in plain {
            #expect(!ImportSensitiveName.matches(name), Comment(rawValue: name))
        }
    }

    @Test func aLinkAnywhereOnTheWayIsNotFollowed() {
        let t = Tree()
        t.put("real/.claude/agents/a.md", "---\nname: a\n---\nbody")
        t.put("real/.claude/commands/c.md", "x")
        // `.claude` itself is a link.
        t.link("home/.claude", to: t.root.appendingPathComponent("real/.claude").path)
        let scan = ImportScanner.scan(home: t.root.appendingPathComponent("home"))
        #expect(scan.items.isEmpty)
        #expect(scan.skipped.contains { $0.path.hasSuffix(".claude") && $0.reason == .link })
    }

    @Test func aLinkedFolderInTheMiddleOfThePathIsNotFollowed() {
        let t = Tree()
        t.put("elsewhere/agents/a.md", "---\nname: a\n---\nbody")
        t.put("home/.claude/commands/ok.md", "x")
        t.link("home/.claude/agents", to: t.root.appendingPathComponent("elsewhere/agents").path)
        t.put("proj/AGENTS.md", "rules")
        t.link("proj/.claude", to: t.root.appendingPathComponent("home/.claude").path)
        let scan = ImportScanner.scan(
            home: t.root.appendingPathComponent("home"), project: t.root.appendingPathComponent("proj"))
        #expect(scan.items(of: .agent).map(\.name) == ["proj"], "only AGENTS.md of the project")
        #expect(scan.items(of: .command).map(\.name) == ["ok"], "the user's own commands are still read")
        #expect(scan.skipped.filter { $0.reason == .link }.count >= 2)
    }

    @Test func theHomeFolderItselfMayBeBehindALink() {
        let t = Tree()
        t.put("real/.claude/agents/a.md", "---\nname: a\n---\nbody")
        t.link("alias", to: t.root.appendingPathComponent("real").path)
        let scan = ImportScanner.scan(home: t.root.appendingPathComponent("alias"))
        #expect(scan.items(of: .agent).map(\.name) == ["a"], "only what is below the home folder counts")
    }

    @Test func aCutShortFolderIsNamedAndASkillThatWasCutIsNotTaken() {
        let t = Tree()
        t.put(".claude/skills/deep/SKILL.md", "x")
        t.put(".claude/skills/deep/a/b/c/d/e/f/too-deep.txt", "x")
        t.put(".claude/skills/wide/SKILL.md", "x")
        for i in 0..<20 { t.put(".claude/skills/wide/f\(i).txt", "x") }
        t.put(".claude/skills/small/SKILL.md", "x")
        for i in 0..<30 { t.put(".claude/commands/c\(i).md", "x") }
        let scan = ImportScanner.scan(home: t.root, maxVisited: 10)
        func reason(_ suffix: String) -> ImportSkipReason? { scan.skipped.first { $0.path.hasSuffix(suffix) }?.reason }
        #expect(reason("skills/deep") == .truncated, "deeper than the limit")
        #expect(reason("skills/wide") == .truncated, "more files than the limit")
        #expect(scan.items(of: .skill).map(\.name) == ["small"])
        #expect(reason("commands") == .truncated, "the folder is named, so the list is not taken for complete")
        #expect(scan.items(of: .command).count <= 10)
    }

    @Test func aFileThatLooksLikeItHoldsAKeyCarriesAWarning() {
        let t = Tree()
        t.put(".claude/commands/deploy.md", "Run with API_KEY=\"abcdef1234567890abcdef\"")
        t.put(".claude/commands/safe.md", "Run the deploy")
        let scan = ImportScanner.scan(home: t.root)
        #expect(scan.items.first { $0.name == "deploy" }?.warnings == [.looksLikeSecret])
        #expect(scan.items.first { $0.name == "safe" }?.warnings == [])
    }

    @Test func nothingElseInTheHomeIsRead() {
        let t = Tree()
        t.put(".claude/settings.json", "{\"apiKey\":\"sk-abcdefghijklmnopqrstuvwxyz\"}")
        t.put(".claude.json", "{}")
        t.put(".claude/.credentials.json", "{}")
        t.put(".claude/projects/x/session.jsonl", "{}")
        t.put(".codex/auth.json", "{}")
        t.put(".codex/config.toml", "x")
        let scan = ImportScanner.scan(home: t.root)
        #expect(scan.items.isEmpty && scan.skipped.isEmpty)
    }

    @Test func aBadCommandNameIsSkipped() {
        let t = Tree()
        t.put(".claude/commands/bad name.md", "x")
        t.put(".claude/commands/ok-name.md", "x")
        let scan = ImportScanner.scan(home: t.root)
        #expect(scan.items.map(\.name) == ["ok-name"])
        #expect(scan.skipped.first?.reason == .badName)
    }
}
