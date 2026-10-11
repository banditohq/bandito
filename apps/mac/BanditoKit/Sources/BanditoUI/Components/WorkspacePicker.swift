import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The workplace picker of the Browser and Terminals sidebars (and the base of the Screen's cards): the shared server
/// and every container, each with its state, and "Запустить" for a stopped container. It shows nothing when the server
/// has only the shared workplace. Rows are `Equatable`, so a poll that changes nothing a row shows redraws nothing.
struct WorkspacePicker: View {
    let selection: WorkspaceSelection

    var body: some View {
        let directory = selection.directory
        let rows = WorkspacePickerLogic.rows(
            workspaces: directory.workspaces, selectedID: selection.selectedID, busyID: directory.busyID)
        if rows.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(L10n.Inspector.workplace)
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                ForEach(rows) { row in
                    WorkspacePickerRow(
                        row: row,
                        onSelect: { selection.select(row.id) },
                        onStart: { Task { await directory.start(row.id) } }
                    )
                    .equatable()
                }
                if let error = directory.errorText {
                    UserFacingErrorView(message: error)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// One row: the icon (house for the shared server, box for a container), the name, the state, and the start button.
struct WorkspacePickerRow: View, Equatable {
    let row: WorkspacePickerLogic.Row
    let onSelect: () -> Void
    let onStart: () -> Void

    nonisolated static func == (lhs: WorkspacePickerRow, rhs: WorkspacePickerRow) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    WorkspaceGlyph(isContainer: row.isContainer, tint: row.selected ? Color.Bandito.signal : Color.Bandito.text2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(BanditoFont.text(size: 13, weight: row.selected ? 600 : 500))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            Circle().fill(WorkspaceStateText.color(row.live)).frame(width: 6, height: 6)
                            Text(row.busy ? L10n.Workspace.Picker.starting : WorkspaceStateText.text(row.live))
                                .font(BanditoFont.text(size: 11.5, weight: 400))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 11))
            .accessibilityAddTraits(row.selected ? .isSelected : [])

            if row.canStart {
                Button(L10n.Workspace.Action.start, action: onStart)
                    .banditoButton(.quiet())
                    .disabled(row.busy)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            row.selected ? Color.Bandito.signal.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11))
    }
}

/// The icon of a workplace: a house for the shared server, a box for a container.
struct WorkspaceGlyph: View {
    let isContainer: Bool
    var tint: Color = Color.Bandito.text2

    var body: some View {
        Image(systemName: isContainer ? "shippingbox" : "house")
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

/// The words and the colour of a workplace's state.
enum WorkspaceStateText {
    static func text(_ state: WorkspaceLiveState) -> String {
        switch state {
        case .serverRunning: L10n.Workspace.Picker.onServer
        case .containerRunning: L10n.Workspace.Status.running
        case .containerStopped: L10n.Workspace.Status.stopped
        case .unavailable: L10n.Workspace.Status.dockerError
        }
    }

    static func color(_ state: WorkspaceLiveState) -> Color {
        switch state {
        case .serverRunning, .containerRunning: Color.Bandito.ok
        case .containerStopped: BanditoPalette.idle
        case .unavailable: Color.Bandito.danger
        }
    }
}

/// The name of the workplace a terminal or an agent runs in, as a small label. Shown only for a container: the shared
/// server needs none.
struct WorkspaceChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.text(size: 10.5, weight: 600))
            .foregroundStyle(Color.Bandito.info)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Color.Bandito.info.opacity(0.12), in: Capsule())
    }
}
