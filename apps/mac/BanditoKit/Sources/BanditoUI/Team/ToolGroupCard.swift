import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Consecutive tool calls as one card: "Ran 3 commands", expandable to one line per command.
struct ToolGroupCard: View {
    var tools: [ToolRow]
    /// Total time of the group in seconds, when known.
    var duration: Double?

    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(BanditoMotion.ease) { open.toggle() }
            } label: {
                HStack(spacing: 10) {
                    statusIcon
                    Text(L10n.Thread.ranCommands(count: tools.count))
                        .font(BanditoFont.font(size: 12.5, weight: 500))
                        .foregroundStyle(Color.Bandito.text)
                    if let duration {
                        Text("· " + L10n.Thread.duration(runtime: duration.formatted(.number.precision(.fractionLength(1)))))
                            .font(BanditoFont.font(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text3)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools, id: \.callId) { tool in
                        ToolLine(tool: tool)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
                }
            }
        }
        .background(Color.Bandito.surface1.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if tools.contains(where: { $0.ok == nil }) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Bandito.text3)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .frame(width: 14)
        } else if tools.contains(where: { $0.ok == false }) {
            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.Bandito.danger).frame(width: 14)
        } else {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.Bandito.ok).frame(width: 14)
        }
    }
}

/// `$ command → result`, the monospaced line of one tool call.
private struct ToolLine: View {
    var tool: ToolRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("$").foregroundStyle(Color.Bandito.text3)
            Text(tool.title)
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let summary {
                Text(summary.text)
                    .foregroundStyle(summary.tint)
                    .lineLimit(1)
            }
        }
        .font(BanditoFont.font(size: 12, weight: 400, mono: true))
    }

    /// The first line of the output, in green for success and red for failure. Running calls show nothing.
    private var summary: (text: String, tint: Color)? {
        guard let ok = tool.ok else { return nil }
        let firstLine = tool.output?
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let text = firstLine.isEmpty ? (ok ? "✓" : "✗") : String(firstLine.prefix(80))
        return (text, ok ? Color.Bandito.ok : Color.Bandito.danger)
    }
}
