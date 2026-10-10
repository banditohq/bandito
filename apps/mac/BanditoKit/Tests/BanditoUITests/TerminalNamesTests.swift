import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct TerminalNamesTests {
    private func info(_ id: String, cwd: String, createdAt: Int64, title: String = "zsh") -> TermInfo {
        TermInfo(
            id: id, title: title, cwd: cwd, command: ["/bin/zsh"], pid: 1, cols: 80, rows: 24,
            createdAt: createdAt, state: .running, offset: 0)
    }

    private func agentTitle(_ name: String) -> String { "Terminal · \(name)" }

    @Test func folderMatchIgnoresATrailingSlash() {
        #expect(TerminalNames.samePath("/work/proj1", "/work/proj1/"))
        #expect(TerminalNames.samePath("/work/./proj1", "/work/proj1"))
        #expect(!TerminalNames.samePath("/work/proj1", "/work/proj10"))
    }

    /// An agent reuses the newest session in its folder; a session in another folder is never picked.
    @Test func agentReusesTheNewestSessionInItsFolder() {
        let sessions = [
            info("old", cwd: "/work/proj1", createdAt: 100),
            info("new", cwd: "/work/proj1/", createdAt: 300),
            info("other", cwd: "/work/proj2", createdAt: 400),
        ]
        #expect(TerminalNames.newestSession(in: "/work/proj1", among: sessions)?.id == "new")
        #expect(TerminalNames.newestSession(in: "/work/proj3", among: sessions) == nil)
        #expect(TerminalNames.newestSession(in: "/work/proj1", among: []) == nil)
    }

    /// An empty folder matches no agent and no session: a terminal without a folder is not an agent's.
    @Test func anEmptyFolderMatchesNothing() {
        let agents = [(name: "Forge", cwd: "")]
        #expect(TerminalNames.agentName(inFolder: "", among: agents) == nil)
        #expect(TerminalNames.newestSession(in: "", among: [info("e", cwd: "", createdAt: 1)]) == nil)
        let loose = info("loose", cwd: "", createdAt: 1)
        #expect(TerminalNames.baseName(of: loose, agents: agents, agentTitle: agentTitle) == "zsh")
    }

    @Test func agentsTerminalIsNamedAfterTheAgent() {
        let agents = [(name: "Forge", cwd: "/work/proj1")]
        let mine = info("a", cwd: "/work/proj1/", createdAt: 1)
        #expect(TerminalNames.baseName(of: mine, agents: agents, agentTitle: agentTitle) == "Terminal · Forge")
        let other = info("b", cwd: "/work/proj2", createdAt: 2)
        #expect(TerminalNames.baseName(of: other, agents: agents, agentTitle: agentTitle) == "zsh · proj2")
    }

    /// The same name twice gets "· 2" from the second terminal on, in the order they were made.
    @Test func sameNamesAreNumberedInTheOrderTheyWereMade() {
        let agents = [(name: "Forge", cwd: "/work/proj1")]
        let sessions = [
            info("a", cwd: "/work/proj1", createdAt: 100),
            info("b", cwd: "/work/proj2", createdAt: 200),
            info("c", cwd: "/work/proj2/", createdAt: 300),
            info("d", cwd: "/work/proj1", createdAt: 400),
        ]
        var numbering = TerminalNumbering()
        numbering.sync(sessions) { TerminalNames.baseName(of: $0, agents: agents, agentTitle: agentTitle) }
        let names = Dictionary(
            uniqueKeysWithValues: sessions.map {
                ($0.id, TerminalNames.displayName(
                    of: $0, number: numbering.number(of: $0.id), agents: agents, agentTitle: agentTitle))
            })
        #expect(names["a"] == "Terminal · Forge")
        #expect(names["b"] == "zsh · proj2")
        #expect(names["c"] == "zsh · proj2 · 2")
        #expect(names["d"] == "Terminal · Forge · 2")
    }

    /// Closing the first of two same-named terminals renames no one; a new one takes the next number.
    @Test func closingOneTerminalRenamesNoOther() {
        let a = info("a", cwd: "/work/proj1", createdAt: 100)
        let b = info("b", cwd: "/work/proj1", createdAt: 200)
        let c = info("c", cwd: "/work/proj1", createdAt: 300)
        let name: (TermInfo) -> String = { _ in "zsh · proj1" }
        var numbering = TerminalNumbering()
        numbering.sync([a, b], nameAtAppearance: name)
        #expect(numbering.number(of: "a") == 1)
        #expect(numbering.number(of: "b") == 2)

        numbering.sync([b], nameAtAppearance: name)
        #expect(numbering.number(of: "b") == 2, "b keeps its number after a is closed")

        numbering.sync([b, c], nameAtAppearance: name)
        #expect(numbering.number(of: "c") == 3, "a number is not handed out again")
        #expect(numbering.number(of: "b") == 2)
    }

    /// A name the person gave stays, whatever the folder.
    @Test func renamedSessionKeepsItsName() {
        let renamed = info("r", cwd: "/work/proj2", createdAt: 100, title: "build")
        #expect(TerminalNames.baseName(of: renamed, agents: [], agentTitle: agentTitle) == "build")
    }
}
