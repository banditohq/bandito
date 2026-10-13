import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The one-time note after the first click on a web link: where links open, and how ⌘ changes it. Shown over the
/// window until closed, and it goes away by itself.
struct ChatLinkNotice: Identifiable, Equatable {
    let id = UUID()
    let target: ChatLinkOpenTarget
    let browserName: String
}

struct ChatLinkNoticeToast: View {
    let notice: ChatLinkNotice
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .banditoButton(.icon(size: 24, label: L10n.Common.close))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color.Bandito.surface3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            onClose()
        }
    }

    private var message: String {
        switch notice.target {
        case .builtIn: L10n.ChatLinks.Toast.builtIn(browser: notice.browserName)
        case .macBrowser: L10n.ChatLinks.Toast.mac(browser: notice.browserName)
        }
    }
}

/// The hover hint under a message that has web links: where a click opens the link, and where ⌘ opens it. It is drawn
/// over the message (it takes no room), and it appears only while the pointer is on the message. The ⌘ key is watched
/// only while the pointer is there.
struct ChatLinkHintHost<Content: View>: View {
    /// The first web address of the message, found when the message was parsed. It decides the hint.
    let link: URL
    @ViewBuilder var content: Content

    @State private var hovering = false
    private let monitor = CommandKeyMonitor.shared

    var body: some View {
        content
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { monitor.retain() } else { monitor.release() }
            }
            .onDisappear {
                if hovering {
                    hovering = false
                    monitor.release()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if hovering, let text = hintText {
                    ChatLinkHintCapsule(text: text)
                        .offset(y: 30)
                        .transition(.opacity)
                }
            }
            .banditoAnimation(.easeOut(duration: BanditoMotion.fast), value: hovering)
    }

    private var hintText: String? {
        let browser = ChatLinkBrowser.defaultName() ?? L10n.ChatLinks.Browser.fallback
        switch ChatLinkRouting.hintKind(
            for: link, commandHeld: monitor.commandHeld, preferences: .stored())
        {
        case .builtInWithCommand: return L10n.ChatLinks.Hint.builtInWithCommand(browser: browser)
        case .macWithCommand: return L10n.ChatLinks.Hint.macWithCommand(browser: browser)
        case .builtInOnly: return L10n.ChatLinks.Hint.builtInOnly
        case .macOnly: return L10n.ChatLinks.Hint.macOnly(browser: browser)
        }
    }
}

private struct ChatLinkHintCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.text(size: 11.5, weight: 500))
            .foregroundStyle(Color.Bandito.text2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.Bandito.surface3, in: Capsule())
            .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
