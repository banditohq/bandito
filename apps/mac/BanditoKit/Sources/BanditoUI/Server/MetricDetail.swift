import BanditoDesign
import BanditoKit
import BanditoL10n
import Charts
import SwiftUI

/// The four metric cards of the overview. Each one opens its detail.
enum OverviewMetric: String, Identifiable, CaseIterable {
    case cpu, memory, disk, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: L10n.Server.Tile.cpu
        case .memory: L10n.Server.Tile.memory
        case .disk: L10n.Server.Tile.disk
        case .network: L10n.Server.Tile.network
        }
    }
}

/// The detail of one metric: a large chart for the chosen period, the current value, the average and the peak.
/// CPU and memory also list the processes that use the most. Hovering the chart shows the value at that moment.
struct MetricDetailView: View {
    let metric: OverviewMetric
    let monitor: HostMonitor
    let server: ServerModel
    let ownerName: (ProcessOwnerRef) -> String

    @State private var selected: Date?
    /// The process the user chose to stop, until the user confirms or cancels.
    @State private var stopping: HostProcessEntry?
    @State private var stopError: UserFacingMessage?
    /// Set when the daemon sent SIGTERM but the process was still running a second later.
    @State private var stillRunning = false
    /// Ids of the groups that are open, and whether the list shows every row.
    @State private var expanded: Set<String> = []
    @State private var showAll = false

    /// Rows shown before "Show all".
    private static let collapsedRows = 8
    private static let gib = 1024.0 * 1024 * 1024

    /// One drawn sample: a time, a value and the line it belongs to.
    private struct Sample: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let series: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(metric.title)
                    .font(BanditoFont.text(size: 15, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                SegmentedPicker(
                    selection: Binding(
                        get: { monitor.range },
                        set: { range in Task { await monitor.setRange(range, server: server) } }),
                    options: [(HostHistoryRange.hour, L10n.Server.range1h), (HostHistoryRange.day, L10n.Server.range24h)]
                )
                .fixedSize()
            }
            if metric == .disk {
                diskBody
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        summary
                        chart
                        topProcesses
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(16)
        .frame(width: 520, alignment: .leading)
        .frame(maxHeight: 560)
        .background(Color.Bandito.surface2)
        .confirmationDialog(
            stopping.map { L10n.Server.Detail.stopTitle(name: $0.name) } ?? "",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            titleVisibility: .visible,
            presenting: stopping
        ) { row in
            Button(L10n.Server.Detail.stopConfirm, role: .destructive) { stop(row) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Server.Detail.stopMessage)
        }
    }

    // MARK: - Numbers

    private var summary: some View {
        let values = totals
        let current = currentValue
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let peak = values.max() ?? 0
        return HStack(alignment: .top, spacing: 28) {
            figure(L10n.Server.Detail.now, format(current))
            figure(L10n.Server.Detail.average, format(average))
            figure(L10n.Server.Detail.peak, format(peak))
            Spacer(minLength: 0)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(BanditoFont.text(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
            Text(value)
                .font(BanditoFont.display(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let samples = samples
        let names = seriesNames
        let scale = yScale
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Value", sample.value / yScale))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(by: .value("Series", sample.series))
            }
            if let selected, let nearest = nearestSample(to: selected, in: samples) {
                RuleMark(x: .value("Selected", nearest.date))
                    .foregroundStyle(Color.Bandito.text3.opacity(0.6))
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        Text(annotationText(for: nearest))
                            .font(BanditoFont.text(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.Bandito.surface3, in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartForegroundStyleScale(domain: names.map(\.name), range: names.map(\.color))
        .chartLegend(metric == .network ? .visible : .hidden)
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Self.axisLabel(format(number * scale)))
                    }
                }
            }
        }
        .frame(height: 150)
        .help(L10n.Server.Detail.hint)
        .banditoAnimation(.easeInOut(duration: 0.3), value: monitor.range)
    }

    // MARK: - Processes

    /// The biggest processes of the server (`top_processes`), merged by app. Hidden while there are none, and for a
    /// daemon that does not send the list.
    @ViewBuilder
    private var topProcesses: some View {
        let groups = topGroups
        if !groups.isEmpty {
            let visible = showAll ? groups : Array(groups.prefix(Self.collapsedRows))
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(L10n.Server.Detail.topProcesses)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { group in
                        groupRows(group)
                    }
                }
                if groups.count > Self.collapsedRows {
                    Button(showAll ? L10n.Server.Detail.showLess : L10n.Server.Detail.showAll(count: groups.count)) {
                        showAll.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                }
                if stillRunning {
                    Text(L10n.Server.Detail.stillRunning)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let stopError {
                    UserFacingErrorView(message: stopError)
                }
            }
        }
    }

    @ViewBuilder
    private func groupRows(_ group: HostProcessGroup) -> some View {
        if group.isGroup, !group.members.isEmpty {
            let open = expanded.contains(group.id)
            ProcessRowView(
                owner: group.owner, ownerName: ownerName, title: group.appName,
                subtitle: L10n.Server.Detail.processCount(count: group.processCount),
                value: groupValue(group), indent: false, trailing: .chevron(open: open), stopName: nil,
                onTap: {
                    if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                },
                onStop: nil)
            if open {
                ForEach(group.members) { row in
                    memberRow(row, indent: true)
                }
            }
        } else if !group.isGroup, let row = group.members.first {
            memberRow(row, indent: false)
        } else {
            // The sums of an app whose processes this list does not name: a plain row, nothing to stop or expand.
            ProcessRowView(
                owner: group.owner, ownerName: ownerName, title: group.appName,
                subtitle: group.isGroup ? L10n.Server.Detail.processCount(count: group.processCount) : nil,
                value: groupValue(group), indent: false, trailing: .none, stopName: nil,
                onTap: nil, onStop: nil)
        }
    }

    private func memberRow(_ row: HostProcessEntry, indent: Bool) -> some View {
        let owned = row.owner != nil
        let appName = HostProcessList.appName(row.name)
        // An agent's process shows the agent first and the program under it; an ordinary one shows the program,
        // and under it the raw name when the app name is a shortened form of it.
        let title = row.owner.map { ownerName($0) } ?? appName
        let subtitle: String? = owned ? appName : (appName != row.name ? row.name : nil)
        return ProcessRowView(
            owner: row.owner, ownerName: ownerName, title: title, subtitle: subtitle,
            value: processValue(row), indent: indent,
            trailing: row.canStop ? .stop : .none,
            stopName: row.canStop ? row.name : nil,
            onTap: nil,
            onStop: { stopping = row })
    }

    private func stop(_ row: HostProcessEntry) {
        stopError = nil
        stillRunning = false
        Task {
            do {
                stillRunning = !(try await server.killProcess(pid: row.pid))
            } catch {
                stopError = UserFacingError.message(for: error)
            }
            await monitor.refresh(server)
        }
    }

    // MARK: - Disk

    /// The disk keeps no history yet: the card shows the fill as it is now.
    private var diskBody: some View {
        let stats = monitor.stats
        let root = stats?.primaryDisk
        let total = root?.total ?? 0
        let used = root?.used ?? 0
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        let usage = HostFormat.diskUsage(used: used, total: total)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HostFormat.diskBytes(max(0, total - used)))
                    .font(BanditoFont.display(size: 24, weight: 600))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Server.Tile.freeWord)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(L10n.Server.Tile.diskUsed(used: usage.used, total: usage.total))
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            FillBar(fraction: fraction, tint: Color.Bandito.text)
                .frame(height: 8)
            Text(L10n.Server.Detail.diskNoHistory)
                .font(BanditoFont.text(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
        }
    }

    // MARK: - Data

    private var seriesNames: [(name: String, color: Color)] {
        switch metric {
        case .cpu: [(OverviewMetric.cpu.title, Color.Bandito.ok)]
        case .memory: [(OverviewMetric.memory.title, Color.Bandito.signal)]
        case .network: [(L10n.Server.Detail.download, Color.Bandito.info), (L10n.Server.Detail.upload, Color.Bandito.signal)]
        case .disk: []
        }
    }

    private var samples: [Sample] {
        monitor.history.enumerated().flatMap { index, point -> [Sample] in
            let date = Date(timeIntervalSince1970: TimeInterval(point.t) / 1000)
            switch metric {
            case .cpu:
                return [Sample(id: index * 2, date: date, value: point.cpu, series: OverviewMetric.cpu.title)]
            case .memory:
                return [Sample(id: index * 2, date: date, value: Double(point.memUsed), series: OverviewMetric.memory.title)]
            case .network:
                return [
                    Sample(id: index * 2, date: date, value: Double(point.netRxBps), series: L10n.Server.Detail.download),
                    Sample(id: index * 2 + 1, date: date, value: Double(point.netTxBps), series: L10n.Server.Detail.upload),
                ]
            case .disk:
                return []
            }
        }
    }

    /// The number the summary compares: CPU percent, memory bytes, or the download and upload rate together.
    private var totals: [Double] {
        monitor.history.map { point in
            switch metric {
            case .cpu: point.cpu
            case .memory: Double(point.memUsed)
            case .network, .disk: Double(point.netRxBps + point.netTxBps)
            }
        }
    }

    private var currentValue: Double {
        guard let stats = monitor.stats else { return 0 }
        switch metric {
        case .cpu: return stats.cpuPercent
        case .memory: return Double(stats.memUsed)
        case .network, .disk: return Double(stats.netRxBps + stats.netTxBps)
        }
    }

    /// What the chart's y values are divided by: memory is drawn in GiB, so the axis ends on round numbers.
    private var yScale: Double { metric == .memory ? Self.gib : 1 }

    /// The chart's y range, in drawn units (percent, GiB, or bytes per second).
    private var yDomain: ClosedRange<Double> {
        switch metric {
        case .cpu:
            return 0...100
        case .memory:
            return 0...(memoryTicks.last ?? 1)
        case .network, .disk:
            return 0...max(1, samples.map(\.value).max() ?? 0)
        }
    }

    private var yTicks: AxisMarkValues {
        switch metric {
        case .memory: .stride(by: memoryStep)
        case .cpu: .automatic(desiredCount: 4)
        case .network, .disk: .automatic(desiredCount: 4)
        }
    }

    private var memoryTop: Double {
        max(1, Double(monitor.stats?.memTotal ?? 0) / Self.gib, (samples.map(\.value).max() ?? 0) / Self.gib)
    }

    private var memoryStep: Double { Self.memoryAxis(topGiB: memoryTop).step }

    private var memoryTicks: [Double] {
        let axis = Self.memoryAxis(topGiB: memoryTop)
        return stride(from: 0, through: axis.top, by: axis.step).map { $0 }
    }

    /// The smallest round step (in GiB) with at most four intervals up to `topGiB`, and the axis top it gives.
    nonisolated static func memoryAxis(topGiB: Double) -> (step: Double, top: Double) {
        let steps: [Double] = [1, 2, 2.5, 4, 5, 8, 10, 16, 20, 25, 32, 50, 64, 100, 128, 256]
        let top = max(1, topGiB)
        let step = steps.first { top / $0 <= 4 } ?? (top / 4).rounded(.up)
        return (step, step * (top / step).rounded(.up))
    }

    private func groupValue(_ group: HostProcessGroup) -> String {
        metric == .memory ? HostFormat.bytes(group.rssBytes) : HostFormat.percent(group.cpuPercent)
    }

    /// The CPU list is sorted by CPU among the biggest processes by memory, which is all the daemon sends. With the
    /// daemon's app groups the sums are exact (every process counted); without them the groups are built from the list.
    private var topGroups: [HostProcessGroup] {
        let top = monitor.stats?.topProcesses ?? []
        let sort: HostProcessList.Sort
        switch metric {
        case .cpu: sort = .cpu
        case .memory: sort = .memory
        case .network, .disk: return []
        }
        // No cut before grouping: the helpers of one app must all land in its group.
        let rows = HostProcessList.rows(top: top, owners: monitor.ownerGroups, sort: sort, limit: .max)
        if let apps = monitor.stats?.appGroups, !apps.isEmpty {
            return HostProcessList.appGroups(apps, rows: rows, sort: sort)
        }
        return HostProcessList.groups(rows, sort: sort)
    }

    private func processValue(_ row: HostProcessEntry) -> String {
        metric == .memory ? HostFormat.bytes(row.rssBytes) : HostFormat.percent(row.cpuPercent)
    }

    private func nearestSample(to date: Date, in samples: [Sample]) -> Sample? {
        samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    private func annotationText(for sample: Sample) -> String {
        let clock = sample.date.formatted(.dateTime.hour().minute().second())
        if metric == .network {
            return "\(clock) · \(sample.series) \(format(sample.value))"
        }
        return "\(clock) · \(format(sample.value))"
    }

    /// An axis label without a zero fraction: "8 ГБ", not "8,0 ГБ".
    static func axisLabel(_ text: String) -> String {
        text.replacingOccurrences(of: #"(\d)[.,]0(?=\D|$)"#, with: "$1", options: .regularExpression)
    }

    private func format(_ value: Double) -> String {
        switch metric {
        case .cpu: HostFormat.percent(value)
        case .memory: HostFormat.bytes(Int64(value))
        case .network, .disk: HostFormat.rate(Int64(value))
        }
    }
}

/// A thin filled bar for a share of something, such as the disk in use.
struct FillBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Bandito.text.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
    }
}

/// One line of the process list: 28pt, a hover backdrop, and a 24pt action column that is always reserved so the
/// values line up. The column holds the chevron of a group, or the stop icon of a process, shown on hover.
private struct ProcessRowView: View {
    enum Trailing: Equatable {
        case none, stop, chevron(open: Bool)
    }

    let owner: ProcessOwnerRef?
    let ownerName: (ProcessOwnerRef) -> String
    let title: String
    let subtitle: String?
    let value: String
    let indent: Bool
    let trailing: Trailing
    /// The process name in the stop tooltip.
    let stopName: String?
    let onTap: (() -> Void)?
    let onStop: (() -> Void)?

    @State private var hovering = false
    @State private var overStop = false
    @FocusState private var stopFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 18, height: 18)
            HStack(spacing: 6) {
                Text(title)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(BanditoFont.text(size: 12.5, weight: 500)).monospacedDigit()
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .frame(width: 64, alignment: .trailing)
            action
                .frame(width: 24, height: 24)
        }
        .padding(.leading, indent ? 30 : 6)
        .padding(.trailing, 2)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.Bandito.text.opacity(hovering ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
        .modifier(RowButtonTraits(action: onTap))
    }

    @ViewBuilder
    private var icon: some View {
        if let owner, owner.kind == .agent {
            AgentAvatar(name: ownerName(owner), size: 18)
                .help(L10n.Server.Detail.agentMark)
        } else {
            // Only agents carry a picture; the other names line up with them.
            Color.clear.frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var action: some View {
        switch trailing {
        case .none:
            Color.clear
        case .chevron(let open):
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.Bandito.text3)
                .rotationEffect(.degrees(open ? 90 : 0))
        case .stop:
            Button(action: { onStop?() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(overStop ? Color.Bandito.text : Color.Bandito.text3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { overStop = $0 }
            .focused($stopFocused)
            .opacity(hovering || stopFocused ? 1 : 0)
            .help(stopName.map { L10n.Server.Detail.stopAria(name: $0) } ?? "")
            .accessibilityLabel(stopName.map { L10n.Server.Detail.stopAria(name: $0) } ?? "")
        }
    }
}

/// Makes a tappable row a button for the keyboard and VoiceOver; no-op for a row without an action.
private struct RowButtonTraits: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .focusable()
                .onKeyPress(.return) { action(); return .handled }
                .onKeyPress(.space) { action(); return .handled }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, action)
        } else {
            content
        }
    }
}
