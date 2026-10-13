import AppKit
import BanditoKit
import BanditoL10n
import SwiftUI

extension ChatLinkText {
    /// Opens a link from a message. A path is asked of the server first (`fs.stat`, which also expands `~/`): a
    /// folder opens in Files, a file opens in the workbench panel beside the chat, and ⌥ shows a file in Files instead.
    /// A path that is not there opens nothing. A web address goes where `ChatLinkRouting` says: the browser tab of
    /// the panel, or the browser of the Mac. The first web link clicked on this Mac also raises a one-time note.
    @MainActor
    static func open(_ url: URL, agentID: String, folder: String?, server: ServerModel, router: Router) {
        let flags = NSEvent.modifierFlags
        if let path = filePath(of: url) {
            let requested = ChatLinks.absolutePath(path, folder: folder)
            Task { @MainActor in
                guard let entry = try? await server.stat(requested) else { return }
                switch entry.kind {
                case .dir:
                    router.openInFiles(entry.path, isFile: false)
                case .file, .symlink:
                    if flags.contains(.option) {
                        router.openInFiles(entry.path, isFile: true)
                    } else {
                        router.showInWorkbench(.file(path: entry.path), agentID: agentID)
                    }
                case .other:
                    return
                }
            }
            return
        }
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let preferences = ChatLinkPreferences.stored()
        let destination = ChatLinkRouting.destination(
            for: url, commandHeld: flags.contains(.command), preferences: preferences)
        if !UserDefaults.standard.bool(forKey: ChatLinkSettings.hintShownKey) {
            UserDefaults.standard.set(true, forKey: ChatLinkSettings.hintShownKey)
            router.chatLinkNotice = ChatLinkNotice(
                target: preferences.openTarget,
                browserName: ChatLinkBrowser.defaultName() ?? L10n.ChatLinks.Browser.fallback)
        }
        switch destination {
        case .macBrowser:
            NSWorkspace.shared.open(url)
        case .builtIn:
            let model = BrowserStore.shared.model(for: server)
            model.addressText = url.absoluteString
            model.submitAddress()
            router.showInWorkbench(.browser, agentID: agentID)
        }
    }
}
