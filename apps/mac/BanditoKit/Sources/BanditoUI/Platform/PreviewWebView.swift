#if os(macOS)
import BanditoKit
import SwiftUI
import WebKit

/// Answers `bandito-preview://` loads by asking the server's HTTP proxy, with the device token in the
/// `Authorization` header. The token stays out of the web view: it never sees the server address or the token.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let serverBase: URL?
    private let token: String?
    private let session = URLSession(configuration: .ephemeral)
    /// The data task of each load that is still running, so `stop` can cancel it.
    private var running: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(serverBase: URL?, token: String?) {
        self.serverBase = serverBase
        self.token = token
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url, let serverBase,
              let target = PreviewURL.proxyURL(for: url, serverBase: serverBase)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var request = URLRequest(url: target)
        request.httpMethod = urlSchemeTask.request.httpMethod ?? "GET"
        if let accept = urlSchemeTask.request.value(forHTTPHeaderField: "Accept") {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let box = SchemeTaskBox(task: urlSchemeTask)
        let dataTask = session.dataTask(with: request) { data, response, error in
            Task { @MainActor in
                self.finish(key: key, box: box, url: url, data: data, response: response, error: error)
            }
        }
        running[key] = dataTask
        dataTask.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        running.removeValue(forKey: key)?.cancel()
    }

    private func finish(key: ObjectIdentifier, box: SchemeTaskBox, url: URL, data: Data?, response: URLResponse?, error: Error?) {
        // A stopped load was cancelled: WebKit must not get a second answer for it.
        guard running.removeValue(forKey: key) != nil else { return }
        if let error {
            box.task.didFailWithError(error)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            box.task.didFailWithError(URLError(.badServerResponse))
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        if let reply = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) {
            box.task.didReceive(reply)
        }
        box.task.didReceive(data ?? Data())
        box.task.didFinish()
    }
}

/// Carries a `WKURLSchemeTask` into the session's completion, which runs off the main actor.
private final class SchemeTaskBox: @unchecked Sendable {
    // Only touched on the main actor (see `PreviewSchemeHandler.finish`).
    let task: WKURLSchemeTask

    init(task: WKURLSchemeTask) {
        self.task = task
    }
}

/// A web view that shows one preview: `url` is `bandito-preview://…` (through `handler`) or `http://127.0.0.1:<port>`
/// for a Mac server. Recreated when the view's identity changes (use `.id(port)`).
struct PreviewWebView: NSViewRepresentable {
    let url: URL
    let serverBase: URL?
    let token: String?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if url.scheme == PreviewURL.scheme {
            configuration.setURLSchemeHandler(
                PreviewSchemeHandler(serverBase: serverBase, token: token), forURLScheme: PreviewURL.scheme)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
