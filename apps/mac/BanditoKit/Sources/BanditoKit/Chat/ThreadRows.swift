import Foundation

/// The names of the tools an agent calls.
public enum ToolNames {
    /// A browser tool of an agent, by its name: `browser_*`, or the Bandito server's `mcp__bandito__browser_*`.
    public static func isBrowser(_ tool: String) -> Bool {
        let name = tool.lowercased()
        return name.hasPrefix("browser_") || name.hasPrefix("mcp__bandito__browser_")
    }
}

// MARK: - Thread rows

/// One row of the thread as shown: consecutive tool calls are one group, days and chapters are dividers.
public enum ThreadRow: Sendable {
    /// Start of a calendar day (local time).
    case day(Date)
    /// Start of a memory chapter; `saved` is false when its memory was not saved.
    case chapter(number: Int, saved: Bool)
    /// Any other item, shown as it is.
    case item(ThreadItem)
    /// Consecutive tool calls, shown as one card.
    case toolGroup([ToolRow])
    /// Consecutive browser calls of the agent, shown as one live card (see `BrowserRunCard`).
    case browserRun([ToolRow])
}

extension ThreadRow: Equatable {}

extension ThreadRow: Identifiable {
    /// Stable across updates, so a row keeps its identity (and its entrance animation) when others arrive.
    public var id: String {
        switch self {
        case .day(let date): "day-\(date.timeIntervalSince1970)"
        case .chapter(let number, _): "chapter-\(number)"
        case .item(let item): item.id
        case .toolGroup(let tools): "tools-\(tools.first?.callId ?? "")"
        case .browserRun(let tools): "browser-\(tools.first?.callId ?? "")"
        }
    }
}

public enum ThreadRows {
    /// Builds the rows of a thread. Items without a timestamp (streams, tools, approvals) stay in the day they follow.
    public static func build(_ items: [ThreadItem], calendar: Calendar = .current) -> [ThreadRow] {
        var rows: [ThreadRow] = []
        var pending: [ToolRow] = []
        var lastDay: Date?

        /// Tool calls go out as runs: browser calls as a browser card, the rest as a command group, in order.
        func flushTools() {
            var run: [ToolRow] = []
            var runIsBrowser = false
            for tool in pending {
                let isBrowser = ToolNames.isBrowser(tool.tool)
                if !run.isEmpty, isBrowser != runIsBrowser {
                    rows.append(runIsBrowser ? .browserRun(run) : .toolGroup(run))
                    run = []
                }
                runIsBrowser = isBrowser
                run.append(tool)
            }
            if !run.isEmpty {
                rows.append(runIsBrowser ? .browserRun(run) : .toolGroup(run))
            }
            pending = []
        }

        for item in items {
            if case .tool(let row) = item {
                pending.append(row)
                continue
            }
            flushTools()
            if let ts = timestamp(of: item) {
                let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(ts) / 1000))
                if day != lastDay {
                    rows.append(.day(day))
                    lastDay = day
                }
            }
            if case .chapter(_, let number, let saved, _) = item {
                rows.append(.chapter(number: number, saved: saved))
            } else {
                rows.append(.item(item))
            }
        }
        flushTools()
        return rows
    }

    /// The rows of `new` made from the rows of `old` when only the last item changed and it is a stream (no time, its
    /// own row, its own id); nil otherwise (then the rows are built again).
    public static func replacingLast(_ rows: [ThreadRow], from old: [ThreadItem], to new: [ThreadItem]) -> [ThreadRow]? {
        guard old.count == new.count, let last = new.last, let previous = old.last, last.id == previous.id,
            case .streaming = last, case .item(let shown)? = rows.last, shown.id == last.id,
            old.dropLast().elementsEqual(new.dropLast())
        else { return nil }
        return rows.dropLast() + [.item(last)]
    }

    /// Timestamp in Unix milliseconds, when the item has one.
    public static func timestamp(of item: ThreadItem) -> Int64? { item.timestamp }
}
