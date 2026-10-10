import BanditoKit
import BanditoL10n
import Foundation

/// Which terminal of a folder an agent reuses, and how terminals are named on screen.
enum TerminalNames {
    /// Whether two folders are the same one: a trailing slash or a `.` does not make another folder.
    static func samePath(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }

    /// The session in `folder` that was made last, among `sessions` (any state; the caller keeps the running ones).
    static func newestSession(in folder: String, among sessions: [TermInfo]) -> TermInfo? {
        guard !folder.isEmpty else { return nil }
        return sessions
            .filter { samePath($0.cwd, folder) }
            .max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The agent that works in `folder`, by name. An empty folder (an agent or a session without one) matches none.
    static func agentName(inFolder folder: String, among agents: [(name: String, cwd: String)]) -> String? {
        guard !folder.isEmpty else { return nil }
        return agents.first { !$0.cwd.isEmpty && samePath($0.cwd, folder) }?.name
    }

    /// What a session is called before its number: a name the person gave, else the agent's own terminal
    /// (`agentTitle`), else "<program> · <folder>".
    static func baseName(
        of info: TermInfo, agents: [(name: String, cwd: String)], agentTitle: (String) -> String
    ) -> String {
        let program = programName(of: info)
        if info.title != program { return info.title }
        if let agent = agentName(inFolder: info.cwd, among: agents) { return agentTitle(agent) }
        let folder = folderName(info.cwd)
        return folder.isEmpty ? program : "\(program) · \(folder)"
    }

    /// The name on screen: the base name, and "· 2", "· 3" from the second terminal of that name on.
    static func displayName(
        of info: TermInfo, number: Int, agents: [(name: String, cwd: String)], agentTitle: (String) -> String
    ) -> String {
        let base = baseName(of: info, agents: agents, agentTitle: agentTitle)
        return number > 1 ? "\(base) · \(number)" : base
    }

    /// The names of a server's terminals as the app lists them (quick open): numbered in the order they were made.
    static func names(for infos: [TermInfo], agents: [Agent]) -> [String: String] {
        let pairs = agents.map { (name: $0.name, cwd: $0.cwd) }
        let title: (String) -> String = { L10n.Terminals.agentTitle(name: $0) }
        var numbering = TerminalNumbering()
        numbering.sync(infos) { baseName(of: $0, agents: pairs, agentTitle: title) }
        return Dictionary(
            uniqueKeysWithValues: infos.map {
                ($0.id, displayName(of: $0, number: numbering.number(of: $0.id), agents: pairs, agentTitle: title))
            })
    }

    /// The program's base name, which the daemon uses as the default title.
    static func programName(of info: TermInfo) -> String {
        guard let first = info.command.first, !first.isEmpty else { return info.title }
        return (first as NSString).lastPathComponent
    }

    /// The last part of a folder, or the folder itself at the root.
    static func folderName(_ folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }
}

/// The numbers of terminals with the same name. A terminal takes the next number for its name when it appears and
/// keeps it: closing another one renames no one, and a number is not handed out again.
struct TerminalNumbering {
    /// Number by session id; 1 is the name alone.
    private var numbers: [String: Int] = [:]
    /// The highest number handed out per name, ever.
    private var highest: [String: Int] = [:]

    /// Numbers the sessions that appeared since the last call (in the order they were made) and forgets the ones
    /// that are gone. `nameAtAppearance` is the name a new session is numbered under.
    mutating func sync(_ sessions: [TermInfo], nameAtAppearance: (TermInfo) -> String) {
        let live = Set(sessions.map(\.id))
        numbers = numbers.filter { live.contains($0.key) }
        for info in sessions.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) where numbers[info.id] == nil {
            let name = nameAtAppearance(info)
            let next = (highest[name] ?? 0) + 1
            highest[name] = next
            numbers[info.id] = next
        }
    }

    func number(of id: String) -> Int {
        numbers[id] ?? 1
    }
}
