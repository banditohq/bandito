#if os(macOS)
import BanditoKit
import SwiftUI
import WebKit

/// Answers `bandito-preview://` loads by asking the server's HTTP proxy through the daemon's request builder, which
/// adds the device token. The token stays out of the web view. The server's address is read for each load, so an
/// ssh tunnel that moved is followed, and a token is never sent over a connection that does not allow it.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let server: ServerModel
    private let session = URLSession(configuration: .ephemeral)
    /// The request that is being built for each load, so `stop` can cancel it before it starts.
    private var building: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The data task of each load that is still running, so `stop` can cancel it.
    private var running: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(server: ServerModel) {
        self.server = server
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url, let parts = PreviewURL.proxyParts(for: url) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let method = urlSchemeTask.request.httpMethod ?? "GET"
        let accept = urlSchemeTask.request.value(forHTTPHeaderField: "Accept")
        let box = SchemeTaskBox(task: urlSchemeTask)
        building[key] = Task { @MainActor in
            defer { self.building.removeValue(forKey: key) }
            do {
                var request = try await self.server.daemonRequest(
                    encodedPath: parts.path, encodedQuery: parts.query)
                guard !Task.isCancelled else { return }
                request.httpMethod = method
                if let accept {
                    request.setValue(accept, forHTTPHeaderField: "Accept")
                }
                let dataTask = self.session.dataTask(with: request) { data, response, error in
                    Task { @MainActor in
                        self.finish(key: key, box: box, url: url, data: data, response: response, error: error)
                    }
                }
                self.running[key] = dataTask
                dataTask.resume()
            } catch {
                guard !Task.isCancelled else { return }
                box.task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        building.removeValue(forKey: key)?.cancel()
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

/// A web view that shows one preview: `url` is `bandito-preview://…` (answered for `server`) or `http://127.0.0.1:<port>`
/// for a Mac server. Recreated when the view's identity changes (use `.id(port)`).
struct PreviewWebView: NSViewRepresentable {
    let url: URL
    let server: ServerModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if url.scheme == PreviewURL.scheme {
            configuration.setURLSchemeHandler(
                PreviewSchemeHandler(server: server), forURLScheme: PreviewURL.scheme)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
