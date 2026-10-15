import BanditoL10n
import Observation
import UIKit

// The actions of the app icon (a long press on the icon): "New task" and "Inbox". They are set in code, not in
// Info.plist. The SwiftUI app gets them through a small app delegate and a scene delegate that only read the action;
// RootView takes the action from `QuickActionHub` and does what the button or the tab does.

/// One action of the app icon.
enum QuickAction: String, CaseIterable {
    case newTask = "dev.bandito.ios.quick.newTask"
    case inbox = "dev.bandito.ios.quick.inbox"

    init?(item: UIApplicationShortcutItem) {
        self.init(rawValue: item.type)
    }

    var shortcutItem: UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: rawValue, localizedTitle: title, localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: symbol), userInfo: nil)
    }

    var title: String {
        switch self {
        case .newTask: L10n.Ios.QuickAction.newTask
        case .inbox: L10n.Ios.Tab.inbox
        }
    }

    private var symbol: String {
        switch self {
        case .newTask: "square.and.pencil"
        case .inbox: "tray"
        }
    }
}

/// The action the app was asked to do by its icon, until RootView takes it.
@MainActor
@Observable
final class QuickActionHub {
    static let shared = QuickActionHub()

    private(set) var pending: QuickAction?

    func request(_ action: QuickAction) {
        pending = action
    }

    func consume() {
        pending = nil
    }
}

/// Sets the icon's actions at launch, and passes the scene's connection to the scene delegate.
@MainActor
final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        application.shortcutItems = QuickAction.allCases.map(\.shortcutItem)
        return true
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

/// Reads an action that starts the app (`connectionOptions`) or that is chosen while it runs.
@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let item = connectionOptions.shortcutItem, let action = QuickAction(item: item) else { return }
        QuickActionHub.shared.request(action)
    }

    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let action = QuickAction(item: shortcutItem)
        if let action {
            QuickActionHub.shared.request(action)
        }
        completionHandler(action != nil)
    }
}
