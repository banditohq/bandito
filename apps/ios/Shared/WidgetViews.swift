import BanditoDesign
import BanditoL10n
import SwiftUI
import WidgetKit

// The widgets' pictures. Shared by the widget extension and the app (the tests render them with `ImageRenderer`). They
// draw only from a `WidgetSnapshot`; no network, no state. The extension sets the container background and the links'
// fallback; these views carry no background of their own.

extension WidgetStatus {
    var label: String {
        switch self {
        case .idle: L10n.Ios.Widget.Status.idle
        case .working: L10n.Ios.Widget.Status.working
        case .needsYou: L10n.Ios.Widget.Status.needsYou
        case .error: L10n.Ios.Widget.Status.error
        case .offline: L10n.Ios.Widget.Status.offline
        }
    }

    /// The status color: the brand's signal for a person's wait, info for work, danger for a failure.
    var tint: Color {
        switch self {
        case .needsYou: Color.Bandito.signal
        case .working: Color.Bandito.info
        case .error: Color.Bandito.danger
        case .idle: Color.Bandito.ok
        case .offline: Color.Bandito.text3
        }
    }
}

extension WidgetMood {
    var avatarMood: AvatarMood {
        switch self {
        case .idle: .idle
        case .working: .working
        case .needsYou: .needsYou
        case .thinking: .thinking
        case .error: .error
        case .sleeping: .sleeping
        }
    }
}

/// A raccoon at rest in its mood, tinted by the status. Widgets do not animate: the pose is the one at time zero.
struct WidgetRaccoon: View {
    let name: String
    let mood: AvatarMood
    let tint: Color
    let size: CGFloat

    var body: some View {
        RaccoonFace(
            resolved: AvatarResolver.resolve(name: name, color: nil, face: .auto),
            tint: tint,
            pose: AvatarPose.make(mood: mood, time: 0, phase: AvatarPose.phase(for: name), reduceMotion: true),
            size: size)
            .accessibilityHidden(true)
    }
}

/// The background of the small widget: the brand's ground with a soft signal glow from the top-left corner (cream and
/// warm in the light theme, the glow is lower there).
struct WidgetBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.Bandito.bg
            RadialGradient(
                colors: [
                    Color.Bandito.signal.opacity(colorScheme == .dark ? 0.24 : 0.14),
                    Color.Bandito.signal.opacity(0),
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 190)
        }
    }
}

/// The waiting agents as overlapping raccoons (the crew widget's faces, at 30 points), each on a ring of the ground's
/// color so the overlap reads as a stack.
struct WaitingAvatars: View {
    let agents: [WidgetSnapshot.Agent]

    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(agents.prefix(WidgetSnapshot.waitingLimit).enumerated()), id: \.offset) { _, agent in
                WidgetRaccoon(name: agent.name, mood: agent.mood.avatarMood, tint: agent.status.tint, size: 30)
                    .padding(2)
                    .background(Circle().fill(Color.Bandito.bg))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The sleeping raccoon of the empty widget: the head of the logo drawn as its lights, the eyes shut, a small "z".
struct SleepingRaccoon: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                guard let sample = RaccoonHead.sample() else { return }
                let box = sample.box
                let scale = min(size.width / box.width, size.height / box.height)
                let offsetX = (size.width - box.width * scale) / 2 - box.minX * scale
                let offsetY = (size.height - box.height * scale) / 2 - box.minY * scale
                func map(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: point.x * scale + offsetX, y: point.y * scale + offsetY)
                }
                let light = RaccoonHead.gridStep * scale * 0.42
                for point in sample.head {
                    let centre = map(point)
                    context.fill(
                        Path(ellipseIn: CGRect(x: centre.x - light, y: centre.y - light, width: light * 2, height: light * 2)),
                        with: .color(Color.Bandito.signal))
                }
                // Shut eyes: one dash per eye, as long as the eye's lights.
                for (index, points) in sample.eyes.enumerated() where !points.isEmpty && index < sample.eyeCentres.count {
                    let left = points.reduce(CGFloat.greatestFiniteMagnitude) { min($0, $1.x) }
                    let right = points.reduce(-CGFloat.greatestFiniteMagnitude) { max($0, $1.x) }
                    let y = sample.eyeCentres[index].y
                    var dash = Path()
                    dash.move(to: map(CGPoint(x: left, y: y)))
                    dash.addLine(to: map(CGPoint(x: right, y: y)))
                    context.stroke(dash, with: .color(Color.Bandito.text), style: StrokeStyle(lineWidth: light * 1.4, lineCap: .round))
                }
            }
            Text("z")
                .font(BanditoFont.display(size: 15, weight: 700))
                .foregroundStyle(Color.Bandito.signal)
                .offset(x: 6, y: -2)
        }
        .accessibilityHidden(true)
    }
}

/// The Inbox widget. Small: the count in signal, its caption, the waiting raccoons and their names; with nothing
/// waiting, the sleeping raccoon and "All quiet". Lock screen: the count (circular) and the count with the working agent
/// (rectangular). No snapshot yet: the placeholder.
struct InboxWidgetView: View {
    let snapshot: WidgetSnapshot?
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            default:
                small
            }
        }
        .widgetURL(BanditoLink.inbox.url)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot {
                if snapshot.pending > 0 {
                    Text("\(snapshot.pending)")
                        .font(BanditoFont.display(size: 40, weight: 700))
                        .foregroundStyle(Color.Bandito.signal)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(L10n.Ios.Widget.waitingTitle)
                        .font(BanditoFont.display(size: 11, weight: 600))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if !snapshot.waiting.isEmpty {
                        WaitingAvatars(agents: snapshot.waiting)
                    }
                    if let line = waitingLine(snapshot) {
                        Text(line)
                            .font(BanditoFont.text(size: 12, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .padding(.top, 6)
                    }
                } else {
                    Spacer(minLength: 0)
                    SleepingRaccoon()
                        .frame(width: 70, height: 70)
                    Text(L10n.Ios.Widget.allQuiet)
                        .font(BanditoFont.display(size: 14, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                }
            } else {
                Text(L10n.Ios.Widget.open)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
    }

    /// "Forge, Watch", or "Forge, Watch и ещё 1" when more wait than the line names; nil when nobody is named.
    private func waitingLine(_ snapshot: WidgetSnapshot) -> String? {
        let names = snapshot.waitingNames.joined(separator: ", ")
        guard !names.isEmpty else { return nil }
        return snapshot.waitingMore > 0 ? L10n.Ios.Widget.more(names: names, count: snapshot.waitingMore) : names
    }

    private var circular: some View {
        Text(snapshot.map { "\($0.pending)" } ?? "–")
            .font(BanditoFont.display(size: 22, weight: 700))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .widgetAccentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rectangular: some View {
        let waiting: String
        let working: String?
        if let snapshot {
            waiting = snapshot.pending > 0 ? L10n.Ios.Widget.Lock.waiting(count: snapshot.pending) : L10n.Ios.Widget.allQuiet
            working = snapshot.agents.first { $0.status == .working }.map { L10n.Ios.Widget.Lock.working(name: $0.name) }
        } else {
            waiting = L10n.Ios.Widget.open
            working = nil
        }
        return Text(working.map { "\(waiting) · \($0)" } ?? waiting)
            .font(BanditoFont.text(size: 13, weight: 500))
            .lineLimit(2)
            .widgetAccentable()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Crew widget: up to four agents in two columns, each a raccoon with its status. A tap on an agent opens it; a tap
/// on the rest opens the Crew (the links are set by the widget's entry view).
struct CrewWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Ios.Widget.Crew.name)
                .font(BanditoFont.display(size: 12, weight: 600))
                .foregroundStyle(Color.Bandito.text2)
            if let snapshot {
                if snapshot.agents.isEmpty {
                    Text(L10n.Ios.Crew.emptyTitle)
                        .font(BanditoFont.text(size: 13, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                } else {
                    let picked = WidgetAgentPicker.pick(snapshot.agents)
                    HStack(alignment: .top, spacing: 14) {
                        column(Array(picked.prefix(2)))
                        column(Array(picked.dropFirst(2)))
                    }
                }
            } else {
                Text(L10n.Ios.Widget.open)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .widgetURL(BanditoLink.crew.url)
    }

    private func column(_ agents: [WidgetSnapshot.Agent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(agents, id: \.id) { agent in
                Link(destination: BanditoLink.agent(server: agent.server, id: agent.id).url) {
                    AgentCell(agent: agent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One agent in the Crew widget: the raccoon, the name, the status word in its color.
private struct AgentCell: View {
    let agent: WidgetSnapshot.Agent

    var body: some View {
        HStack(spacing: 8) {
            WidgetRaccoon(name: agent.name, mood: agent.mood.avatarMood, tint: agent.status.tint, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(BanditoFont.display(size: 12, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(agent.status.label)
                    .font(BanditoFont.text(size: 11))
                    .foregroundStyle(agent.status.tint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
