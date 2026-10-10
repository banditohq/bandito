#if os(macOS)
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The panes on screen, placed by the layout's cells. A pane in full screen covers the area and the others
/// are hidden, not removed, so their emulators keep running in view.
struct TerminalGrid: View {
    let controller: TerminalController
    let requestClose: (String) -> Void

    @Environment(AppModel.self) private var app
    private static let gap: CGFloat = 8

    var body: some View {
        let workspace = controller.workspace
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(workspace.onScreen, id: \.self) { id in
                    if let session = controller.session(for: id) {
                        let rect = rect(for: id, in: geometry.size, workspace: workspace)
                        let hidden = workspace.fullscreenID.map { $0 != id } ?? false
                        TerminalPaneView(
                            controller: controller, session: session,
                            isFocused: workspace.focusedID == id || workspace.onScreen.count == 1, requestClose: requestClose)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(hidden ? 0 : 1)
                            .allowsHitTesting(!hidden)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .banditoAnimation(BanditoMotion.ease, value: workspace.layout)
        .banditoAnimation(BanditoMotion.ease, value: workspace.fullscreenID)
        .banditoAnimation(BanditoMotion.ease, value: workspace.onScreen)
    }

    /// Where a pane goes: the whole area in full screen, else its layout cell, inset by half the gap.
    private func rect(for id: String, in size: CGSize, workspace: TerminalWorkspace) -> CGRect {
        let half = TerminalGrid.gap / 2
        let whole = CGRect(origin: .zero, size: size).insetBy(dx: half, dy: half)
        if workspace.fullscreenID == id { return whole }
        guard let index = workspace.onScreen.firstIndex(of: id), index < workspace.layout.capacity else {
            return whole
        }
        let cell = workspace.layout.cells[index]
        return CGRect(
            x: cell.x * size.width, y: cell.y * size.height,
            width: cell.width * size.width, height: cell.height * size.height
        ).insetBy(dx: half, dy: half)
    }
}

/// One pane: the header, the emulator, and the strips for an ended process or an error.
struct TerminalPaneView: View {
    let controller: TerminalController
    let session: TerminalSession
    let isFocused: Bool
    let requestClose: (String) -> Void
    /// Inside the workbench panel the tab is the header (name, folder, close in its menu): no header of its own.
    var compact = false

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                PaneHeader(controller: controller, session: session, requestClose: requestClose)
            }
            ZStack(alignment: .bottom) {
                TerminalPane(view: session.view, fontSize: app.terminalFont.size)
                    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
                if let message = session.errorMessage {
                    UserFacingErrorView(message: message)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: 0x12100E).opacity(0.94))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                if let exit = session.exit {
                    ExitStrip(text: TerminalSession.exitDescription(exit)) {
                        Task { await controller.restart(session.id) }
                    }
                }
            }
        }
        .background(Color(hex: 0x0B0A09))
        // The pane that has the keys is not outlined: the others are dimmed a little, as in iTerm or Warp.
        .overlay {
            Color.black.opacity(isFocused ? 0 : 0.22)
                .allowsHitTesting(false)
                .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: isFocused)
        }
        // In the side panel the terminal fills its tab, edge to edge; in the grid each pane is a quiet card.
        .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 10, style: .continuous))
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.Bandito.text.opacity(0.06), lineWidth: 1)
            }
        }
    }
}

/// 36 pt: status dot, name (double-click to rename), folder, and the pane's buttons.
/// A pinch on the header goes full screen (outward) or back to the grid (inward).
struct PaneHeader: View {
    let controller: TerminalController
    let session: TerminalSession
    let requestClose: (String) -> Void

    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let id = session.id
        let isFull = controller.workspace.fullscreenID == id
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            if renaming {
                TextField(L10n.Terminals.rename, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: 180)
                    .focused($nameFocused)
                    .onSubmit { commitRename(id) }
                    .onExitCommand { renaming = false }
            } else {
                Text(controller.displayTitle(id) ?? session.info.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startRename() }
                    .help(L10n.Terminals.Pane.rename)
            }
            Text(session.info.cwd)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            headerButton("rectangle.split.2x1", help: L10n.Terminals.Pane.split) {
                controller.workspace.focus(id)
                Task { await controller.openNew(cwd: session.info.cwd, afterFocused: true) }
            }
            headerButton("minus", help: L10n.Terminals.Pane.collapse) {
                controller.collapse(id)
            }
            headerButton(
                isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: isFull ? L10n.Terminals.Pane.exitFullscreen : L10n.Terminals.Pane.fullscreen
            ) {
                controller.workspace.toggleFullscreen(id)
            }
            headerButton("xmark", help: L10n.Terminals.Pane.close) {
                requestClose(id)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(Color(hex: 0x1C1815).opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture().onEnded { value in
                if value.magnification > 1.12, !isFull {
                    controller.workspace.toggleFullscreen(id)
                } else if value.magnification < 0.9, isFull {
                    controller.workspace.exitFullscreen()
                }
            }
        )
    }

    private var statusColor: Color {
        if session.exit != nil { return BanditoPalette.idle }
        return session.isAttached ? Color.Bandito.ok : Color.Bandito.text3
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
        .foregroundStyle(Color.Bandito.text3)
        .help(help)
    }

    private func startRename() {
        draft = session.info.title
        renaming = true
        nameFocused = true
    }

    private func commitRename(_ id: String) {
        renaming = false
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != session.info.title else { return }
        Task { await controller.rename(id, to: title) }
    }
}

/// Bottom strip of an ended terminal: how it ended, and a restart.
struct ExitStrip: View {
    let text: String
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text2)
            Spacer(minLength: 8)
            Button(L10n.Terminals.restart, action: restart)
                .banditoButton(.quiet(size: .regular))
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Color(hex: 0x12100E).opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }
}
#endif
