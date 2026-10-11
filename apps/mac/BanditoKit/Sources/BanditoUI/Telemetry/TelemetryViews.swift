import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The first-run notice: what Bandito sends, what it never sends, and the two answers. Shown once after the update.
struct TelemetryNoticeSheet: View {
    @Environment(\.openURL) private var openURL
    let telemetry: TelemetryCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Telemetry.Notice.title)
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.Telemetry.Notice.intro)
                .font(BanditoFont.text(size: 13.5))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TelemetryPointList(
                        title: L10n.Telemetry.Notice.collectHeading,
                        points: [
                            L10n.Telemetry.Notice.Collect.app,
                            L10n.Telemetry.Notice.Collect.language,
                            L10n.Telemetry.Notice.Collect.servers,
                            L10n.Telemetry.Notice.Collect.counts,
                        ],
                        symbol: "checkmark", tint: Color.Bandito.ok)
                    TelemetryPointList(
                        title: L10n.Telemetry.Notice.neverHeading,
                        points: [
                            L10n.Telemetry.Notice.Never.content,
                            L10n.Telemetry.Notice.Never.code,
                            L10n.Telemetry.Notice.Never.addresses,
                            L10n.Telemetry.Notice.Never.secrets,
                        ],
                        symbol: "xmark", tint: Color.Bandito.text3)
                }
                .padding(.top, 16)
            }
            .scrollIndicators(.never)
            Text(L10n.Telemetry.Notice.note)
                .font(BanditoFont.text(size: 12))
                .foregroundStyle(Color.Bandito.text3)
                .padding(.top, 12)
            Button(L10n.Telemetry.Notice.policy) { openURL(TelemetryCenter.privacyPolicyURL) }
                .banditoButton(.link)
                .font(BanditoFont.text(size: 12.5))
                .padding(.top, 6)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.Telemetry.Notice.decline) { telemetry.answerNotice(sendStatistics: false) }
                    .banditoButton(.quiet())
                Button(L10n.Telemetry.Notice.accept) { telemetry.answerNotice(sendStatistics: true) }
                    .banditoButton(.signal())
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 480)
        .frame(maxHeight: 620)
        .background(Color.Bandito.surface2)
    }
}

/// A question with two answers: the crash-report question and the confirmation of "Delete my data".
struct TelemetryConfirmSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    let confirmIsDanger: Bool
    /// The label of the other answer: "Cancel" for a deletion, "Don't send" for the crash question.
    var cancelTitle: String = L10n.Common.cancel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(BanditoFont.display(size: 17, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(BanditoFont.text(size: 13.5))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(cancelTitle, action: onCancel)
                    .banditoButton(.quiet())
                if confirmIsDanger {
                    Button(confirmTitle, action: onConfirm)
                        .banditoButton(.quiet(tone: .danger))
                } else {
                    Button(confirmTitle, action: onConfirm)
                        .banditoButton(.signal())
                }
            }
            .padding(.top, 20)
        }
        .padding(28)
        .frame(width: 440)
        .background(Color.Bandito.surface2)
    }
}

/// A heading and its points, each with a mark that is a symbol as well as a colour.
private struct TelemetryPointList: View {
    let title: String
    let points: [String]
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text(point)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The strip at the top of the main window for one announcement. The text is plain: no markup, no links in the text.
struct AnnouncementBanner: View {
    let announcement: Announcement
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: announcement.title)
                    .font(BanditoFont.display(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: announcement.body)
                    .font(BanditoFont.text(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if let button = announcement.button, announcement.url != nil {
                Button(button, action: onOpen)
                    .banditoButton(.quiet())
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .banditoButton(.icon(label: L10n.Common.close))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .banditoCard()
        .frame(maxWidth: 680)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.Telemetry.Banner.aria)
    }
}
