#if os(macOS)
import BanditoKit
import SwiftUI
import WebKit

/// Answers `bandito-preview://` loads for one port: the web view was opened for `servingPort`, and a load of any
/// other port gets 404. The request goes to the daemon through its request builder, which adds the device token, so
/// the token stays out of the web view. The server's address is read for each load, so an ssh tunnel that moved is
/// followed, and a token is never sent over a connection that does not allow it.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    private let server: ServerModel
    private let servingPort: Int
    /// One session per web view: its own cookies, no cache.
    private let session: URLSession
    /// The request that is being built for each load, so `stop` can cancel it before it starts.
    private var building: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// The data task of each load that is still running, so `stop` can cancel it.
    private var running: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(server: ServerModel, servingPort: Int) {
        self.server = server
        self.servingPort = servingPort
        self.session = URLSession(configuration: PreviewProxy.previewConfiguration())
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        let incoming = urlSchemeTask.request
        guard let url = incoming.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let parts = PreviewProxy.target(for: url, servingPort: servingPort) else {
            // Another port than this web view's: not served here.
            Self.answer(urlSchemeTask, url: url, status: 404, headers: [:], body: Data())
            return
        }
        let method = incoming.httpMethod ?? "GET"
        let headers = PreviewProxy.forwardedHeaders(incoming.allHTTPHeaderFields ?? [:])
        let body = PreviewProxy.body(of: incoming)
        let box = SchemeTaskBox(task: urlSchemeTask)
        building[key] = Task { @MainActor in
            defer { self.building.removeValue(forKey: key) }
            do {
                var request = try await self.server.daemonRequest(
                    encodedPath: parts.path, encodedQuery: parts.query)
                guard !Task.isCancelled else { return }
                request.httpMethod = method
                for (name, value) in headers {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                request.httpBody = body
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
        Self.answer(box.task, url: url, status: http.statusCode, headers: PreviewProxy.responseHeaders(headers), body: data ?? Data())
    }

    private static func answer(_ task: WKURLSchemeTask, url: URL, status: Int, headers: [String: String], body: Data) {
        if let reply = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
            task.didReceive(reply)
        }
        task.didReceive(body)
        task.didFinish()
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

/// A web view that shows one preview: `url` is `bandito-preview://p<port>/…` (answered for `server`, and for that port
/// only) or `http://127.0.0.1:<port>` for a Mac server. Recreated when the view's identity changes (use `.id(port)`).
struct PreviewWebView: NSViewRepresentable {
    let url: URL
    let server: ServerModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if url.scheme == PreviewURL.scheme {
            configuration.setURLSchemeHandler(
                PreviewSchemeHandler(server: server, servingPort: PreviewURL.port(of: url) ?? 0),
                forURLScheme: PreviewURL.scheme)
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
