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
    let ownerName: (ProcessRow) -> String

    @State private var selected: Date?

    /// One drawn sample: a time, a value and the line it belongs to.
    private struct Sample: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let series: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(metric.title)
                    .font(.system(size: 15, weight: .semibold))
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
                summary
                chart
                Text(L10n.Server.Detail.hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                topProcesses
            }
        }
        .padding(18)
        .frame(width: 520, alignment: .leading)
        .background(Color.Bandito.surface2)
    }

    // MARK: - Numbers

    private var summary: some View {
        let values = totals
        let current = currentValue
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let peak = values.max() ?? 0
        return HStack(alignment: .top, spacing: 24) {
            figure(L10n.Server.Detail.now, format(current))
            figure(L10n.Server.Detail.average, format(average))
            figure(L10n.Server.Detail.peak, format(peak))
            Spacer(minLength: 0)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let samples = samples
        let names = seriesNames
        return Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.date), y: .value("Value", sample.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(by: .value("Series", sample.series))
            }
            if let selected, let nearest = nearestSample(to: selected, in: samples) {
                RuleMark(x: .value("Selected", nearest.date))
                    .foregroundStyle(Color.Bandito.text3.opacity(0.6))
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        Text(annotationText(for: nearest))
                            .font(.system(size: 11.5, weight: .medium))
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
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(format(number))
                    }
                }
            }
        }
        .frame(height: 220)
        .banditoAnimation(.easeInOut(duration: 0.3), value: monitor.range)
    }

    // MARK: - Processes

    @ViewBuilder
    private var topProcesses: some View {
        let rows = topRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(L10n.Server.Detail.topProcesses)
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Text(ownerName(row))
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(processValue(row))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 3)
                }
            }
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
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Server.Tile.freeWord)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(L10n.Server.Tile.diskUsed(used: usage.used, total: usage.total))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            FillBar(fraction: fraction, tint: Color.Bandito.text)
                .frame(height: 8)
            Text(L10n.Server.Detail.diskNoHistory)
                .font(.system(size: 11.5))
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

    private var yDomain: ClosedRange<Double> {
        switch metric {
        case .cpu:
            return 0...100
        case .memory:
            let total = Double(monitor.stats?.memTotal ?? 0)
            return 0...max(1, total, samples.map(\.value).max() ?? 0)
        case .network, .disk:
            return 0...max(1, samples.map(\.value).max() ?? 0)
        }
    }

    private var topRows: [ProcessRow] {
        switch metric {
        case .cpu: monitor.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5).map { $0 }
        case .memory: monitor.processes.sorted { $0.rssBytes > $1.rssBytes }.prefix(5).map { $0 }
        case .network, .disk: []
        }
    }

    private func processValue(_ row: ProcessRow) -> String {
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
