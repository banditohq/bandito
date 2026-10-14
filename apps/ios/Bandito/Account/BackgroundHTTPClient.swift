import BanditoKit
import Foundation
import UIKit

/// Keeps a request alive for the few seconds iOS gives an app that has just gone to the background (a person who
/// leaves for Mail to read a code): without it the connection is cut mid-request and the answer is lost.
struct BackgroundHTTPClient: HTTPClient {
    let base: HTTPClient

    init(_ base: HTTPClient) { self.base = base }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let box = await MainActor.run { BackgroundTaskBox() }
        await box.begin()
        defer { Task { await box.end() } }
        return try await base.send(request)
    }
}

@MainActor
private final class BackgroundTaskBox {
    private var id = UIBackgroundTaskIdentifier.invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "dev.bandito.account.request") { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
