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
        model.openApp = { [weak self] url in await self?.open(url) ?? false }
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
    /// is the application. An extension has no `UIApplication.shared`, so this is the way to reach it. True only when
    /// the system says it opened the link; with no answer within two seconds, or none in the chain, the sheet says the
    /// message is saved instead.
    private func open(_ url: URL) async -> Bool {
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), let method = class_getInstanceMethod(type(of: current), selector) {
                typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, @escaping @convention(block) (Bool) -> Void) -> Void
                let call = unsafeBitCast(method_getImplementation(method), to: Open.self)
                let once = OnceFlag()
                return await withCheckedContinuation { continuation in
                    call(current, selector, url, [:]) { opened in
                        if once.take() { continuation.resume(returning: opened) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if once.take() { continuation.resume(returning: false) }
                    }
                }
            }
            responder = current.next
        }
        return false
    }
}

/// Lets exactly one of two racing callbacks through.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
