import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The import screen's rules: conflicts, renames, and what is sent for each kind of thing.
@Suite struct ImportPlanTests {
    private func agent(
        _ name: String, path: String? = nil, tools: [String]? = nil, model: String? = nil, warnings: [ImportWarning] = []
    ) -> ImportItem {
        ImportItem(
            kind: .agent, origin: .claudeUser, name: name, summary: nil, path: path ?? "~/.claude/agents/\(name).md",
            frontMatter: [], bodyPreview: "", warnings: warnings,
            payload: .agent(ImportedAgent(name: name, role: "role", instructions: "Do it.", tools: tools, model: model)))
    }

    private func command(_ name: String, kind: ImportKind = .command, path: String? = nil) -> ImportItem {
        let file = MacCommandFile(path: kind == .skill ? "SKILL.md" : "\(name).md", data: Data("body".utf8))
        let made = MacCommand(name: name, kind: kind == .skill ? .skill : .command, description: nil, argsHint: nil, files: [file])
        return ImportItem(
            kind: kind, origin: .claudeUser, name: name, summary: nil,
            path: path ?? "~/.claude/\(kind == .skill ? "skills" : "commands")/\(name)", frontMatter: [], bodyPreview: "",
            warnings: [], payload: .command(made))
    }

    // MARK: conflicts

    @Test func everythingStartsSelectedAndReady() {
        let plan = ImportPlan(items: [agent("a"), command("c"), command("s", kind: .skill)])
        #expect(plan.states() == [.ready("a"), .ready("c"), .ready("s")])
        #expect(plan.count == 3 && plan.canImport)
    }

    @Test func aNameTheServerHasIsRenamedByDefaultAndMayBeSkipped() {
        let existing = ImportPlan.Existing(agents: ["Reviewer"], commands: ["deploy"], skills: ["pdf"])
        var plan = ImportPlan(
            items: [agent("reviewer"), command("deploy"), command("pdf", kind: .skill), command("pdf")], existing: existing)
        // The agent name is compared without case; a skill and a command of one name are different things.
        #expect(plan.states() == [.ready("reviewer-imported"), .ready("deploy-imported"), .ready("pdf-imported"), .ready("pdf")])
        #expect(plan.rows[0].resolution == .rename("reviewer-imported"))
        plan.setResolution(plan.rows[0].id, .skip)
        #expect(plan.states()[0] == .skippedByYou)
        #expect(plan.steps.map(\.name) == ["deploy-imported", "pdf-imported", "pdf"])
        #expect(plan.skippedByYou.map(\.name) == ["reviewer"])
    }

    @Test func aTypedNameThatIsTakenToo() {
        let existing = ImportPlan.Existing(agents: ["a", "b"])
        var plan = ImportPlan(items: [agent("a")], existing: existing)
        let id = plan.rows[0].id
        plan.setResolution(id, .rename("B"))
        #expect(plan.states() == [.conflict("B")])
        #expect(!plan.canImport, "a name that is still taken blocks the import")
        plan.setResolution(id, .rename("c"))
        #expect(plan.states() == [.ready("c")] && plan.canImport)
    }

    @Test func twoItemsOfOneNameInTheBatchConflictToo() {
        let plan = ImportPlan(items: [agent("x", path: "~/.claude/agents/x.md"), agent("x", path: "proj/.claude/agents/x.md")])
        #expect(plan.states() == [.ready("x"), .ready("x-imported")])
        #expect(plan.steps.map(\.name) == ["x", "x-imported"])
    }

    @Test func aFreeNameIsFoundAmongTheTakenOnes() {
        let taken: Set<String> = ["x-imported", "x-imported-2"]
        #expect(ImportPlan.freeName("x", kind: .command, taken: taken) == "x-imported-3")
        // An agent's name stays within 32 characters, whatever is added.
        let long = String(repeating: "a", count: 32)
        let fitted = ImportPlan.freeName(long, kind: .agent, taken: [])
        #expect(fitted.count == 32 && fitted.hasSuffix("-imported"))
        let again = ImportPlan.freeName(long, kind: .agent, taken: [fitted])
        #expect(again.count == 32 && again.hasSuffix("-imported-2") && again != fitted)
    }

    @Test func leavingAnItemOutFreesItsName() {
        var plan = ImportPlan(items: [agent("x", path: "a"), agent("x", path: "b")])
        // The second one was renamed; leaving the first out does not take the rename back, but the rename is free to use.
        plan.setSelected(plan.rows[0].id, false)
        #expect(plan.states() == [.notSelected, .ready("x-imported")])
        #expect(plan.steps.map(\.name) == ["x-imported"])
    }

    // MARK: items that look like they hold a secret

    @Test func anItemThatLooksLikeItHoldsASecretStartsUnchecked() {
        let plan = ImportPlan(items: [agent("fine"), agent("risky", warnings: [.looksLikeSecret]), command("c")])
        #expect(plan.rows.map(\.selected) == [true, false, true])
        #expect(plan.states() == [.ready("fine"), .notSelected, .ready("c")])
        #expect(plan.steps.map(\.name) == ["fine", "c"])
        #expect(plan.rows[1].flagged && !plan.rows[0].flagged)
        // Other warnings do not uncheck.
        let other = ImportPlan(items: [agent("a", warnings: [.leftOutFiles(2)])])
        #expect(other.rows[0].selected)
    }

    @Test func aGroupCheckLeavesWhatLooksLikeASecretAndItCanStillBeCheckedOnItsOwn() {
        var plan = ImportPlan(items: [agent("fine"), agent("risky", warnings: [.looksLikeSecret])])
        plan.setSelected(kind: .agent, false)
        plan.setSelected(kind: .agent, true)
        #expect(plan.rows.map(\.selected) == [true, false], "select all does not check it")
        plan.setSelected(plan.rows[1].id, true)
        #expect(plan.steps.map(\.name) == ["fine", "risky"], "a choice of its own does")
        plan.setSelected(kind: .agent, false)
        #expect(plan.rows.map(\.selected) == [false, false], "clearing clears all")
    }

    @Test func foldersAddedLaterFollowTheSameRule() {
        var plan = ImportPlan(items: [agent("a")])
        plan.add([agent("p", path: "proj/p.md", warnings: [.looksLikeSecret]), agent("q", path: "proj/q.md")])
        #expect(plan.rows.map(\.selected) == [true, false, true])
    }

    // MARK: stopping

    @Test func stepsNotReachedAreReportedAsNotDone() {
        let plan = ImportPlan(items: [agent("a"), agent("b"), command("c")])
        let lines = ImportRunner.cancelledLines(steps: plan.steps, after: 1)
        #expect(lines.map(\.name) == ["b", "c"])
        #expect(lines.allSatisfy { $0.outcome == .skipped(.cancelled) })
        #expect(ImportRunner.cancelledLines(steps: plan.steps, after: 3).isEmpty)
        #expect(ImportRunner.cancelledLines(steps: plan.steps, after: 0).count == 3)
    }

    @MainActor
    @Test func aStoppedImportReportsEverythingItDidNotDo() async throws {
        let server = ServerModel(config: ServerConfig(name: "offline", endpoint: .defaultLocal))
        let plan = ImportPlan(items: [agent("a"), agent("b")])
        let runner = ImportRunner()
        runner.start(plan: plan, scanSkips: [], server: server, runtime: .claude)
        runner.cancel()
        for _ in 0..<200 where !runner.finished { try await Task.sleep(for: .milliseconds(10)) }
        #expect(runner.finished && !runner.running)
        #expect(runner.lines.map(\.name) == ["a", "b"])
        #expect(runner.lines.allSatisfy { $0.outcome == .skipped(.cancelled) })
    }

    // MARK: selecting

    @Test func aGroupIsSelectedOrClearedAsOne() {
        var plan = ImportPlan(items: [agent("a"), agent("b"), command("c")])
        plan.setSelected(kind: .agent, false)
        #expect(plan.states() == [.notSelected, .notSelected, .ready("c")])
        #expect(plan.count == 1)
        plan.setSelected(kind: .agent, true)
        #expect(plan.count == 3)
        plan.setSelected(kind: .agent, false)
        plan.setSelected(kind: .command, false)
        #expect(plan.count == 0 && !plan.canImport)
    }

    @Test func itemsOfAnotherFolderAreAddedOnceAndKeepTheirChoices() {
        var plan = ImportPlan(items: [agent("a")])
        plan.setSelected(plan.rows[0].id, false)
        plan.add([agent("a"), agent("p", path: "proj/p.md")])
        #expect(plan.rows.count == 2, "the same file is not added twice")
        #expect(!plan.rows[0].selected && plan.rows[1].selected)
    }

    @Test func theServerAnsweringLateRenamesWhatIsTaken() {
        var plan = ImportPlan(items: [command("deploy")])
        #expect(plan.states() == [.ready("deploy")])
        plan.setExisting(ImportPlan.Existing(commands: ["deploy"]))
        #expect(plan.states() == [.ready("deploy-imported")])
    }

    // MARK: names

    @Test func namesAreCheckedForTheirKind() {
        #expect(ImportPlan.problem("", kind: .agent) == .empty)
        #expect(ImportPlan.problem(String(repeating: "a", count: 33), kind: .agent) == .tooLong)
        #expect(ImportPlan.problem("a/b", kind: .agent) == .badCharacters)
        #expect(ImportPlan.problem("My agent_1-x", kind: .agent) == nil)
        #expect(ImportPlan.problem("git:commit", kind: .command) == nil)
        #expect(ImportPlan.problem("git:", kind: .command) == .badCharacters)
        #expect(ImportPlan.problem("a b", kind: .command) == .badCharacters)
        #expect(ImportPlan.problem("git:commit", kind: .skill) == .badCharacters)
        #expect(ImportPlan.problem(".hidden", kind: .skill) == .badCharacters)
        #expect(ImportPlan.problem("-x", kind: .skill) == .badCharacters, "the server wants a letter, a digit or _ first")
        #expect(ImportPlan.problem("_x.y-z", kind: .skill) == nil)
    }

    @Test func aBadTypedNameBlocksTheImport() {
        var plan = ImportPlan(items: [command("a")])
        plan.setResolution(plan.rows[0].id, .rename("no good"))
        #expect(plan.states() == [.invalid("no good", .badCharacters)])
        #expect(!plan.canImport && plan.steps.isEmpty)
    }

    @Test func theServersListsBecomeWhatThePlanKnows() throws {
        func decode(_ raw: String) throws -> [AgentCommand] {
            try RPCClient.decoder.decode([AgentCommand].self, from: Data(raw.utf8))
        }
        let list = try decode(
            #"[{"name":"deploy","source":"user","path":"/h/.claude/commands/deploy.md","runtime_native":true},{"name":"pdf","source":"skill","path":"/h/.claude/skills/pdf","runtime_native":true},{"name":"mine","source":"project","path":"/p","runtime_native":true},{"name":"plan","source":"codex_prompt","path":"/h/.codex/prompts/plan.md","runtime_native":false}]"#)
        let existing = ImportExisting.make(agents: [], commands: list)
        #expect(existing.commands == ["deploy"])
        #expect(existing.skills == ["pdf"])
    }

    // MARK: what is sent

    @Test func anAgentIsCreatedInItsOwnFolderWithItsCapabilitiesAndModel() {
        let imported = ImportedAgent(
            name: "rev", role: "Reviews", instructions: "You review.", tools: ["Read", "Bash", "Edit"], model: "sonnet")
        let sent = ImportRunner.request(imported, name: "rev-imported", runtime: .claude, lists: [:])
        #expect(sent.name == "rev-imported" && sent.role == "Reviews")
        #expect(sent.systemPrompt == "You review.")
        #expect(sent.runtime == .claude && sent.model == "sonnet")
        #expect(sent.cwd == "", "the server gives the agent a folder of its own")
        #expect(sent.capabilities == ["terminal", "files"])
        // The same file on another runtime: the model is not offered there, so none is sent.
        let codex = ImportRunner.request(imported, name: "rev", runtime: .codex, lists: [:])
        #expect(codex.model == nil && codex.runtime == .codex)
        // No tools listed: no capability list, so the agent may do everything.
        let free = ImportedAgent(name: "x", role: "", instructions: "i", tools: nil, model: nil)
        #expect(ImportRunner.request(free, name: "x", runtime: .claude, lists: [:]).capabilities == nil)
    }

    @Test func aSkillGoesAsItsFolderAndNeverOverwrites() throws {
        let files = [
            MacCommandFile(path: "SKILL.md", data: Data("s".utf8)),
            MacCommandFile(path: "scripts/run.sh", data: Data("echo".utf8)),
        ]
        let skill = MacCommand(name: "pdf", kind: .skill, description: nil, argsHint: nil, files: files)
        let request = ImportRunner.installRequest(skill, kind: .skill, name: "pdf-imported")
        #expect(request.scope == "user" && request.kind == .skill && request.name == "pdf-imported")
        #expect(request.files.map(\.path) == ["SKILL.md", "scripts/run.sh"])
        #expect(Data(base64Encoded: request.files[1].content) == Data("echo".utf8))
        #expect(!request.overwrite)
        #expect(request.agentId == nil)
    }

    @Test func aCommandIsOneFileNamedForItsLastPart() {
        let command = MacCommand(
            name: "git:commit", kind: .command, description: nil, argsHint: nil,
            files: [MacCommandFile(path: "git/commit.md", data: Data("c".utf8))])
        let request = ImportRunner.installRequest(command, kind: .command, name: "git:save")
        #expect(request.kind == .command && request.name == "git:save")
        #expect(request.files.map(\.path) == ["save.md"])
        #expect(!request.overwrite)
    }
}
