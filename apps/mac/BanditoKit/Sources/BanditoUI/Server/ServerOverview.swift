import BanditoDesign
import BanditoKit
import BanditoL10n
import Charts
import SwiftUI

/// Server → Overview: health, four metrics with history, who uses the most, ports, secrets and capabilities.
struct ServerOverview: View {
    let server: ServerModel?
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var app
    @State private var monitor: HostMonitor
    @State private var setup = SetupModel()
    @State private var release = ReleaseStatus()
    @State private var daemonUpdate = DaemonUpdateModel()
    @State private var secrets: [SecretInfo] = []
    @State private var stopping: ProcessRow?
    @State private var actionError: UserFacingMessage?
    /// The metric whose detail is open, if any.
    @State private var detail: OverviewMetric?
    @Environment(\.scenarioRequests) private var scenario
    /// Two columns of cards or one. Starts narrow; changes only when the measured page width crosses the threshold.
    @State private var isWide = false

    /// `monitor` is given only by the layout audit, with numbers already in it.
    init(server: ServerModel?, monitor: HostMonitor = HostMonitor()) {
        self.server = server
        _monitor = State(initialValue: monitor)
    }

    /// The daemon runs without a database after a restore (safe mode): the reason, and the way to the copies.
    private func safeModeCard(_ info: DaemonInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Backups.safeMode(error: info.safeModeError ?? info.lastRestore?.error ?? ""))
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.danger)
            Text(L10n.Backups.safeModeHint)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
            Button(L10n.Mode.serverBackups) { router.serverSection = .backups }
                .banditoButton(.quiet())
                .fixedSize()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .banditoCard()
    }

    var body: some View {
        ServerPage(title: L10n.Mode.serverOverview, trailing: { trailing }) {
            if let server, let info = server.info, info.isSafeMode {
                safeModeCard(info)
            } else if let server, server.supports("host") {
                ServerPassport(server: server, stats: monitor.stats, health: monitor.stats.map(HostHealth.evaluate))
                LocalDaemonUpgradeBanner(server: server, model: app.localUpgrade)
                // This Mac's daemon is replaced by the bundled one: the release offers would be the same update, shown twice.
                if !app.localUpgrade.replacesOffer(for: server) {
                    // The daemon's own check wins; the GitHub hint is only for a daemon that has not reported one yet.
                    if daemonUpdate.shownOffer(current: server.daemonUpdateOffer, serverID: server.id) != nil {
                        DaemonUpdateBanner(server: server, model: daemonUpdate)
                    } else if release.updateAvailable(current: server.info?.version), server.info?.supports("update") != true {
                        // Only a daemon the app cannot update (no `update` feature) gets the terminal command.
                        updateBanner(server)
                    }
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
        .onChange(of: scenario?.overviewMetric) { _, metric in
            if detail != metric { detail = metric }
        }
        .task(id: server?.id) {
            guard let server else { return }
            await monitor.run(server)
        }
        .task(id: server?.id) {
            // Opening the Server screen re-reads the daemon's update check, so the offer is current.
            await server?.refreshInfo()
            await server?.refreshDaemonUpdateCheck()
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
            // The health shows once, in the server's passport below.
            SegmentedPicker(
                selection: Binding(
                    get: { monitor.range },
                    set: { range in
                        guard let server else { return }
                        Task { await monitor.setRange(range, server: server) }
                    }),
                options: [(HostHistoryRange.hour, L10n.Server.range1h), (HostHistoryRange.day, L10n.Server.range24h)])
            .fixedSize()
            if let server {
                Button(L10n.ServerSettings.openLink) { openServerSettings(server) }
                    .banditoButton(.quiet())
                    .fixedSize()
            }
        }
        .fixedSize()
    }

    /// Opens Settings on this server's settings page (Settings → Servers → the server).
    private func openServerSettings(_ server: ServerModel) {
        SettingsNavigation.shared.requestedServer = server.id
        SettingsNavigation.shared.requested = .servers
        WindowActions.showSettings()
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
        let root = stats?.primaryDisk
        let rx = stats?.netRxBps ?? 0
        let tx = stats?.netTxBps ?? 0
        let diskTotal = root?.total ?? 0
        let diskUsed = root?.used ?? 0
        // Four in a row on a wide page, two by two otherwise: a narrow card would cut its numbers.
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: isWide ? 4 : 2),
            alignment: .leading, spacing: 12
        ) {
            openable(.cpu) {
                MetricTile(
                    label: L10n.Server.Tile.cpu,
                    value: HostFormat.percent(stats?.cpuPercent ?? 0),
                    note: L10n.Server.cores(count: stats?.cpus ?? 0),
                    series: HostFormat.downsample(points.map(\.cpu), to: 120),
                    tint: Color.Bandito.signalGlow)
            }
            openable(.memory) {
                MetricTile(
                    label: L10n.Server.Tile.memory,
                    value: HostFormat.bytes(stats?.memUsed ?? 0),
                    note: L10n.Server.Tile.memoryOf(total: HostFormat.bytes(stats?.memTotal ?? 0)),
                    series: HostFormat.downsample(
                        points.map { HostHealth.fraction(used: $0.memUsed, total: stats?.memTotal ?? 0) * 100 }, to: 120),
                    tint: Color.Bandito.info)
            }
            openable(.disk) {
                let usage = HostFormat.diskUsage(used: diskUsed, total: diskTotal)
                MetricTile(
                    label: L10n.Server.Tile.disk,
                    value: HostFormat.diskBytes(max(0, diskTotal - diskUsed)),
                    note: "",
                    series: [],
                    tint: Color.Bandito.ok,
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
                    tint: BanditoPalette.avatarLilac)
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
                    .font(BanditoFont.text(size: 12, weight: 400))
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
        let cpuFraction = min(1, row.cpuPercent / (100 * cpus))
        let memTotal = monitor.stats?.memTotal ?? 0
        let memFraction = memTotal > 0 ? min(1, Double(row.rssBytes) / Double(memTotal)) : 0
        return HStack(alignment: .center, spacing: 10) {
            ownerAvatar(row, name: name, server: server)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(row.commandNames)
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Two thin bars, CPU and memory, in the tile colours, with the numbers in mono on the right.
            VStack(alignment: .leading, spacing: 6) {
                usageBar(fraction: cpuFraction, tint: Color.Bandito.signalGlow,
                         value: HostFormat.percent(row.cpuPercent))
                usageBar(fraction: memFraction, tint: Color.Bandito.info,
                         value: HostFormat.bytes(row.rssBytes))
            }
            .frame(width: 210)
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

    /// A thin capsule bar with its value in mono at the right. The bar takes the rest of the width.
    private func usageBar(fraction: Double, tint: Color, value: String) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Bandito.text.opacity(0.08))
                    Capsule().fill(tint).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 3)
            Text(value)
                .font(BanditoFont.mono(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func ownerAvatar(_ row: ProcessRow, name: String, server: ServerModel) -> some View {
        switch row.owner.kind {
        case .agent:
            OwnerAgentAvatar(owner: row.owner, server: server, fallbackName: name, size: 24)
        case .terminal, .daemon:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.Bandito.text.opacity(0.07))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: row.owner.kind == .terminal ? "terminal" : "waveform.path.ecg")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text2)
                }
        }
    }

    private func ownerName(_ row: ProcessRow, server: ServerModel) -> String {
        ownerName(row.owner, server: server)
    }

    private func ownerName(_ owner: ProcessOwnerRef, server: ServerModel) -> String {
        switch owner.kind {
        case .agent: server.agents.first { $0.id == owner.id }?.name ?? L10n.Server.Owner.agent
        case .terminal:
            owner.id.flatMap { app.terminalController(for: server).displayTitle($0) } ?? L10n.Server.Owner.terminal
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
                        .font(BanditoFont.text(size: 13, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(ownerLabel(port))
                        .font(BanditoFont.text(size: 12, weight: 400))
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
                        .font(BanditoFont.mono(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(SecretsView.masked(secret.tail))
                        .font(BanditoFont.mono(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                    Text(SecretsView.whoLabel(secret.agents, server: server))
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                }
            }
            Text(L10n.Secrets.hint)
                .font(BanditoFont.text(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    /// Who opened the port: an agent or a terminal, or the daemon itself. Anything else has no owner to name.
    private func ownerLabel(_ port: ListeningPort) -> String {
        switch port.owner?.kind {
        case .agent: server?.agents.first { $0.id == port.owner?.id }?.name ?? L10n.Server.Owner.agent
        case .terminal:
            server.flatMap { app.terminalController(for: $0).displayTitle(port.owner?.id ?? "") } ?? L10n.Server.Owner.terminal
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
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Server.Update.current(version: server.info?.version ?? ""))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            }
            Spacer(minLength: 8)
            // This Mac's server is updated from the app, never from a terminal command.
            if !server.isThisMacServer {
                Button(L10n.Server.Update.howTo) {
                    router.requestTerminalCommand(ReleaseFeed.installCommand)
                }
                .banditoButton(.lightPill())
            }
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
    /// The big number (28 pt type).
    static let value: CGFloat = 36
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
                SectionLabel(label)
                Spacer(minLength: 6)
                Text(note)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            .frame(height: TileHeight.header)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                let parts = OverviewTileText.split(value)
                Text(parts.number)
                    .font(BanditoFont.display(size: 28, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = parts.unit {
                    Text(unit)
                        .font(BanditoFont.text(size: 14, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                }
                if let valueNote {
                    Text(valueNote)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
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
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.top, 4)
                    }
                }
                .frame(height: TileHeight.chart, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                Sparkline(values: series, tint: tint, fillOpacity: 0.35, lineWidth: 1.5)
                    .frame(height: TileHeight.chart)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard(hoverLift: true)
    }
}

/// The history of one metric as a filled line. Empty when there is no history.
struct Sparkline: View {
    let values: [Double]
    let tint: Color
    /// Opacity of the fill at the top; it fades to 0 at the bottom.
    var fillOpacity = 0.22
    var lineWidth: CGFloat = 2

    // Drawn as two shapes, not as a chart: a chart builds a mark for every sample of the four tiles and was a large
    // part of opening the Server page; it also animated every new sample through the whole chart.
    var body: some View {
        if values.count < 2 {
            Color.clear
        } else {
            let top = max(1, values.max() ?? 1)
            ZStack {
                SparklineShape(values: values, top: top, inset: lineWidth / 2, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(fillOpacity), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                SparklineShape(values: values, top: top, inset: lineWidth / 2, closed: false)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// The line of a sparkline through its samples (monotone cubic, so it never overshoots a sample), or the area under
/// it when `closed`. The samples span the width; 0 is the bottom, `top` the top.
struct SparklineShape: Shape {
    let values: [Double]
    let top: Double
    /// Room kept at the top and the bottom for the line's width.
    var inset: CGFloat = 0
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        let points = SparklineGeometry.points(values: values, top: top, in: rect.insetBy(dx: 0, dy: inset))
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let tangents = SparklineGeometry.tangents(points)
        for index in 1..<points.count {
            let a = points[index - 1]
            let b = points[index]
            let third = (b.x - a.x) / 3
            path.addCurve(
                to: b, control1: CGPoint(x: a.x + third, y: a.y + tangents[index - 1] * third),
                control2: CGPoint(x: b.x - third, y: b.y - tangents[index] * third))
        }
        if closed, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// Where the samples of a sparkline go, and the slopes of a monotone curve through them (Fritsch–Carlson). Pure.
enum SparklineGeometry {
    static func points(values: [Double], top: Double, in rect: CGRect) -> [CGPoint] {
        guard values.count > 1, top > 0 else { return [] }
        let step = rect.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let share = min(max(value / top, 0), 1)
            return CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - CGFloat(share) * rect.height)
        }
    }

    /// The slope (dy/dx) at each point, limited so the curve keeps the order of the samples.
    static func tangents(_ points: [CGPoint]) -> [CGFloat] {
        let count = points.count
        guard count > 1 else { return Array(repeating: 0, count: count) }
        var secants: [CGFloat] = []
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            secants.append(dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx)
        }
        var slopes = [CGFloat](repeating: 0, count: count)
        slopes[0] = secants[0]
        slopes[count - 1] = secants[count - 2]
        if count > 2 {
            for index in 1..<(count - 1) {
                let left = secants[index - 1]
                let right = secants[index]
                slopes[index] = left * right <= 0 ? 0 : (left + right) / 2
            }
        }
        for index in 0..<(count - 1) where secants[index] == 0 {
            slopes[index] = 0
            slopes[index + 1] = 0
        }
        for index in 0..<(count - 1) where secants[index] != 0 {
            let a = slopes[index] / secants[index]
            let b = slopes[index + 1] / secants[index]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                slopes[index] = scale * a * secants[index]
                slopes[index + 1] = scale * b * secants[index]
            }
        }
        return slopes
    }
}

/// A port number in the green chip of the design.
struct PortBadge: View {
    let port: Int

    var body: some View {
        Text(verbatim: ":\(port)")
            .font(BanditoFont.mono(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.ok)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.Bandito.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The avatar of the agent that owns a process: its own look (color, face, picture) when the server knows the agent,
/// else one drawn from the name, so the Server screens show the same faces as the sidebar.
struct OwnerAgentAvatar: View {
    let owner: ProcessOwnerRef
    let server: ServerModel?
    let fallbackName: String
    let size: CGFloat

    var body: some View {
        if let server, let agent = server.agents.first(where: { $0.id == owner.id }) {
            AgentAvatarView(agent: agent, server: server, size: size)
        } else {
            AgentAvatar(name: fallbackName, size: size)
        }
    }
}
