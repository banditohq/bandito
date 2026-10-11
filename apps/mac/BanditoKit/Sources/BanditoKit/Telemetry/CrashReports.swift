import Foundation

/// What a crash report says, reduced to what may leave the Mac: the exception's type and the frames of the thread that
/// crashed, each as `image`symbol` (or `image`+offset without a symbol). No paths, no addresses, no messages.
public struct CrashSummary: Equatable, Sendable {
    public var kind: String
    public var frames: [String]

    public init(kind: String, frames: [String]) {
        self.kind = kind
        self.frames = frames
    }
}

/// Reads a macOS crash report (`.ips`): one JSON header line, then one JSON body.
public enum CrashReportParser {
    public static let maxFrames = 64
    public static let maxFrameLength = 200
    public static let maxKindLength = 64

    /// Takes out every path that starts at a home folder (`/Users/<name>/...`), up to the next space or backtick.
    /// The app's own paths and the person's folder names must not leave the Mac, even inside a symbol.
    public static func scrubbed(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^\s`]*"#, with: "<path>", options: .regularExpression)
    }

    /// The summary of a report, or nil when the file is not a report this parser understands.
    public static func summary(from data: Data) -> CrashSummary? {
        // The body starts after the first line; the header carries only the app name and the time.
        guard let newline = data.firstIndex(of: 0x0A),
            let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...])
                as? [String: Any]
        else { return nil }

        let exception = body["exception"] as? [String: Any]
        let kind = (exception?["type"] as? String) ?? "unknown"
        // Only the file name of an image: its path is the person's own folder structure.
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map {
            URL(fileURLWithPath: ($0["name"] as? String) ?? "?").lastPathComponent
        }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { ($0["triggered"] as? Bool) == true }
        let frames = (crashed?["frames"] as? [[String: Any]] ?? []).prefix(maxFrames).map { frame -> String in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : "?"
            let location = (frame["symbol"] as? String) ?? "+\(frame["imageOffset"] as? Int ?? 0)"
            return String(scrubbed("\(image)`\(location)").prefix(maxFrameLength))
        }
        return CrashSummary(kind: String(scrubbed(kind).prefix(maxKindLength)), frames: frames)
    }
}

/// A crash report file with the time it was last written.
public struct CrashReportFile: Equatable, Sendable {
    public var url: URL
    public var modified: Date
}

/// Finds the crash reports of the app in the folder where macOS writes them.
public enum CrashReportScanner {
    /// `~/Library/Logs/DiagnosticReports` of the person who runs the app.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// The `.ips` files whose names start with `prefix` and that were written after `modifiedAfter`, oldest first.
    /// Without a `modifiedAfter` every such file counts.
    public static func reports(
        in directory: URL, prefix: String = "Bandito", modifiedAfter: Date?
    ) -> [CrashReportFile] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return urls.compactMap { url -> CrashReportFile? in
            guard url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "ips" else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let modifiedAfter, modified <= modifiedAfter { return nil }
            return CrashReportFile(url: url, modified: modified)
        }
        .sorted { $0.modified < $1.modified }
    }
}
