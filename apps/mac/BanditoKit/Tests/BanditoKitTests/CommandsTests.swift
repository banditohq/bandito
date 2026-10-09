import Foundation
import Testing

@testable import BanditoKit

@Suite struct CommandsTests {
    // MARK: Wire models

    @Test func decodesCommandListFromWire() throws {
        let json = #"""
            [{"name":"git:commit","description":"Commit","args_hint":"[msg]","source":"project","path":"/w/.claude/commands/git/commit.md","runtime_native":true},
             {"name":"prompt","source":"codex_prompt","path":"/home/me/.codex/prompts/prompt.md","runtime_native":false}]
            """#
        let list = try RPCClient.decoder.decode([AgentCommand].self, from: Data(json.utf8))
        #expect(list[0].name == "git:commit")
        #expect(list[0].argsHint == "[msg]")
        #expect(list[0].source == .project)
        #expect(list[0].runtimeNative)
        #expect(list[1].source == .codexPrompt)
        #expect(list[1].description == nil)
        #expect(list[1].id == "codex_prompt:prompt")
    }

    @Test func unknownCommandSourceFallsBackToUser() throws {
        let json = #"{"name":"x","source":"from_the_future","path":"/p","runtime_native":false}"#
        let command = try RPCClient.decoder.decode(AgentCommand.self, from: Data(json.utf8))
        #expect(command.source == .user)
    }

    // MARK: Front matter

    @Test func frontMatterReadsTopLevelKeysOnly() {
        let text = """
            ---
            description: "Review a PR"
            argument-hint: <number>
            tools:
              - bash
            ---
            Body $ARGUMENTS
            """
        let fields = MacCommandParser.frontMatter(text)
        #expect(fields["description"] == "Review a PR")
        #expect(fields["argument-hint"] == "<number>")
        #expect(fields["tools"] == nil)
    }

    @Test func textWithoutFrontMatterHasNoFields() {
        #expect(MacCommandParser.frontMatter("Just a prompt").isEmpty)
    }

    // MARK: Mac commands

    @Test func commandNameComesFromItsPath() {
        let body = Data("---\ndescription: Commit it\n---\nCommit it".utf8)
        let command = MacCommandParser.command(relativePath: "git/commit.md", data: body)
        #expect(command?.name == "git:commit")
        #expect(command?.kind == .command)
        #expect(command?.description == "Commit it")
        #expect(command?.files == [MacCommandFile(path: "git/commit.md", data: body)])
    }

    @Test func commandsWithUnsafeNamesAreSkipped() {
        #expect(MacCommandParser.command(relativePath: ".hidden.md", data: Data()) == nil)
        #expect(MacCommandParser.command(relativePath: "my cmd.md", data: Data()) == nil)
        #expect(MacCommandParser.command(relativePath: "notes.txt", data: Data()) == nil)
    }

    @Test func skillNameComesFromFrontMatterOrFolder() {
        let skillMD = Data("---\nname: pdf\ndescription: Work with PDFs\n---\nBody".utf8)
        let named = MacCommandParser.skill(
            folder: "pdf-tools",
            files: [
                MacCommandFile(path: "SKILL.md", data: skillMD),
                MacCommandFile(path: "scripts/run.sh", data: Data("echo 1".utf8)),
            ])
        #expect(named?.name == "pdf")
        #expect(named?.kind == .skill)
        #expect(named?.description == "Work with PDFs")
        #expect(named?.files.count == 2)

        let unnamed = MacCommandParser.skill(
            folder: "deploy", files: [MacCommandFile(path: "SKILL.md", data: Data("Body".utf8))])
        #expect(unnamed?.name == "deploy")
    }

    @Test func skillNeedsSkillMarkdown() {
        let folder = [MacCommandFile(path: "README.md", data: Data("x".utf8))]
        #expect(MacCommandParser.skill(folder: "x", files: folder) == nil)
    }

    @Test func scanFindsCommandsAndSkillsUnderClaudeHome() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bandito-scan-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        let commands = claude.appendingPathComponent("commands/git")
        let skill = claude.appendingPathComponent("skills/pdf")
        try fm.createDirectory(at: commands, withIntermediateDirectories: true)
        try fm.createDirectory(at: skill.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("---\ndescription: Commit\n---\nDo it".utf8).write(to: commands.appendingPathComponent("commit.md"))
        try Data("---\nname: pdf\n---\nBody".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("echo".utf8).write(to: skill.appendingPathComponent("scripts/run.sh"))
        try Data("skip".utf8).write(to: claude.appendingPathComponent("commands/notes.txt"))

        let found = MacCommandScanner.scan(claudeHome: claude)
        #expect(found.map(\.id).sorted() == ["command:git:commit", "skill:pdf"])
        let scannedSkill = found.first { $0.kind == .skill }
        #expect(scannedSkill?.files.map(\.path).sorted() == ["SKILL.md", "scripts/run.sh"])
    }

    // MARK: Install

    @Test func installRequestForSkillCarriesBase64Files() {
        let skill = MacCommandParser.skill(
            folder: "pdf",
            files: [
                MacCommandFile(path: "SKILL.md", data: Data("Body".utf8)),
                MacCommandFile(path: "scripts/run.sh", data: Data("echo 1".utf8)),
            ])!
        let request = CommandInstallRequest.user(skill)
        #expect(request.scope == "user")
        #expect(request.agentId == nil)
        #expect(request.kind == .skill)
        #expect(request.name == "pdf")
        #expect(request.overwrite == false)
        #expect(
            request.files == [
                CommandFile(path: "SKILL.md", content: Data("Body".utf8).base64EncodedString()),
                CommandFile(path: "scripts/run.sh", content: Data("echo 1".utf8).base64EncodedString()),
            ])
    }

    @Test func installRequestForCommandIsOneFile() {
        let command = MacCommandParser.command(relativePath: "git/commit.md", data: Data("Commit".utf8))!
        let request = CommandInstallRequest.user(command)
        #expect(request.kind == .command)
        #expect(request.name == "git:commit")
        #expect(request.files == [CommandFile(path: "git/commit.md", content: Data("Commit".utf8).base64EncodedString())])
    }

    @Test func installRequestEncodesWireKeys() throws {
        let command = MacCommandParser.command(relativePath: "worklog.md", data: Data("Log".utf8))!
        let data = try RPCClient.encoder.encode(CommandInstallRequest.user(command))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["scope"] as? String == "user")
        #expect(json["kind"] as? String == "command")
        #expect(json["overwrite"] as? Bool == false)
        #expect(json["agent_id"] == nil)
    }
}

@Suite struct RuntimeEffortTests {
    @Test func effortLevelsFollowTheRuntime() {
        #expect(RuntimeKind.claude.supportedEfforts == [.low, .medium, .high, .xhigh, .max])
        #expect(RuntimeKind.api.supportedEfforts == RuntimeKind.claude.supportedEfforts)
        #expect(RuntimeKind.codex.supportedEfforts == [.low, .medium, .high, .xhigh])
        #expect(RuntimeKind.grok.supportedEfforts == [.low, .medium, .high])
    }

    @Test func unsupportedLevelDropsToTheHighestOneBelow() {
        #expect(RuntimeKind.codex.clampedEffort(.max) == .xhigh)
        #expect(RuntimeKind.grok.clampedEffort(.xhigh) == .high)
        #expect(RuntimeKind.grok.clampedEffort(.max) == .high)
        #expect(RuntimeKind.codex.clampedEffort(.low) == .low)
        #expect(RuntimeKind.claude.clampedEffort(.max) == .max)
    }
}
