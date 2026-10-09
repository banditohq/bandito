import AVFoundation
import AVKit
import BanditoKit
import SwiftUI

/// Bytes of a file on the server, through the raw endpoint (with the auth header) or the local file.
enum RemoteFile {
    enum Failure: Error {
        case unavailable, status(Int)
    }

    @MainActor
    static func data(path: String, server: ServerModel) async throws -> Data {
        let request = try await server.rawURLRequest(path: path)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        return data
    }
}

/// An image from the server, scaled to fit. Shows a placeholder while loading or when it cannot be read.
struct RemoteImage: View {
    let path: String
    let server: ServerModel
    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.Bandito.text3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            image = nil
            failed = false
            do {
                let data = try await RemoteFile.data(path: path, server: server)
                guard let loaded = FileBridge.image(from: data) else { throw RemoteFile.Failure.unavailable }
                image = loaded
            } catch {
                failed = true
            }
        }
    }
}

/// A video or audio file from the server, played as it streams. Headers go with the request, so the token
/// reaches the server but is not written anywhere.
struct RemoteMediaPlayer: View {
    let path: String
    let server: ServerModel
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) {
            guard let request = try? await server.rawURLRequest(path: path), let url = request.url else { return }
            var options: [String: Any] = [:]
            if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            let asset = AVURLAsset(url: url, options: options)
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        .onDisappear { player?.pause() }
    }
}
