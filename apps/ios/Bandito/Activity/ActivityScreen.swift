import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI

/// Counts the bodies of the Activity rows evaluated: the speed test reads it. A streamed reply makes no row until it is
/// finished, and a finished one makes its row once. Counted in every build; it is one increment.
@MainActor
enum ActivityCounters {
    static var rowBodies = 0

    /// Called from a row's body: one more evaluation.
    static func rowBodyRan() {
        rowBodies += 1
    }
}

/// Activity, the second tab: one timeline across every agent and server, newest first, grouped by day. Filter chips on
/// top; pull to refresh means "check now"; a tap opens the agent's chat at the entry.
struct ActivityScreen: View {
    let servers: [ServerModel]

    @State private var filter = ActivityFilter.requested(in: ProcessInfo.processInfo.arguments)
    @State private var path: [ActivityRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ActivityList(servers: servers, filter: $filter)
                .navigationTitle(L10n.Ios.Tab.activity)
                .navigationBarTitleDisplayMode(.large)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationDestination(for: ActivityRoute.self) { route in
                    ActivityChatStub(route: route, markRead: { markRead(route) })
                }
        }
    }

    /// Opening a chat reads it, as the Mac's chat does: the replies up to its newest message stop counting as unread.
    private func markRead(_ route: ActivityRoute) {
        servers.first { $0.id == route.serverID }?.threadSummary(for: route.agentID).markRead()
    }
}

/// The timeline as a list: the filter chips, then one section per day. Pull to refresh reads every server's agents again.
struct ActivityList: View {
    let servers: [ServerModel]
    @Binding var filter: ActivityFilter

    var body: some View {
        let days = ActivityFacts.days(servers: servers, filter: filter)
        List {
            ActivityFilterChips(selection: $filter)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: BanditoSpace.s5, bottom: 0, trailing: BanditoSpace.s5))
                .listRowSeparator(.hidden)

            if days.isEmpty {
                Section {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                ForEach(days) { day in
                    Section {
                        ForEach(day.rows) { row in
                            NavigationLink(value: row.route) {
                                ActivityRow(facts: row).equatable()
                            }
                            .listRowBackground(Color.Bandito.surface1)
                        }
                    } header: {
                        CrewSectionLabel(title: ActivityGrouping.title(of: day.day))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .refreshable {
            // Pull to refresh means "check now": the agents of every server are read again.
            for server in servers {
                try? await server.readAgentsNow()
            }
        }
    }

    /// Nothing in the timeline: the sleeping raccoon and "All quiet for now". A filter with nothing in it says so in a line.
    private var emptyState: some View {
        VStack(spacing: BanditoSpace.s3) {
            if filter == .all {
                CrewAvatar(
                    name: "", look: CrewLook(color: .peach, face: .sleeping, customHex: nil), mood: .sleeping, size: 72)
                Text(L10n.Ios.Activity.emptyTitle)
                    .font(BanditoFont.display(size: 16.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.center)
                Text(L10n.Ios.Activity.emptyMessage)
                    .font(BanditoFont.text(size: 13.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
            } else {
                Text(filter == .errors ? L10n.Ios.Activity.emptyErrors : L10n.Ios.Activity.emptyUnread)
                    .font(BanditoFont.text(size: 14))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BanditoSpace.s6)
    }
}

/// The three filters, one selected at a time. Scrolls sideways at large type rather than clipping a chip.
struct ActivityFilterChips: View {
    @Binding var selection: ActivityFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BanditoSpace.s2) {
                ForEach(ActivityFilter.allCases, id: \.self) { filter in
                    Button {
                        selection = filter
                    } label: {
                        Text(filter.title)
                    }
                    .buttonStyle(ActivityChipStyle(selected: selection == filter))
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
            .padding(.vertical, BanditoSpace.s1)
        }
    }
}

/// A chip: a cream capsule when selected, a quiet one otherwise (the quiet button's fill and border, in this target).
struct ActivityChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.text(size: 13, weight: selected ? 600 : 500))
            .foregroundStyle(selected ? Color.Bandito.bg : Color.Bandito.text2)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(Capsule().fill(selected ? Color.Bandito.text : Color.Bandito.text.opacity(0.06)))
            .overlay {
                if !selected {
                    Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// One entry: the agent's raccoon, what happened, the first line of the reply, the time, and an unread dot. `Equatable`
/// over its facts: the list builds it again only when a fact it shows changed.
struct ActivityRow: View, Equatable {
    let facts: ActivityRowFacts

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 13.5
    @ScaledMetric(relativeTo: .body) private var lineSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var timeSize: CGFloat = 11.5

    nonisolated static func == (lhs: ActivityRow, rhs: ActivityRow) -> Bool {
        lhs.facts == rhs.facts
    }

    var body: some View {
        let _ = ActivityCounters.rowBodyRan()
        HStack(alignment: .top, spacing: BanditoSpace.s3) {
            CrewAvatar(name: facts.agentName, look: facts.look, mood: facts.mood, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(facts.title)
                    .font(BanditoFont.display(size: titleSize, weight: 600))
                    .foregroundStyle(facts.isError ? Color.Bandito.danger : Color.Bandito.text)
                    .multilineTextAlignment(.leading)
                if let line = facts.line {
                    Text(line)
                        .font(BanditoFont.text(size: lineSize, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: BanditoSpace.s2)
            VStack(alignment: .trailing, spacing: 6) {
                Text(CrewTime.date(ms: facts.ts), format: CrewTime.style(ms: facts.ts))
                    .font(BanditoFont.text(size: timeSize, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize()
                if facts.isUnread {
                    Circle()
                        .fill(Color.Bandito.text)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, BanditoSpace.s1)
        .accessibilityElement(children: .combine)
        .accessibilityValue(facts.isUnread ? L10n.Ios.Crew.unread(count: 1) : "")
    }
}

/// The chat of an agent is not built yet: this screen holds the place of the entry, with the agent's name and the event's
/// id. Shown, it marks the chat read.
struct ActivityChatStub: View {
    let route: ActivityRoute
    let markRead: () -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s3) {
            Text(L10n.Ios.Activity.chatSoon(name: route.name, event: route.eventID))
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: markRead)
    }
}
