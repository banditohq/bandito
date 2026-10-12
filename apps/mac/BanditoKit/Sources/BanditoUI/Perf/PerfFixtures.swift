import BanditoKit
import Foundation

/// Synthetic data for the QA performance scenarios (`perf thread`, `perf switch`): long threads of every kind of row,
/// built in memory. The same input always gives the same rows, so two runs are comparable. The smoothness check
/// (Help menu) uses them too.
enum PerfFixtures {
    static let threadAgentID = "qa-perf-thread"

    /// A small deterministic generator (no `SystemRandomNumberGenerator`: the runs must repeat).
    struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private static let sentences = [
        "I read the module and the three call sites, and the change is small.",
        "The failing test passes now; the other 212 still pass.",
        "Here is what I found: the cache key ignored the locale, so two languages shared one entry.",
        "I would keep the old name as a deprecated alias for one release.",
        "Nothing else in the repository uses that function, so it can go.",
        "The migration is idempotent and runs inside one transaction.",
        "The build takes about forty seconds on this machine, most of it linking.",
        "I left the formatting alone and only touched the lines that had to change.",
    ]

    private static let codeSamples: [(String, String)] = [
        (
            "swift",
            """
            func merge(_ a: [Item], _ b: [Item]) -> [Item] {
                var seen = Set<String>()
                var result: [Item] = []
                for item in a + b where seen.insert(item.id).inserted {
                    result.append(item)
                }
                return result.sorted { $0.updatedAt > $1.updatedAt }
            }

            struct Item: Identifiable {
                let id: String
                var updatedAt: Date
            }
            """
        ),
        (
            "python",
            """
            def window(rows, size=300):
                # The newest `size` rows, oldest first.
                if len(rows) <= size:
                    return list(rows)
                return list(rows[-size:])

            for n, row in enumerate(window(load())):
                print(n, row.id, row.title[:60])
            """
        ),
        (
            "json",
            """
            {
              "name": "bandito",
              "version": "0.1.11",
              "features": ["forms", "mentions", "workspaces", "lead"],
              "limits": { "attachments": 20971520, "name": 200 }
            }
            """
        ),
        (
            "rust",
            """
            pub fn page(&self, agent: &str, before: Option<i64>, limit: usize) -> Result<Vec<Event>> {
                let mut stmt = self.conn.prepare(
                    "SELECT seq, body FROM events WHERE agent_id = ?1 AND seq < ?2 ORDER BY seq DESC LIMIT ?3",
                )?;
                let rows = stmt.query_map(params![agent, before.unwrap_or(i64::MAX), limit], Event::from_row)?;
                rows.collect::<rusqlite::Result<Vec<_>>>().map_err(Into::into)
            }
            """
        ),
    ]

    private static func paragraph(_ rng: inout Lcg, sentenceCount: Int) -> String {
        (0..<sentenceCount).map { _ in sentences[rng.next(sentences.count)] }.joined(separator: " ")
    }

    private static func assistantText(index: Int, _ rng: inout Lcg) -> String {
        switch index % 9 {
        case 0:
            return sentences[rng.next(sentences.count)]
        case 1:
            return paragraph(&rng, sentenceCount: 3) + "\n\n" + paragraph(&rng, sentenceCount: 4)
        case 2:
            let (lang, code) = codeSamples[rng.next(codeSamples.count)]
            return "Here is the change:\n\n```\(lang)\n\(code)\n```\n\n" + sentences[rng.next(sentences.count)]
        case 3:
            return
                "The plan:\n\n- **Read** the module `Thread.swift` and its tests\n- Change `windowSize` only where it is used\n- Run `swift test` and look at the result\n- Write a note for the next chapter\n\n"
                + sentences[rng.next(sentences.count)]
        case 4:
            return paragraph(&rng, sentenceCount: 12)
        case 5:
            let (lang, code) = codeSamples[rng.next(codeSamples.count)]
            let (lang2, code2) = codeSamples[rng.next(codeSamples.count)]
            return "Two versions to compare.\n\n```\(lang)\n\(code)\n```\n\nand\n\n```\(lang2)\n\(code2)\n```"
        case 6:
            return
                "1. Open the file\n2. Find the `onScrollGeometryChange` call\n3. Compare the value before writing it\n\nSee [the notes](https://bandito.dev/docs) for the reasons. "
                + paragraph(&rng, sentenceCount: 2)
        case 7:
            return
                "## Result\n\n> The numbers are from one run on a quiet machine.\n\n| step | before | after |\n| --- | --- | --- |\n| load | 412 ms | 96 ms |\n| scroll | 31 fps | 60 fps |\n\n"
                + sentences[rng.next(sentences.count)]
        default:
            return paragraph(&rng, sentenceCount: 6)
        }
    }

    private static func userText(index: Int, _ rng: inout Lcg) -> String {
        switch index % 5 {
        case 0: return "ok"
        case 1: return "Can you also check the tests for this?"
        case 2: return paragraph(&rng, sentenceCount: 3)
        case 3:
            let file = ["Thread.swift", "Router.swift", "ServerModel.swift"][rng.next(3)]
            return "Please look at `\(file)` and tell me what you think.\n\n" + paragraph(&rng, sentenceCount: 5)
        default: return "Thanks. " + sentences[rng.next(sentences.count)]
        }
    }

    /// `count` rows: messages of both sides in every length, code blocks, lists, tables, tool calls, notes and files.
    static func thread(count: Int, seed: UInt64 = 7) -> [ThreadItem] {
        var rng = Lcg(state: seed)
        var items: [ThreadItem] = []
        items.reserveCapacity(count)
        let end = Int64(Date().timeIntervalSince1970 * 1000)
        var seq: Int64 = 0
        var n = 0
        while items.count < count {
            n += 1
            let ts = end - Int64(count - items.count) * 45_000
            seq += 1
            if n % 2 == 1 {
                var files: [AgentAttachment] = []
                if n % 17 == 1 {
                    files = [
                        AgentAttachment(
                            path: "/tmp/qa/spec-\(n).pdf", name: "spec-\(n).pdf", size: 183_204, mime: "application/pdf"),
                        AgentAttachment(
                            path: "/tmp/qa/notes-\(n).txt", name: "notes-\(n).txt", size: 2_410, mime: "text/plain"),
                    ]
                }
                items.append(
                    .user(
                        id: ThreadItem.messageID(seq: seq), text: userText(index: n, &rng), source: .user, from: nil,
                        ts: ts, attachments: files))
            } else {
                items.append(.assistant(id: ThreadItem.messageID(seq: seq), text: assistantText(index: n, &rng), ts: ts))
            }
            guard items.count < count else { break }
            if n % 5 == 0 {
                let lines = (0..<(6 + n % 14)).map { "Test case #\($0) passed (0.00\($0 % 9) seconds)" }
                items.append(
                    .tool(
                        ToolRow(
                            callId: "perf-\(n)", tool: "bash", title: "swift test --filter Thread\(n % 7)",
                            ok: n % 23 != 0, output: lines.joined(separator: "\n"), startedAt: ts)))
            }
            guard items.count < count else { break }
            if n % 31 == 0 {
                items.append(.note(id: "perf-note-\(n)", text: "Handed over to Scout for review.", kind: .crew, ts: ts))
            }
        }
        return Array(items.prefix(count))
    }

    /// An agent for the scenarios. `index` varies role, runtime, status and the preview of its last message.
    static func agent(id: String, name: String, index: Int) -> Agent {
        let runtimes: [RuntimeKind] = [.claude, .codex, .grok]
        let roles = ["Builder", "Reviewer", "On call", "Auditor", "Docs", "Lead", "Designer", "Tester"]
        let statuses: [AgentStatus] = [.idle, .working, .idle, .needsYou, .idle, .working, .idle, .error]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Agent(
            id: id, name: name, role: roles[index % roles.count], runtime: runtimes[index % runtimes.count],
            cwd: "/Users/demo/Projects/bandito-site", createdAt: 1_700_000_000_000 + Int64(index),
            updatedAt: 1_700_000_000_000 + Int64(index), contextTokens: 12_000 + index * 3_100,
            lastTurnAt: now - Int64(index) * 300_000,
            lastMessage: LastMessage(role: "assistant", text: sentences[index % sentences.count], ts: now - Int64(index) * 300_000),
            status: statuses[index % statuses.count])
    }

    /// Names of the demo agents (the smoothness check shows forty of them).
    static let names = [
        "Forge", "Scout", "Watch", "Night Owl", "Quill", "Atlas", "Echo", "Pixel", "Harbor", "Juniper", "Kite", "Lumen",
        "Maple", "Nova", "Orbit", "Pike", "Quartz", "Raven", "Sable", "Tide", "Umber", "Vale", "Wren", "Yarrow", "Zephyr",
        "Birch", "Cinder", "Delta", "Ember", "Flint", "Grove", "Haze", "Iris", "Jade", "Knot", "Larch", "Moss", "Nettle",
        "Onyx", "Pebble",
    ]
}
