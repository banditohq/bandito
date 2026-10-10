import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Journal: the daemon's own log, newest line last. A level filter, refresh, copy all, and it follows the end.
/// Runs of identical lines are shown once with a count.
struct ServerJournalView: View {
    let server: ServerModel?
    @State private var level: DaemonLogLevel = .info
    @State private var log: DaemonLog?
    @State private var entries: [JournalEntry] = []
    @State private var error: UserFacingMessage?
    @State private var loading = false

    /// How many lines one read asks for. The daemon allows up to 2000.
    private static let lineCount = 500

    var body: some View {
        ServerPage(
            title: L10n.Mode.serverJournal,
            trailing: {
                if let server, server.supports("logs") {
                    // Icons with hints on a narrow window, icons with words when there is room.
                    ViewThatFits(in: .horizontal) {
                        toolbar(iconsOnly: false)
                        toolbar(iconsOnly: true)
                    }
                }
            }
        ) {
            if let server, server.supports("logs") {
                if let error {
                    UserFacingErrorView(message: error)
                }
                ServerCard {
                    logBody
                }
            } else {
                Text(L10n.Journal.needsNewer)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
            }
        }
        .onAppear { reload() }
        .onChange(of: level) { _, _ in reload() }
        .onChange(of: server?.id) { _, _ in reload() }
    }

    private func toolbar(iconsOnly: Bool) -> some View {
        HStack(spacing: 8) {
            SegmentedPicker(
                selection: $level,
                options: [
                    (DaemonLogLevel.info, L10n.Journal.levelAll),
                    (DaemonLogLevel.warn, L10n.Journal.levelWarn),
                    (DaemonLogLevel.error, L10n.Journal.levelError),
                ]
            )
            .fixedSize()
            if iconsOnly {
                Button { reload() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .banditoButton(.icon(label: L10n.Journal.refresh))
                .help(L10n.Journal.refresh)
                .disabled(loading)
                Button { copyAll() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .banditoButton(.icon(label: L10n.Journal.copyAll))
                .help(L10n.Journal.copyAll)
                .disabled(entries.isEmpty)
            } else {
                Button { reload() } label: {
                    Label(L10n.Journal.refresh, systemImage: "arrow.clockwise")
                }
                .banditoButton(.quiet())
                .fixedSize()
                .help(L10n.Journal.refresh)
                .disabled(loading)
                Button { copyAll() } label: {
                    Label(L10n.Journal.copyAll, systemImage: "doc.on.doc")
                }
                .banditoButton(.quiet())
                .fixedSize()
                .help(L10n.Journal.copyAll)
                .disabled(entries.isEmpty)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var logBody: some View {
        if log == nil {
            Text(loading ? L10n.Journal.loading : L10n.Journal.empty)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text3)
        } else if entries.isEmpty {
            Text(L10n.Journal.empty)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text3)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            row(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 460)
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: entries.last?.id) { _, _ in scrollToEnd(proxy) }
            }
            Text(sourceText)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    private func row(_ entry: JournalEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.line.time ?? "")
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 62, alignment: .leading)
            Group {
                if let level = entry.line.level {
                    Text(level.rawValue)
                        .font(BanditoFont.font(size: 10.5, weight: 600, mono: true))
                        .foregroundStyle(Self.color(for: level))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Self.color(for: level).opacity(0.14), in: Capsule())
                }
            }
            .fixedSize()
            .frame(width: 58, alignment: .leading)
            Text(entry.line.module ?? "")
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(entry.line.message)
                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.repeats > 1 {
                Text(verbatim: "×\(entry.repeats)")
                    .font(BanditoFont.font(size: 11.5, weight: 600))
                    .monospacedDigit()
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private static func color(for level: JournalLine.Level) -> Color {
        switch level {
        case .error: Color.Bandito.danger
        // The warm highlight of the palette: the warning colour of the journal.
        case .warn: BanditoPalette.peach
        case .info: Color.Bandito.info
        case .debug, .trace: Color.Bandito.text3
        }
    }

    private var sourceText: String {
        log?.source == "journald" ? L10n.Journal.sourceJournald : L10n.Journal.sourceFile
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard let last = entries.last?.id else { return }
        proxy.scrollTo(last, anchor: .bottom)
    }

    private func copyAll() {
        SystemActions.copy((log?.lines ?? []).joined(separator: "\n"))
    }

    private func reload() {
        guard let server, server.supports("logs") else { return }
        loading = true
        Task {
            do {
                let fetched = try await server.daemonLog(lines: Self.lineCount, level: level)
                log = fetched
                entries = JournalEntry.collapsed(fetched.lines)
                error = nil
            } catch {
                self.error = UserFacingError.message(for: error)
            }
            loading = false
        }
    }
}
