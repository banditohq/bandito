import Foundation

// What the widgets show, as the app writes it for them. The app and the widget extension both compile this folder, so
// they agree on the file. Nothing here is an address or a token: a server is its id, an agent is its id and name.

/// The App Group both targets belong to (their entitlements), and the snapshot's file name in its container.
enum WidgetAppGroup {
    static let identifier = "group.dev.bandito.ios"
    static let snapshotFileName = "widget-snapshot.json"
}

/// An agent's status as the widgets say it: working, waiting for the person, free, failed, not reachable.
enum WidgetStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case needsYou
    case error
    case offline
}

/// The face of an agent's avatar in a widget (the raccoon's pose). The app maps the Crew's `AvatarMood` to these.
enum WidgetMood: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case needsYou
    case thinking
    case error
    case sleeping
}

/// The picture the widgets read: how many things wait for the person, and up to four agents for the crew widget. The
/// App Intents and Spotlight read the directory too: the names of up to 50 agents, for "Ask <agent>" and search.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// The crew widget shows at most this many agents; the small widget names and draws at most this many waiting ones.
    static let agentLimit = 4
    static let waitingLimit = 3
    /// The directory holds at most this many agents (the intents' picker and the Spotlight index).
    static let directoryLimit = 50

    struct Agent: Codable, Equatable, Sendable {
        /// The server's id (a UUID string) for the deep link. Never its address.
        let server: String
        let id: String
        let name: String
        let status: WidgetStatus
        let mood: WidgetMood
    }

    /// An agent as a name in a list: which server it belongs to, its id, its name and its role. No address, no token.
    struct Listing: Codable, Equatable, Hashable, Sendable {
        let server: String
        let id: String
        let name: String
        let role: String
    }

    var generatedAt: Date
    /// Everything that waits for the person on the connected servers (the Inbox's count).
    var pending: Int
    var agents: [Agent]
    /// The agents that wait for the person, in the team's order: the first `waitingLimit` of them.
    var waiting: [Agent]
    /// How many agents wait for the person in all (`waiting` holds at most `waitingLimit` of them).
    var waitingCount: Int
    /// The agents of the paired servers, in the team's order, at most `directoryLimit`.
    var directory: [Listing]

    init(
        generatedAt: Date, pending: Int, agents: [Agent], waiting: [Agent] = [], waitingCount: Int? = nil,
        directory: [Listing] = []
    ) {
        self.generatedAt = generatedAt
        self.pending = max(0, pending)
        self.agents = Array(agents.prefix(Self.agentLimit))
        self.waiting = Array(waiting.prefix(Self.waitingLimit))
        self.waitingCount = max(waitingCount ?? waiting.count, self.waiting.count)
        self.directory = Array(directory.prefix(Self.directoryLimit))
    }

    /// A file written before the directory existed has none: it reads as an empty directory, not as a broken file.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        pending = try container.decode(Int.self, forKey: .pending)
        agents = try container.decode([Agent].self, forKey: .agents)
        waiting = try container.decode([Agent].self, forKey: .waiting)
        waitingCount = try container.decode(Int.self, forKey: .waitingCount)
        directory = try container.decodeIfPresent([Listing].self, forKey: .directory) ?? []
    }

    /// The names on the small widget's line: at most two of the waiting agents.
    var waitingNames: [String] {
        waiting.prefix(2).map(\.name)
    }

    /// How many waiting agents the line leaves out ("и ещё N"): none when there are two or fewer.
    var waitingMore: Int {
        max(0, waitingCount - 2)
    }

    /// The same picture whatever the time of writing: the app writes a snapshot only when this is false.
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        pending == other.pending && agents == other.agents && waiting == other.waiting
            && waitingCount == other.waitingCount && directory == other.directory
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// What the gallery and the previews show: two things waiting, a team of four.
    static let sample: WidgetSnapshot = {
        let watch = Agent(server: "sample", id: "watch", name: "Watch", status: .needsYou, mood: .needsYou)
        let forge = Agent(server: "sample", id: "forge", name: "Forge", status: .needsYou, mood: .needsYou)
        let scout = Agent(server: "sample", id: "scout", name: "Scout", status: .working, mood: .working)
        let quill = Agent(server: "sample", id: "quill", name: "Quill", status: .idle, mood: .idle)
        let agents = [watch, forge, scout, quill]
        return WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            pending: 2,
            agents: agents,
            waiting: [watch, forge],
            directory: agents.map { Listing(server: $0.server, id: $0.id, name: $0.name, role: "") })
    }()
}

/// The file of the snapshot. The app writes it through `write`, the widget reads it through `read`; nothing else.
struct WidgetSnapshotStore: Sendable {
    let fileURL: URL

    /// The store in the App Group container; nil when the group is not available (an unsigned build, no entitlement).
    static func appGroup(fileManager: FileManager = .default) -> WidgetSnapshotStore? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: WidgetAppGroup.identifier)
        else { return nil }
        return WidgetSnapshotStore(fileURL: container.appendingPathComponent(WidgetAppGroup.snapshotFileName))
    }

    /// The last snapshot written; nil when there is none yet or the file cannot be read.
    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? WidgetSnapshot.decoded(from: data)
    }

    /// Writes the snapshot atomically, so a widget never reads half of it.
    func write(_ snapshot: WidgetSnapshot) throws {
        try snapshot.encoded().write(to: fileURL, options: .atomic)
    }
}

/// Which agents a crew widget shows: the ones waiting for the person first, then the working ones, then the rest. Inside
/// each group the team's order stays.
enum WidgetAgentPicker {
    static func pick(_ agents: [WidgetSnapshot.Agent], limit: Int = WidgetSnapshot.agentLimit) -> [WidgetSnapshot.Agent] {
        let ordered = agents.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank(a.element.status), rank(b.element.status))
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
        return Array(ordered.prefix(max(0, limit)))
    }

    private static func rank(_ status: WidgetStatus) -> Int {
        switch status {
        case .needsYou: return 0
        case .working: return 1
        case .idle, .error, .offline: return 2
        }
    }
}

/// The links the widgets open: `bandito://inbox`, `bandito://crew`, `bandito://agent/<serverID>/<agentID>`.
enum BanditoLink: Equatable, Sendable {
    case inbox
    case crew
    case agent(server: String, id: String)

    static let scheme = "bandito"

    /// Reads one of the links above; nil for any other URL (a pairing link, a stranger's scheme, a malformed agent link).
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "inbox":
            self = .inbox
        case "crew":
            self = .crew
        case "agent":
            let parts = url.pathComponents.filter { $0 != "/" }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            self = .agent(server: parts[0], id: parts[1])
        default:
            return nil
        }
    }

    /// The link as a URL, with its segments escaped.
    var url: URL {
        switch self {
        case .inbox:
            return Self.inboxURL
        case .crew:
            return Self.crewURL
        case .agent(let server, let id):
            let escapedServer = server.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? server
            let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return URL(string: "\(Self.scheme)://agent/\(escapedServer)/\(escapedID)") ?? Self.crewURL
        }
    }

    // Literal URLs: they parse, so the force unwraps cannot fail.
    private static let inboxURL = URL(string: "bandito://inbox")!
    private static let crewURL = URL(string: "bandito://crew")!
}
