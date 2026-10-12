import AppKit
import Foundation

/// Where a web link from a chat opens when it is clicked without ⌘. ⌘-click always takes the other one.
enum ChatLinkOpenTarget: String, CaseIterable, Sendable {
    /// The browser in the workbench panel, beside the chat (the default).
    case builtIn
    /// The browser of the Mac, with its sign-ins and extensions.
    case macBrowser
}

/// Where a web link actually opens.
enum ChatLinkDestination: Equatable, Sendable {
    case builtIn
    case macBrowser
}

/// The storage keys of the two settings in Settings → General, and the one-time hint flag. Read through
/// `ChatLinkPreferences.stored()`, written by the Settings controls.
enum ChatLinkSettings {
    static let openTargetDefaultsKey = "chatLinks.openTarget"
    static let signInDefaultsKey = "chatLinks.signInInMacBrowser"
    /// Set after the first click on a web link: the explanatory toast is shown once.
    static let hintShownKey = "chatLinks.hintShown"
}

/// The two link settings as they are stored.
struct ChatLinkPreferences: Equatable, Sendable {
    var openTarget: ChatLinkOpenTarget
    /// Sign-in and login pages open in the Mac browser, whatever the target and ⌘ say.
    var signInInMacBrowser: Bool

    static let defaults = ChatLinkPreferences(openTarget: .builtIn, signInInMacBrowser: true)

    static func stored(_ store: UserDefaults = .standard) -> ChatLinkPreferences {
        let target = store.string(forKey: ChatLinkSettings.openTargetDefaultsKey)
            .flatMap(ChatLinkOpenTarget.init(rawValue:)) ?? defaults.openTarget
        let signIn = store.object(forKey: ChatLinkSettings.signInDefaultsKey) as? Bool ?? defaults.signInInMacBrowser
        return ChatLinkPreferences(openTarget: target, signInInMacBrowser: signIn)
    }
}

/// What the hover hint under a message with links says. `builtInWithCommand` reads "Opens in the built-in browser ·
/// ⌘ — in Safari"; the other cases say one destination only (a sign-in link, or ⌘ already held).
enum ChatLinkHintKind: Equatable, Sendable {
    case builtInWithCommand
    case macWithCommand
    case builtInOnly
    case macOnly
}

/// Decides where a web link from a chat opens, and what the hint says. Pure: the views and the click handler call it.
enum ChatLinkRouting {
    /// One function for every web link in a chat. A plain click goes where the settings say: a sign-in page to the
    /// Mac browser when that setting is on, any other link to the target setting. ⌘ always takes the opposite of
    /// what the plain click does, for every link, sign-in pages included.
    static func destination(
        for url: URL, commandHeld: Bool, preferences: ChatLinkPreferences
    ) -> ChatLinkDestination {
        let plain: ChatLinkDestination
        if preferences.signInInMacBrowser, isSignIn(url) {
            plain = .macBrowser
        } else {
            plain = preferences.openTarget == .builtIn ? .builtIn : .macBrowser
        }
        guard commandHeld else { return plain }
        return plain == .builtIn ? .macBrowser : .builtIn
    }

    /// The hint for a link. With ⌘ held it shows where ⌘ leads, alone; without ⌘ it shows where a click goes and where
    /// ⌘ takes it.
    static func hintKind(for url: URL, commandHeld: Bool, preferences: ChatLinkPreferences) -> ChatLinkHintKind {
        let shows = destination(for: url, commandHeld: commandHeld, preferences: preferences)
        if commandHeld {
            return shows == .builtIn ? .builtInOnly : .macOnly
        }
        return shows == .builtIn ? .builtInWithCommand : .macWithCommand
    }

    /// The first web address among the links of a message (a file link is not a choice of browsers, so it has none).
    static func firstWebLink(in blocks: [RenderedBlock]) -> URL? {
        for block in blocks {
            guard case .text(let value) = block else { continue }
            for (link, _) in value.runs[\.link] {
                if let link, link.scheme == "http" || link.scheme == "https" { return link }
            }
        }
        return nil
    }

    /// Hosts that only sign people in. A subdomain counts (`tenant.auth0.com`).
    static let signInHosts = ["accounts.google.com", "login.microsoftonline.com", "appleid.apple.com", "connect.composio.dev"]
    static let signInHostSuffixes = [".auth0.com"]

    /// True for the sign-in and login pages of the usual services: a login or OAuth/authorize page on any host, the
    /// login page of GitHub, and the sign-in hosts above. Such a page must run in the Mac browser, where the person is
    /// already signed in and where a redirect back to Bandito does not depend on the built-in panel.
    static func isSignIn(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return false }
        if signInHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if signInHostSuffixes.contains(where: { host.hasSuffix($0) }) { return true }
        let path = url.path.lowercased()
        if host == "github.com", path.hasPrefix("/login") { return true }
        return path.contains("/oauth") || path.contains("/authorize") || path.contains("/login")
    }
}

/// The browser macOS opens web links with, by its display name ("Safari"). `nil` when the system has none.
enum ChatLinkBrowser {
    @MainActor
    static func defaultName() -> String? {
        guard let probe = URL(string: "https://bandito.dev"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return nil }
        return FileManager.default.displayName(atPath: app.path)
    }
}

/// Watches the ⌘ key while a hint is on screen. It listens only while someone retains it (a pointer over a message with
/// links), and it writes `commandHeld` only when the key changes, so the views that read it are not redrawn for
/// every modifier event.
@MainActor
@Observable
final class CommandKeyMonitor {
    static let shared = CommandKeyMonitor()

    private(set) var commandHeld = false
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var token: Any?

    func retain() {
        users += 1
        guard token == nil else { return }
        commandHeld = NSEvent.modifierFlags.contains(.command)
        token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated {
                if self?.commandHeld != held { self?.commandHeld = held }
            }
            return event
        }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0, let token else { return }
        NSEvent.removeMonitor(token)
        self.token = nil
        commandHeld = false
    }
}
