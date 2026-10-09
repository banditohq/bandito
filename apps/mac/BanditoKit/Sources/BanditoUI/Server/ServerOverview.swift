import BanditoDesign
import BanditoKit
import BanditoL10n
import Charts
import SwiftUI

/// Server → Overview: health, four metrics with history, who uses the most, ports, secrets and capabilities.
struct ServerOverview: View {
    let server: ServerModel?
    @Environment(Router.self) private var router
    @State private var monitor = HostMonitor()
    @State private var setup = SetupModel()
    @State private var release = ReleaseStatus()
    @State private var daemonUpdate = DaemonUpdateModel()
    @State private var secrets: [SecretInfo] = []
    @State private var stopping: ProcessRow?
    @State private var actionError: UserFacingMessage?
    /// The metric whose detail is open, if any.
    @State private var detail: OverviewMetric?
    /// Two columns of cards or one. Starts narrow; changes only when the measured page width crosses the threshold.
    @State private var isWide = false

    var body: some View {
        ServerPage(title: L10n.Mode.serverOverview, trailing: { trailing }) {
            if let server, server.supports("host") {
                // The daemon's own check wins; the GitHub hint is only for a daemon that has not reported one yet.
                if daemonUpdate.shownOffer(current: DaemonUpdateOffer.offer(for: server.info), serverID: server.id) != nil {
                    DaemonUpdateBanner(server: server, model: daemonUpdate)
                } else if release.updateAvailable(current: server.info?.version) {
                    updateBanner(server)
                }
                tiles
                if let error = monitor.error {
                    UserFacingErrorView(message: error)
                }
                if isWide {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            processesCard(server)
                            featuresCard(server)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(spacing: 12) {
                            portsCard
                            secretsCard(server)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    VStack(spacing: 12) {
                        processesCard(server)
                        featuresCard(server)
                        portsCard
                        secretsCard(server)
                    }
                }
            } else {
                ServerUnavailable(server: server)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PageWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(PageWidthKey.self) { width in
            let wide = Self.isTwoColumns(width: width)
            if wide != isWide { isWide = wide }
        }
        .task(id: server?.id) {
            guard let server else { return }
            await monitor.run(server)
        }
        .task(id: server?.id) {
            // Opening the Server screen re-reads the daemon's update check, so the offer is current.
            await server?.refreshInfo()
        }
        .task(id: server?.info != nil) {
            guard let server, server.info != nil else { return }
            await loadExtras(server)
        }
        .confirmationDialog(
            stopTitle,
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { row in
            Button(L10n.Server.Processes.stopConfirm, role: .destructive) {
                if let server { stop(row, server: server) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { row in
            Text(L10n.Server.Processes.stopMessage)
        }
    }

    // MARK: - Header

    private var trailing: some View {
        HStack(spacing: 10) {
            if let stats = monitor.stats {
                let health = HostHealth.evaluate(stats)
                Chip(text: Self.healthText(health), tone: health.isOK ? .ok : .signal)
            }
            SegmentedPicker(
                selection: Binding(
                    get: { monitor.range },
                    set: { range in
                        guard let server else { return }
                        Task { await monitor.setRange(range, server: server) }
                    }),
                options: [(HostHistoryRange.hour, L10n.Server.range1h), (HostHistoryRange.day, L10n.Server.range24h)])
            .fixedSize()
        }
        .fixedSize()
    }

    /// Page width from which the cards sit in two columns; narrower pages stack them in one.
    static let twoColumnsMinWidth: CGFloat = 1000

    static func isTwoColumns(width: CGFloat) -> Bool {
        width >= twoColumnsMinWidth
    }

    static func healthText(_ health: HostHealth) -> String {
        switch (health.diskFull, health.memoryFull) {
        case (false, false): L10n.Server.Health.ok
        case (true, false): L10n.Server.Health.diskFull
        case (false, true): L10n.Server.Health.memoryFull
        case (true, true): L10n.Server.Health.bothFull
        }
    }

    // MARK: - Metrics

    private var tiles: some View {
        let stats = monitor.stats
        let points = monitor.history
        let root = stats?.disks.first { $0.mount == "/" } ?? stats?.disks.first
        let rx = stats?.netRxBps ?? 0
        let tx = stats?.netTxBps ?? 0
        let diskTotal = root?.total ?? 0
        let diskUsed = root?.used ?? 0
        return HStack(alignment: .top, spacing: 12) {
            openable(.cpu) {
                MetricTile(
                    label: L10n.Server.Tile.cpu,
                    value: HostFormat.percent(stats?.cpuPercent ?? 0),
                    note: L10n.Server.cores(count: stats?.cpus ?? 0),
                    series: HostFormat.downsample(points.map(\.cpu), to: 120),
                    tint: Color.Bandito.ok)
            }
            openable(.memory) {
                MetricTile(
                    label: L10n.Server.Tile.memory,
                    value: HostFormat.bytes(stats?.memUsed ?? 0),
                    note: L10n.Server.Tile.memoryOf(total: HostFormat.bytes(stats?.memTotal ?? 0)),
                    series: HostFormat.downsample(
                        points.map { HostHealth.fraction(used: $0.memUsed, total: stats?.memTotal ?? 0) * 100 }, to: 120),
                    tint: Color.Bandito.signal)
            }
            openable(.disk) {
                let usage = HostFormat.diskUsage(used: diskUsed, total: diskTotal)
                MetricTile(
                    label: L10n.Server.Tile.disk,
                    value: HostFormat.bytes(max(0, diskTotal - diskUsed)),
                    note: "",
                    series: [],
                    tint: Color.Bandito.text,
                    valueNote: L10n.Server.Tile.freeWord,
                    fill: diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : nil,
                    caption: L10n.Server.Tile.diskUsed(used: usage.used, total: usage.total))
            }
            openable(.network) {
                MetricTile(
                    label: L10n.Server.Tile.network,
                    value: HostFormat.rate(rx + tx),
                    note: L10n.Server.Tile.netSplit(down: HostFormat.rate(rx), up: HostFormat.rate(tx)),
                    series: HostFormat.downsample(points.map { Double($0.netRxBps + $0.netTxBps) }, to: 120),
                    tint: Color.Bandito.info)
            }
        }
    }

    /// A metric card that opens its detail: the chart for the chosen period, with averages and the top processes.
    private func openable<Tile: View>(_ metric: OverviewMetric, @ViewBuilder tile: () -> Tile) -> some View {
        Button {
            detail = metric
        } label: {
            tile()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .banditoButton(.row(cornerRadius: 16))
        .popover(
            isPresented: Binding(get: { detail == metric }, set: { if !$0 { detail = nil } }),
            arrowEdge: .bottom
        ) {
            if let server {
                MetricDetailView(
                    metric: metric, monitor: monitor, server: server,
                    ownerName: { ownerName($0, server: server) })
            }
        }
    }

    // MARK: - Who uses the most

    private func processesCard(_ server: ServerModel) -> some View {
        ServerCard {
            HStack {
                SectionLabel(L10n.Server.Processes.title)
                Spacer(minLength: 8)
                Text(L10n.Server.Processes.hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
            }
            if !monitor.processesSupported {
                Text(L10n.Server.Processes.unsupported).foregroundStyle(Color.Bandito.text2)
            } else if monitor.processes.isEmpty {
                Text(L10n.Server.Processes.empty).foregroundStyle(Color.Bandito.text2)
            }
            ForEach(monitor.processes) { row in
                processRow(row, server: server)
                    .overlay(alignment: .top) { Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1) }
            }
            if let actionError {
                UserFacingErrorView(message: actionError)
            }
        }
    }

    private func processRow(_ row: ProcessRow, server: ServerModel) -> some View {
        let name = ownerName(row, server: server)
        let cpus = Double(max(1, monitor.stats?.cpus ?? 1))
        let fraction = min(1, row.cpuPercent / (100 * cpus))
        return HStack(alignment: .center, spacing: 10) {
            ownerAvatar(row, name: name)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(row.commandNames)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.Server.Processes.cpu(percent: HostFormat.percent(row.cpuPercent)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text2)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.Bandito.text.opacity(0.08))
                        Capsule().fill(Color.Bandito.text2).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 120)
            Text(HostFormat.bytes(row.rssBytes))
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 70, alignment: .trailing)
            if row.canStop {
                Button {
                    stopping = row
                } label: {
                    Image(systemName: "stop.fill")
                }
                .banditoButton(.icon(size: 26, label: L10n.Server.Processes.stopAria(name: name)))
            } else {
                Color.clear.frame(width: 26, height: 26)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func ownerAvatar(_ row: ProcessRow, name: String) -> some View {
        switch row.owner.kind {
        case .agent:
            AgentAvatar(name: name, size: 26)
        case .terminal, .daemon:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.Bandito.text.opacity(0.07))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: row.owner.kind == .terminal ? "terminal" : "waveform.path.ecg")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text2)
                }
        }
    }

    private func ownerName(_ row: ProcessRow, server: ServerModel) -> String {
        switch row.owner.kind {
        case .agent: server.agents.first { $0.id == row.owner.id }?.name ?? L10n.Server.Owner.agent
        case .terminal: L10n.Server.Owner.terminal
        case .daemon: L10n.Server.Owner.daemon
        }
    }

    private var stopTitle: String {
        guard let stopping, let server else { return "" }
        return L10n.Server.Processes.stopTitle(name: ownerName(stopping, server: server))
    }

    private func stop(_ row: ProcessRow, server: ServerModel) {
        actionError = nil
        Task {
            do {
                for pid in row.pids {
                    try await server.kill(pid: pid)
                }
            } catch {
                actionError = UserFacingError.message(for: error)
            }
            await monitor.refresh(server)
        }
    }

    /// "Capabilities": only for a daemon that reports setup; otherwise the card is not shown at all.
    @ViewBuilder
    private func featuresCard(_ server: ServerModel) -> some View {
        if server.supports("setup") {
            ServerFeaturesCard(server: server, setup: setup)
        }
    }

    // MARK: - Ports, secrets

    private var portsCard: some View {
        ServerCard {
            SectionLabel(L10n.Server.Ports.title)
            if !monitor.portsSupported {
                Text(L10n.Server.Processes.unsupported).foregroundStyle(Color.Bandito.text2)
            } else if monitor.ports.isEmpty {
                Text(L10n.Server.Ports.empty).foregroundStyle(Color.Bandito.text2)
            }
            ForEach(monitor.ports.filter(PreviewPorts.isPreviewable).prefix(4), id: \.self) { port in
                HStack(spacing: 10) {
                    PortBadge(port: port.port)
                    Text(port.process ?? "—")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(ownerLabel(port))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(L10n.Server.Ports.open) { openPreview(port.port) }
                        .banditoButton(.quiet(size: .regular))
                }
            }
        }
    }

    private func secretsCard(_ server: ServerModel) -> some View {
        ServerCard {
            HStack {
                SectionLabel(L10n.Server.Secrets.title)
                Spacer(minLength: 8)
                Button(L10n.Server.Secrets.all) { router.serverSection = .secrets }
                    .banditoButton(.quiet())
            }
            if !server.supports("secrets") {
                Text(L10n.Server.updateNote).foregroundStyle(Color.Bandito.text2)
            } else if secrets.isEmpty {
                Text(L10n.Secrets.empty).foregroundStyle(Color.Bandito.text2)
            }
            ForEach(secrets.prefix(3)) { secret in
                HStack(spacing: 10) {
                    Text(secret.name)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(SecretsView.masked(secret.tail))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text3)
                    Text(SecretsView.whoLabel(secret.agents, server: server))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                }
            }
            Text(L10n.Secrets.hint)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    /// Who opened the port: an agent or a terminal, or the daemon itself. Anything else has no owner to name.
    private func ownerLabel(_ port: ListeningPort) -> String {
        switch port.owner?.kind {
        case .agent: server?.agents.first { $0.id == port.owner?.id }?.name ?? L10n.Server.Owner.agent
        case .terminal: L10n.Server.Owner.terminal
        case .daemon: L10n.Server.Owner.daemon
        case nil: ""
        }
    }

    /// Opens the browser on a port of the server. The browser takes the port from the router.
    private func openPreview(_ port: Int) {
        router.pendingPreviewPort = port
        router.select(mode: .browser)
    }

    // MARK: - Loading and the update banner

    private func loadExtras(_ server: ServerModel) async {
        if server.supports("secrets") {
            secrets = (try? await server.secrets()) ?? []
        }
        await release.load()
    }

    private func updateBanner(_ server: ServerModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Bandito.signal)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Server.Update.available(version: release.latest?.description ?? ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Server.Update.current(version: server.info?.version ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text2)
            }
            Spacer(minLength: 8)
            Button(L10n.Server.Update.howTo) {
                router.requestTerminalCommand(ReleaseFeed.installCommand)
            }
            .banditoButton(.lightPill())
        }
        .padding(14)
        .background(Color.Bandito.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.Bandito.signal.opacity(0.28), lineWidth: 1))
    }
}

/// Fixed heights of the parts of a metric tile, so all four tiles are the same height whatever they show.
private enum TileHeight {
    /// The label line.
    static let header: CGFloat = 18
    /// The big number (26 pt type).
    static let value: CGFloat = 32
    /// The chart, or the fill bar and its caption.
    static let chart: CGFloat = 44
}

/// Width of the page, read from the layout.
private struct PageWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// One metric of the overview: its label, the number, a note, and a sparkline of its history.
private struct MetricTile: View {
    let label: String
    let value: String
    let note: String
    let series: [Double]
    let tint: Color
    /// A word after the value in small type, such as "free" after the free space.
    var valueNote: String?
    /// Share of the capacity in use, 0...1. Shown as a bar in place of the sparkline.
    var fill: Double?
    /// A line under the value that says what the number means.
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                Spacer(minLength: 6)
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            .frame(height: TileHeight.header)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let valueNote {
                    Text(valueNote)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            .frame(height: TileHeight.value, alignment: .leading)
            // The chart area has the same fixed height in every tile, so the row of four cards lines up.
            if let fill {
                VStack(alignment: .leading, spacing: 4) {
                    FillBar(fraction: fill, tint: tint)
                        .frame(height: 6)
                        .padding(.top, 4)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.top, 4)
                    }
                }
                .frame(height: TileHeight.chart, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Sparkline(values: series, tint: tint)
                    .frame(height: TileHeight.chart)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard()
    }
}

/// The history of one metric as a filled line. Empty when there is no history.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        if values.count < 2 {
            Color.clear
        } else {
            Chart {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    AreaMark(x: .value("Sample", index), y: .value("Value", value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Sample", index), y: .value("Value", value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(tint)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(1, values.max() ?? 1))
            .banditoAnimation(.easeInOut(duration: 0.6), value: values)
        }
    }
}

/// A port number in the green chip of the design.
struct PortBadge: View {
    let port: Int

    var body: some View {
        Text(verbatim: ":\(port)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.Bandito.ok)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.Bandito.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
