#if os(macOS)
import BanditoDesign
import BanditoL10n
import SwiftUI

/// The dock at the bottom: collapsed terminals as cards. Each shows its live state, a sparkline of output
/// over the last minute, and "Restore". Refreshed once a second so the sparklines and the waiting badge move.
struct TerminalDock: View {
    let controller: TerminalController
    @Environment(Keymap.self) private var keymap

    var body: some View {
        let workspace = controller.workspace
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                SectionLabel(L10n.Terminals.Dock.title)
                    .fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if workspace.collapsed.isEmpty {
                            Text(L10n.Terminals.Dock.empty)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.Bandito.text3)
                        }
                        ForEach(workspace.collapsed, id: \.id) { entry in
                            DockCard(
                                entry: entry,
                                session: controller.session(for: entry.id),
                                now: context.date,
                                restore: { controller.restore(entry.id) })
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if let shortcut = keymap.binding(for: "terminals.restoreCollapsed")?.symbols {
                    Text(L10n.Terminals.Dock.lastHint(shortcut: shortcut))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 64)
            .background(Color(hex: 0x12100E))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
            }
        }
    }
}

/// One collapsed terminal. A waiting prompt is highlighted in orange.
struct DockCard: View {
    let entry: TerminalWorkspace.Collapsed
    let session: TerminalSession?
    let now: Date
    let restore: () -> Void

    var body: some View {
        let activity = session?.activity ?? TerminalActivity()
        let waiting = session?.exit == nil && activity.isWaitingForInput(now: now)
        Button(action: restore) {
            HStack(spacing: 10) {
                if waiting {
                    PulsingDot(size: 8)
                } else {
                    Circle()
                        .fill(session?.exit == nil ? Color.Bandito.ok : BanditoPalette.idle)
                        .frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session?.info.title ?? entry.id)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(subtitle(activity: activity, waiting: waiting))
                        .font(.system(size: 11))
                        .foregroundStyle(waiting ? BanditoPalette.peach : Color.Bandito.text3)
                        .lineLimit(1)
                }
                TerminalSparkline(
                    values: activity.sparkline(now: now),
                    color: waiting ? Color.Bandito.signal : Color.Bandito.ok
                )
                .frame(width: 56, height: 22)
                Text(L10n.Terminals.Dock.restore)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(BanditoPalette.peach)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                waiting ? Color.Bandito.signal.opacity(0.07) : Color.Bandito.text.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(waiting ? Color.Bandito.signal.opacity(0.35) : Color.Bandito.text.opacity(0.08))
            )
        }
        .banditoButton(.row(cornerRadius: 12))
        .help(L10n.Terminals.Dock.restore)
    }

    private func subtitle(activity: TerminalActivity, waiting: Bool) -> String {
        if let exit = session?.exit {
            return TerminalSession.exitDescription(exit)
        }
        if waiting {
            return L10n.Terminals.Dock.waiting
        }
        if let base = entry.lines {
            let since = max(0, activity.lines - base)
            return "\(L10n.Terminals.Dock.running) · \(L10n.Terminals.Dock.lines(count: since))"
        }
        return L10n.Terminals.Dock.running
    }
}

/// Orange dot that breathes, for "waiting for input". Still when Reduce Motion is on.
struct PulsingDot: View {
    let size: CGFloat
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// Repeating motion stands still: Reduce Motion, or "Less" / "Off" in settings.
    private var still: Bool { reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion }

    var body: some View {
        Circle()
            .fill(Color.Bandito.signal)
            .frame(width: size, height: size)
            .shadow(color: Color.Bandito.signal.opacity(0.7), radius: 4)
            .scaleEffect(expanded ? 1.25 : 1)
            .opacity(expanded ? 0.75 : 1)
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    expanded = true
                }
            }
    }
}

/// Line of values over time, scaled to the largest value. A flat line at the bottom when nothing was printed.
struct TerminalSparkline: View {
    let values: [Int]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let peak = Double(max(values.max() ?? 0, 1))
            let steps = max(values.count - 1, 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(steps)
                let y = size.height - 1 - (size.height - 2) * CGFloat(Double(value) / peak)
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(
                path, with: .color(color),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
#endif
