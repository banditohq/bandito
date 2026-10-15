import BanditoKit
import BanditoL10n
import Foundation

// The last messages of each chat, kept on disk so a chat opens with its history while the connection is still being made
// (or is not there at all). It is a copy: the history read from the server replaces it. Only text and the facts the chat
// already holds are kept: no attachments, no pictures, no tool output, no cards that wait for an answer.

/// One item of a chat as it is saved: a message, a note, a chapter mark, a scheduled run, a quiet turn.
struct CachedChatItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case user, assistant, note, runtimeSwitch, chapter, scheduleRun, quietTurn
    }

    var kind: Kind
    var id: String
    var text: String = ""
    var ts: Int64 = 0
    /// A person's message: the source (`MessageSource` raw value) and the sender's name for a teammate.
    var source: String?
    var from: String?
    /// A note: `NoteKind` raw value.
    var noteKind: String?
    /// A runtime switch: where from and to, and until when.
    var switchTo: String?
    var until: Int64?
    /// A chapter.
    var number: Int?
    var saved: Bool?
    /// A scheduled run (its prompt is `text`).
    var run: ScheduleRun?
    /// A quiet turn.
    var reason: String?
    /// A person's message that was only a file: the file is not kept, so it reads as a line saying there was one.
    var attachmentOnly: Bool?

    /// The most characters of one message that are kept; the rest is a quiet loss in a copy (the server has it all).
    static let textLimit = 20_000

    init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The saved form of an item, nil for what is not kept (tool calls, approvals, forms, connect requests, a stream).
    init?(_ item: ThreadItem) {
        switch item {
        case .user(let id, let text, let source, let from, let ts, let files):
            self.init(kind: .user, id: id)
            self.text = Self.cut(text)
            if text.isEmpty, !files.isEmpty { attachmentOnly = true }
            self.ts = ts
            self.source = source.rawValue
            self.from = from
        case .assistant(let id, let text, let ts):
            self.init(kind: .assistant, id: id)
            self.text = Self.cut(text)
            self.ts = ts
        case .note(let id, let text, let kind, let ts):
            self.init(kind: .note, id: id)
            self.text = Self.cut(text)
            self.ts = ts
            noteKind = kind.rawValue
        case .runtimeSwitch(let id, let from, let to, let until, let ts):
            self.init(kind: .runtimeSwitch, id: id)
            self.from = from
            switchTo = to
            self.until = until
            self.ts = ts
        case .chapter(let id, let number, let saved, let ts):
            self.init(kind: .chapter, id: id)
            self.number = number
            self.saved = saved
            self.ts = ts
        case .scheduleRun(let id, let run, let prompt, let ts):
            self.init(kind: .scheduleRun, id: id)
            self.run = run
            text = Self.cut(prompt)
            self.ts = ts
        case .quietTurn(let id, let reason, _, let ts):
            self.init(kind: .quietTurn, id: id)
            self.reason = reason
            self.ts = ts
        case .streaming, .tool, .approval, .form, .connect:
            return nil
        }
    }

    private static func cut(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "…" : text
    }

    /// The item as the thread holds it; nil for a record that does not read (a newer app wrote it).
    var item: ThreadItem? {
        switch kind {
        case .user:
            return .user(
                id: id, text: attachmentOnly == true ? L10n.Ios.Chat.attachmentPlaceholder : text, source: source.flatMap(MessageSource.init(rawValue:)) ?? .user, from: from, ts: ts)
        case .assistant:
            return .assistant(id: id, text: text, ts: ts)
        case .note:
            return .note(id: id, text: text, kind: noteKind.flatMap(NoteKind.init(rawValue:)) ?? .info, ts: ts)
        case .runtimeSwitch:
            guard let from, let switchTo else { return nil }
            return .runtimeSwitch(id: id, from: from, to: switchTo, until: until, ts: ts)
        case .chapter:
            guard let number else { return nil }
            return .chapter(id: id, number: number, saved: saved ?? true, ts: ts)
        case .scheduleRun:
            guard let run else { return nil }
            return .scheduleRun(id: id, run: run, prompt: text, ts: ts)
        case .quietTurn:
            return .quietTurn(id: id, reason: reason, steps: [], ts: ts)
        }
    }
}

/// What is saved of one chat.
struct ChatHistorySnapshot: Codable, Equatable, Sendable {
    struct Reply: Codable, Equatable, Sendable {
        var seq: Int64
        var answers: Int64
    }

    struct Reactions: Codable, Equatable, Sendable {
        var seq: Int64
        var chips: [ChatReactionChip]
    }

    static let currentVersion = 1

    var version = ChatHistorySnapshot.currentVersion
    /// Unix ms.
    var savedAt: Int64
    var items: [CachedChatItem]
    var replies: [Reply]
    var reactions: [Reactions]

    /// The newest `limit` items of a thread, with the replies and reactions that belong to them.
    init(thread: AgentThread, now: Int64, limit: Int = ChatHistoryCache.itemLimit) {
        savedAt = now
        let kept = thread.items.compactMap(CachedChatItem.init).suffix(limit)
        items = Array(kept)
        let seqs = Set(kept.compactMap { Self.seq(of: $0.id) })
        replies = thread.replies.filter { seqs.contains($0.key) }.map { Reply(seq: $0.key, answers: $0.value) }.sorted { $0.seq < $1.seq }
        reactions = thread.reactions.compactMap { entry -> Reactions? in
            guard seqs.contains(entry.key) else { return nil }
            let chips = entry.value.chips.map(ChatReactionChip.init)
            return chips.isEmpty ? nil : Reactions(seq: entry.key, chips: chips)
        }.sorted { $0.seq < $1.seq }
    }

    /// `s123` is the event with `seq` 123.
    private static func seq(of id: String) -> Int64? {
        guard id.hasPrefix("s"), let seq = Int64(id.dropFirst()) else { return nil }
        return seq
    }

    /// The thread to draw while the real one is not read: the saved items and nothing that happens now.
    var thread: AgentThread {
        var thread = AgentThread()
        thread.items = items.compactMap(\.item)
        return thread
    }

    var replyMap: [Int64: Int64] { Dictionary(replies.map { ($0.seq, $0.answers) }, uniquingKeysWith: { _, last in last }) }
    var reactionMap: [Int64: [ChatReactionChip]] {
        Dictionary(reactions.map { ($0.seq, $0.chips) }, uniquingKeysWith: { _, last in last })
    }
}

/// The saved chats: one JSON file per (server, agent) in Application Support, behind the first unlock, out of the
/// backup. Safe to call from any thread.
struct ChatHistoryCache: Sendable {
    /// The most items kept per agent.
    static let itemLimit = 200

    let directory: URL

    init(directory: URL = ChatHistoryCache.defaultDirectory) {
        self.directory = directory
    }

    static let shared = ChatHistoryCache()

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "ChatCache", directoryHint: .isDirectory)
    }

    /// Writes the snapshot. A copy that cannot be kept is only a missing convenience.
    func save(_ snapshot: ChatHistorySnapshot, serverID: UUID, agentID: String) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try prepare(serverFolder(serverID))
            var url = file(serverID, agentID)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } catch {
            // Nothing to do: the chat just opens without its copy next time.
        }
    }

    /// The saved chat, nil when there is none or the file cannot be read (a file that does not decode is removed).
    func load(serverID: UUID, agentID: String) -> ChatHistorySnapshot? {
        let url = file(serverID, agentID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(ChatHistorySnapshot.self, from: data),
            snapshot.version == ChatHistorySnapshot.currentVersion
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return snapshot
    }

    /// The agent is gone.
    func remove(serverID: UUID, agentID: String) {
        try? FileManager.default.removeItem(at: file(serverID, agentID))
    }

    /// The server is forgotten: all its chats go.
    func remove(serverID: UUID) {
        try? FileManager.default.removeItem(at: serverFolder(serverID))
    }

    /// The server's agents are known: the chats of any other agent of it go.
    func prune(serverID: UUID, keeping agentIDs: Set<String>) {
        let keep = Set(agentIDs.map(Self.fileName))
        let folder = serverFolder(serverID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    /// The agents of a server that have a saved chat (tests).
    func savedAgentFiles(serverID: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: serverFolder(serverID).path)) ?? []).sorted()
    }

    // MARK: files

    private func serverFolder(_ serverID: UUID) -> URL {
        directory.appending(path: serverID.uuidString, directoryHint: .isDirectory)
    }

    private func file(_ serverID: UUID, _ agentID: String) -> URL {
        serverFolder(serverID).appending(path: Self.fileName(agentID))
    }

    /// An agent id is the server's word: it never becomes a path by itself (no slash, no dots, no odd characters).
    static func fileName(_ agentID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = agentID.unicodeScalars.map { allowed.contains($0) ? String($0) : String(format: "%%%02X", $0.value) }.joined()
        return (safe.isEmpty ? "agent" : safe) + ".json"
    }

    /// The folders hold chats that are private: closed until the first unlock, and out of the backup.
    private func prepare(_ folder: URL) throws {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
            var root = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
        if !manager.fileExists(atPath: folder.path) {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: attributes)
        }
    }
}
