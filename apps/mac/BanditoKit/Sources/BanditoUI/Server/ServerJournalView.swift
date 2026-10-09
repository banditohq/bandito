import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Journal: the daemon's own log, newest line last. A level filter, refresh, copy all, and it follows the end.
struct ServerJournalView: View {
    let server: ServerModel?
    @State private var level: DaemonLogLevel = .info
    @State private var log: DaemonLog?
    @State private var error: UserFacingMessage?
    @State private var loading = false

    /// How many lines one read asks for. The daemon allows up to 2000.
    private static let lineCount = 500

    var body: some View {
        ServerPage(
            title: L10n.Mode.serverJournal,
            trailing: {
                if let server, server.supports("logs") {
                    HStack(spacing: 10) {
                        SegmentedPicker(
                            selection: $level,
                            options: [
                                (DaemonLogLevel.info, L10n.Journal.levelAll),
                                (DaemonLogLevel.warn, L10n.Journal.levelWarn),
                                (DaemonLogLevel.error, L10n.Journal.levelError),
                            ]
                        )
                        .frame(width: 300)
                        Button(L10n.Journal.refresh) { reload() }
                            .banditoButton(.quiet())
                            .disabled(loading)
                        Button(L10n.Journal.copyAll) {
                            SystemActions.copy((log?.lines ?? []).joined(separator: "\n"))
                        }
                        .banditoButton(.quiet())
                        .disabled((log?.lines ?? []).isEmpty)
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

    @ViewBuilder
    private var logBody: some View {
        let lines = log?.lines ?? []
        if log == nil {
            Text(loading ? L10n.Journal.loading : L10n.Journal.empty)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text3)
        } else if lines.isEmpty {
            Text(L10n.Journal.empty)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text3)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(BanditoFont.font(size: 12, weight: 400, mono: true))
                                .foregroundStyle(Color.Bandito.text2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 460)
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                .onChange(of: lines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            Text(L10n.Journal.source(name: log?.source ?? ""))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    private func reload() {
        guard let server, server.supports("logs") else { return }
        loading = true
        Task {
            do {
                log = try await server.daemonLog(lines: Self.lineCount, level: level)
                error = nil
            } catch {
                self.error = UserFacingError.message(for: error)
            }
            loading = false
        }
    }
}
