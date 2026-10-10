#if os(macOS)
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Terminals sidebar: what is on screen, what is collapsed (still running), and the reminder that collapsing
/// is not closing. The agents section comes when the server reports agent terminals; it is hidden until then.
struct TerminalsSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.currentServer == nil {
            SidebarPlaceholder(mode: .terminals)
        } else if let server = app.currentServer, server.supports("terminals") {
            TerminalsSidebarList(controller: app.terminalController(for: server))
        } else {
            Text(L10n.Terminals.updateServer)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Bandito.surface1)
        }
    }
}

private struct TerminalsSidebarList: View {
    let controller: TerminalController
    @Environment(Router.self) private var router
    /// The "collapse is not close" reminder, closed once for good.
    @AppStorage("terminals.sidebarHintClosed") private var hintClosed = false

    var body: some View {
        let workspace = controller.workspace
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        // The section has its own "+", like the tabs of the browser. With no terminals the main area
                        // says so; the list itself stays silent.
                        HStack(spacing: 6) {
                            SectionLabel(L10n.Mode.terminals)
                            Spacer(minLength: 6)
                            Button {
                                Task { await controller.openNew(cwd: nil, afterFocused: false) }
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .banditoButton(.icon(size: 22, label: L10n.Keys.newTerminal))
                            .focusable(false)
                            .help(L10n.Keys.newTerminal)
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                        if !workspace.onScreen.isEmpty {
                            SectionLabel(L10n.Terminals.Sidebar.onScreen)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(workspace.onScreen, id: \.self) { id in
                                row(id: id, collapsed: nil, now: context.date)
                            }
                        }
                        if !workspace.collapsed.isEmpty {
                            HStack(alignment: .firstTextBaseline) {
                                SectionLabel(L10n.Terminals.Sidebar.collapsed)
                                Spacer(minLength: 6)
                                Text(L10n.Terminals.Sidebar.collapsedHint)
                                    .font(BanditoFont.text(size: 11, weight: 400))
                                    .foregroundStyle(Color.Bandito.text3)
                            }
                            .padding(.horizontal, 10)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            ForEach(workspace.collapsed, id: \.id) { entry in
                                row(id: entry.id, collapsed: entry, now: context.date)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            if !hintClosed {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Terminals.Sidebar.noteTitle)
                            .font(BanditoFont.text(size: 12, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        Text(L10n.Terminals.Sidebar.noteBody)
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineSpacing(2)
                    }
                    Spacer(minLength: 0)
                    Button {
                        hintClosed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .banditoButton(.icon(size: 20, label: L10n.Common.close))
                    .help(L10n.Common.close)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.Bandito.text.opacity(0.06))
                )
                .padding(14)
            }
        }
    }

    /// One terminal. On screen, a click focuses it; collapsed, a click brings it back.
    @ViewBuilder
    private func row(id: String, collapsed entry: TerminalWorkspace.Collapsed?, now: Date) -> some View {
        let session = controller.session(for: id)
        let focused = entry == nil && controller.workspace.focusedID == id
        let waiting = entry != nil && session?.exit == nil && (session?.activity.isWaitingForInput(now: now) ?? false)
        Button {
            if entry != nil {
                controller.restore(id)
            } else {
                controller.workspace.focus(id)
                router.terminalID = id
            }
        } label: {
            HStack(spacing: 10) {
                if waiting {
                    PulsingDot(size: 7)
                } else {
                    Circle()
                        .fill(session?.exit == nil ? Color.Bandito.ok : BanditoPalette.idle)
                        .frame(width: 7, height: 7)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.displayTitle(id) ?? id)
                        .font(BanditoFont.text(size: 13, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(session?.info.cwd ?? "")
                        .font(BanditoFont.mono(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if entry != nil {
                    badge(waiting: waiting, entry: entry, session: session)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                focused ? Color.Bandito.text.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .banditoButton(.row(cornerRadius: 10))
    }

    @ViewBuilder
    private func badge(waiting: Bool, entry: TerminalWorkspace.Collapsed?, session: TerminalSession?) -> some View {
        if waiting {
            Text(L10n.Terminals.Dock.waiting)
                .font(BanditoFont.text(size: 10.5, weight: 600))
                .foregroundStyle(BanditoPalette.peach)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.Bandito.signal.opacity(0.13), in: Capsule())
        } else if let base = entry?.lines, let activity = session?.activity, activity.lines > base {
            Text(L10n.Terminals.Dock.lines(count: activity.lines - base))
                .font(BanditoFont.text(size: 10.5, weight: 600))
                .foregroundStyle(Color.Bandito.text2)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.Bandito.text.opacity(0.07), in: Capsule())
        }
    }
}
#else
import SwiftUI

/// Terminals need the Mac app's terminal emulator; elsewhere the mode shows its placeholder.
struct TerminalsSidebar: View {
    var body: some View {
        SidebarPlaceholder(mode: .terminals)
    }
}
#endif
