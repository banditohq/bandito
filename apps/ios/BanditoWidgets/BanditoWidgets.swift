import ActivityKit
import BanditoDesign
import BanditoL10n
import SwiftUI
import WidgetKit

// The Bandito widgets: the Inbox count (home small, lock screen circular and rectangular) and the crew (home medium).
// The provider reads the snapshot the app wrote in the App Group; it asks for nothing from the network.

@main
struct BanditoWidgetBundle: WidgetBundle {
    var body: some Widget {
        InboxWidget()
        CrewWidget()
        TurnActivityWidget()
    }
}

/// One moment of a widget: the snapshot as it was when the app last wrote it (nil before the first write).
struct BanditoEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Reads the snapshot. Asks again in half an hour at most: the app reloads the timelines when it writes.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> BanditoEntry {
        BanditoEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (BanditoEntry) -> Void) {
        completion(entry(now: Date(), preview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BanditoEntry>) -> Void) {
        let now = Date()
        let timeline = Timeline(
            entries: [entry(now: now, preview: context.isPreview)],
            policy: .after(now.addingTimeInterval(30 * 60)))
        completion(timeline)
    }

    /// The gallery shows the sample; the home screen shows the file. A missing file is the placeholder (nil).
    private func entry(now: Date, preview: Bool) -> BanditoEntry {
        let snapshot = preview ? WidgetSnapshot.sample : WidgetSnapshotStore.appGroup()?.read()
        return BanditoEntry(date: now, snapshot: snapshot)
    }
}

struct InboxWidget: Widget {
    let kind = "dev.bandito.ios.widget.inbox"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            InboxEntryView(entry: entry)
        }
        .configurationDisplayName(L10n.Ios.Widget.Inbox.name)
        .description(L10n.Ios.Widget.Inbox.desc)
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct CrewWidget: Widget {
    let kind = "dev.bandito.ios.widget.crew"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            CrewEntryView(entry: entry)
        }
        .configurationDisplayName(L10n.Ios.Widget.Crew.name)
        .description(L10n.Ios.Widget.Crew.desc)
        .supportedFamilies([.systemMedium])
    }
}

private struct InboxEntryView: View {
    let entry: BanditoEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        InboxWidgetView(snapshot: entry.snapshot, family: family)
            .containerBackground(for: .widget) {
                if family == .systemSmall { WidgetBackdrop() } else { Color.Bandito.bg }
            }
    }
}

private struct CrewEntryView: View {
    let entry: BanditoEntry

    var body: some View {
        CrewWidgetView(snapshot: entry.snapshot)
            .containerBackground(Color.Bandito.bg, for: .widget)
    }
}

/// The Live Activity of a long turn: the lock screen card and the Dynamic Island. The app starts and updates it.
struct TurnActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.Bandito.bg)
                .activitySystemActionForegroundColor(Color.Bandito.text)
                .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnAvatar(attributes: context.attributes, phase: context.state.phase, size: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    TurnTitle(attributes: context.attributes, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TurnTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .running {
                        TurnStopButton(attributes: context.attributes)
                    }
                }
            } compactLeading: {
                TurnAvatar(attributes: context.attributes, phase: context.state.phase, size: 22)
            } compactTrailing: {
                TurnTrailing(state: context.state, fontSize: 13)
                    .frame(maxWidth: 52)
            } minimal: {
                TurnAvatar(attributes: context.attributes, phase: context.state.phase, size: 22)
            }
            .keylineTint(Color.Bandito.signal)
            .widgetURL(context.attributes.link)
        }
    }
}
