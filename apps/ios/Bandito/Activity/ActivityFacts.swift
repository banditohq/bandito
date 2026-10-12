import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation

// What the Activity timeline shows: the entries of every agent of every server, newest first, read from each agent's
// `activity` (BanditoKit's `ActivityFeed`). The rows are `Equatable` over their facts, like the Crew's.

/// The filters on top of the timeline. Unread is the replies no chat was read to yet: the tab's badge counts the same.
enum ActivityFilter: String, CaseIterable, Hashable, Sendable {
    case all, unread, errors

    /// The filter a launch asks for with `-activity-filter <name>` (for the screenshots); all without it.
    static func requested(in arguments: [String]) -> ActivityFilter {
        guard let index = arguments.firstIndex(of: "-activity-filter"), arguments.indices.contains(index + 1),
              let filter = ActivityFilter(rawValue: arguments[index + 1]) else { return .all }
        return filter
    }

    /// The chip's word.
    var title: String {
        switch self {
        case .all: L10n.Ios.Activity.Filter.all
        case .unread: L10n.Ios.Activity.Filter.unread
        case .errors: L10n.Ios.Activity.Filter.errors
        }
    }

    /// Whether a row is in this filter.
    func keeps(_ row: ActivityRowFacts) -> Bool {
        switch self {
        case .all: true
        case .unread: row.isUnread
        case .errors: row.kind == .error
        }
    }
}

/// The chat an entry opens: the agent, its name for the title, and the event (the thread row) the chat opens at.
struct ActivityRoute: Hashable {
    let serverID: UUID
    let agentID: String
    let name: String
    let eventID: String
}

/// One row of the timeline, as the screen shows it. Titles are built here, so a row's facts are all it shows.
struct ActivityRowFacts: Equatable, Identifiable {
    /// Unique across the servers: the server, the agent and the thread row.
    let id: String
    let serverID: UUID
    let agentID: String
    let agentName: String
    let look: CrewLook
    let kind: ActivityEntry.Kind
    /// What happened in words: "Forge finished", "Forge · Morning summary", "Forge: error", or a creation's line.
    let title: String
    /// The first line of the reply or the error; nil for a creation.
    let line: String?
    let ts: Int64
    let mood: AvatarMood
    let isUnread: Bool
    /// The thread row the chat opens at (e.g. "s12").
    let eventID: String

    var isError: Bool { kind == .error }

    var route: ActivityRoute {
        ActivityRoute(serverID: serverID, agentID: agentID, name: agentName, eventID: eventID)
    }
}

/// The rows of one day, newest first.
struct ActivityDayFacts: Equatable, Identifiable {
    /// The start of the day.
    let day: Date
    let rows: [ActivityRowFacts]

    var id: Date { day }
}

/// Groups rows by day. Pure, so it is tested alone.
enum ActivityGrouping {
    /// The rows in days, newest day first; each day's rows newest first.
    static func days(_ rows: [ActivityRowFacts], calendar: Calendar = .current) -> [ActivityDayFacts] {
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: CrewTime.date(ms: $0.ts)) }
        return grouped
            .map { day, rows in ActivityDayFacts(day: day, rows: rows.sorted { $0.ts > $1.ts }) }
            .sorted { $0.day > $1.day }
    }

    /// The heading of a day: today, yesterday (the Mac's words), else the date.
    static func title(of day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return L10n.Thread.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return L10n.Thread.yesterday
        }
        return day.formatted(date: .long, time: .omitted)
    }
}

/// Collects the timeline of the servers. Reads each agent's `activity` and `unreadCount` only: a streamed token moves
/// neither, so a reply in progress does not rebuild the timeline.
@MainActor
enum ActivityFacts {
    /// The newest entries kept in the timeline across the agents (each agent keeps its own newest 500 as well).
    static let memoryLimit = 500

    /// The timeline of the servers: the newest `memoryLimit` entries, the filter applied, grouped by day.
    static func days(servers: [ServerModel], filter: ActivityFilter, calendar: Calendar = .current) -> [ActivityDayFacts] {
        let rows = rows(servers: servers).filter { filter.keeps($0) }
        return ActivityGrouping.days(rows, calendar: calendar)
    }

    /// The unread replies of every agent of every server: the count on the Activity tab.
    static func unreadCount(servers: [ServerModel]) -> Int {
        servers.reduce(0) { total, server in
            server.sortedAgents.reduce(total) { sum, agent in
                sum + server.threadSummary(for: agent.id).unreadCount
            }
        }
    }

    /// The rows of the newest entries, newest first.
    private static func rows(servers: [ServerModel]) -> [ActivityRowFacts] {
        var entries: [(entry: ActivityEntry, agent: Agent, serverID: UUID)] = []
        for server in servers {
            for agent in server.sortedAgents {
                for entry in server.threadSummary(for: agent.id).activity {
                    entries.append((entry, agent, server.id))
                }
            }
        }
        entries.sort { $0.entry.ts > $1.entry.ts }
        return entries.prefix(memoryLimit).map { row($0.entry, agent: $0.agent, serverID: $0.serverID) }
    }

    private static func row(_ entry: ActivityEntry, agent: Agent, serverID: UUID) -> ActivityRowFacts {
        let title: String
        let line: String?
        switch entry.kind {
        case .reply:
            title = L10n.Ios.Activity.finished(name: agent.name)
            line = entry.line
        case .scheduled(let schedule):
            title = L10n.Ios.Activity.scheduled(name: agent.name, schedule: schedule)
            line = entry.line
        case .error:
            title = L10n.Ios.Activity.failed(name: agent.name)
            line = entry.line
        case .created:
            title = entry.line
            line = nil
        }
        return ActivityRowFacts(
            id: "\(serverID.uuidString)/\(agent.id)/\(entry.id)",
            serverID: serverID,
            agentID: agent.id,
            agentName: agent.name,
            look: CrewLook(agent: agent),
            kind: entry.kind,
            title: title,
            line: line.flatMap { $0.isEmpty ? nil : $0 },
            ts: entry.ts,
            mood: entry.kind == .error ? .error : .idle,
            isUnread: entry.isUnread,
            eventID: entry.id)
    }
}
