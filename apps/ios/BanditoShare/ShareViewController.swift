import BanditoDesign
import SwiftUI
import UIKit

/// The share sheet of Bandito. It hosts the SwiftUI `ShareView`; it never talks to a server and never reads a token:
/// it leaves the task in the App Group and opens the app (docs/IOS_APP.md, Share extension).
final class ShareViewController: UIViewController {
    private let model = ShareModel.live()

    override func viewDidLoad() {
        super.viewDidLoad()
        BanditoFont.registerBundledFonts()
        view.backgroundColor = UIColor(Color.Bandito.bg)
        model.openApp = { [weak self] url in self?.open(url) ?? false }
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { @MainActor [model] in
            model.apply(await ShareLoader.load(from: items))
        }
    }

    /// Opens a link through the responder chain: the first object that answers `open(_:options:completionHandler:)`
    /// is the application. An extension has no `UIApplication.shared`, so this is the way to reach it; if nothing
    /// answers the sheet says the message is saved.
    private func open(_ url: URL) -> Bool {
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, AnyObject?) -> Void
                let call = unsafeBitCast(method_getImplementation(method), to: Open.self)
                call(current, selector, url, [:], nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
