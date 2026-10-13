import AVFoundation
import Foundation

/// The files the document picker copied into the app's temporary folder (`asCopy`): read once, then removed, so a
/// picked file does not stay on the phone after it was sent.
enum ChatTempFiles {
    static func readAndRemove(_ url: URL) -> Data? {
        defer { remove(url) }
        return try? Data(contentsOf: url)
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What the camera button does for the camera's permission.
enum ChatCameraAccess {
    enum Decision: Equatable {
        /// Open the camera.
        case open
        /// Ask first (the system's question, with the reason in Info.plist).
        case ask
        /// Refused or restricted: say so, and offer the Settings.
        case explain
    }

    static func decision(for status: AVAuthorizationStatus) -> Decision {
        switch status {
        case .authorized: .open
        case .notDetermined: .ask
        case .denied, .restricted: .explain
        @unknown default: .explain
        }
    }
}
