import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The top card of the Server overview: the device in a tile, its name and system line, a badge for this Mac, and
/// the status ring with its words on the right.
struct ServerPassport: View {
    let server: ServerModel
    let stats: HostStats?
    let health: HostHealth?

    var body: some View {
        ServerCard {
            HStack(alignment: .center, spacing: 16) {
                deviceTile
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(server.config.name)
                            .font(BanditoFont.display(size: 20, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if server.isThisMacServer {
                            Chip(text: L10n.Server.Add.thisMac, tone: .neutral)
                                .fixedSize()
                        }
                    }
                    if let stats {
                        Text(Self.systemLine(stats: stats, daemonVersion: server.info?.version ?? ""))
                            .font(BanditoFont.text(size: 12.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                statusRing
            }
        }
    }

    /// "macos 25.6.0 · Bandito 0.1.6 · up 3 days": the system and its version, the daemon's version, the uptime.
    static func systemLine(stats: HostStats, daemonVersion: String) -> String {
        let system = [stats.os, stats.kernel].filter { !$0.isEmpty }.joined(separator: " ")
        return L10n.Inspector.serverInfo(os: system, version: daemonVersion, uptime: uptimeText(seconds: stats.uptimeS))
    }

    /// Days from a day on, hours below, "less than an hour" under that.
    static func uptimeText(seconds: Int64) -> String {
        let hours = max(0, seconds) / 3600
        if hours >= 24 { return L10n.Inspector.uptime(count: Int(hours / 24)) }
        if hours >= 1 { return L10n.Server.Passport.uptimeHours(count: Int(hours)) }
        return L10n.Server.Passport.uptimeLessHour
    }


    private var deviceTile: some View {
        Image(systemName: DeviceIcon.symbol(platform: stats?.os, name: server.config.name))
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.Bandito.text)
            .frame(width: 52, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.Bandito.text.opacity(0.06))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.Bandito.line))
    }

    /// Green with a check when the server is fine, cream-orange with a mark when a disk or the memory is full.
    /// The words and the mark carry the state too, so it is not the colour alone.
    @ViewBuilder
    private var statusRing: some View {
        if let health {
            let tone = health.isOK ? Color.Bandito.ok : Color.Bandito.signal
            HStack(spacing: 12) {
                Text(ServerOverview.healthText(health))
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(tone)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                ZStack {
                    Circle()
                        .strokeBorder(tone, lineWidth: 3)
                    Image(systemName: health.isOK ? "checkmark" : "exclamationmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tone)
                }
                .frame(width: 40, height: 40)
            }
        }
    }
}

/// The text of a metric tile, split so the number gets the big type and the unit the small one.
enum OverviewTileText {
    /// "5,1 ГБ" becomes ("5,1", "ГБ"), "1,9 МБ/с" becomes ("1,9", "МБ/с"), "38%" becomes ("38", "%"). A value with no
    /// unit stays whole.
    static func split(_ text: String) -> (number: String, unit: String?) {
        if let space = text.lastIndex(of: " ") {
            return (String(text[..<space]), String(text[text.index(after: space)...]))
        }
        if text.hasSuffix("%") {
            return (String(text.dropLast()), "%")
        }
        return (text, nil)
    }
}
