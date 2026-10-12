import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The place of the quick replies in a thread: it reads the newest set of the agent itself (a view that reads the thread
/// is rebuilt as it streams, so `ThreadView` does not) and draws `QuickRepliesBar` above the composer.
struct QuickRepliesHost: View {
    var server: ServerModel
    var agentID: String
    /// Sends a button's reply as the person's message. `true` when it went out.
    var onReply: (String) async -> Bool
    var onOpen: (URL) -> Void

    @State private var pressed: String?

    var body: some View {
        if let replies = QuickRepliesRules.shown(server.thread(for: agentID).quickReplies, pressed: pressed) {
            QuickRepliesBar(
                replies: replies,
                onReply: { reply in
                    // The row goes away at once; a reply that did not go out brings it back.
                    pressed = replies.id
                    Task {
                        let sent = await onReply(reply)
                        if !sent, pressed == replies.id { pressed = nil }
                    }
                },
                onOpen: onOpen
            )
            // The width and the sides of the composer below it.
            .frame(maxWidth: 780)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }
}

/// The row of buttons under the agent's last message: up to four answers, the first one the primary, then a link that
/// opens a page, and "2 of 6" when the agent counts steps. A press sends the button's reply as the person's message.
struct QuickRepliesBar: View {
    var replies: QuickReplies
    var onReply: (String) -> Void
    var onOpen: (URL) -> Void

    var body: some View {
        let buttons = QuickRepliesRules.buttons(replies)
        // A button with a second line is taller than the compact size.
        let size: BanditoButtonSize = buttons.contains { $0.subtitle != nil } ? .regular : .compact
        let link = QuickRepliesRules.link(replies)
        let progress = QuickRepliesRules.progressText(replies.progress)
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                ForEach(buttons) { button in
                    Button {
                        onReply(button.reply)
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(button.label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let subtitle = button.subtitle {
                                Text(subtitle)
                                    .font(BanditoFont.text(size: 10.5, weight: 400))
                                    .opacity(0.65)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(maxWidth: 280, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .banditoButton(button.isPrimary ? .signal(size: size) : .quiet(size: size))
                    .help(button.help ?? "")
                }
                if let link {
                    Button {
                        onOpen(link.url)
                    } label: {
                        HStack(spacing: 4) {
                            // The label gives way when the line is long; the host never does: it says where the link goes.
                            Text(link.label)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("· \(QuickRepliesRules.shownHost(link.host))")
                                .lineLimit(1)
                                .fixedSize()
                                .opacity(0.7)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .frame(maxWidth: 280, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel(QuickRepliesRules.caption(label: link.label, host: link.host))
                    }
                    .banditoButton(.quiet(size: size))
                    .help(link.url.absoluteString)
                }
            }
            if let progress {
                Text(progress)
                    .font(BanditoFont.text(size: 11.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text3)
                    .accessibilityLabel(progress)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.QuickReplies.group)
    }
}
