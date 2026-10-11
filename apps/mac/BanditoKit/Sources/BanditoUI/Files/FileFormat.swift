import BanditoKit
import BanditoL10n
import Foundation
import os

/// Text for file metadata: when it changed, how big it is, what kind it is.
enum FileFormat {
    /// "just now", "5 min ago", "today, 14:05", "yesterday, 19:40", or "8 Oct" for older files.
    static func changed(ms: Int64, now: Date = .now) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        // Making a date format costs about as much as drawing the row: only the cases that show a time make one.
        switch RelativeTime.bucket(ms: ms, now: now, calendar: .current) {
        case .justNow: return L10n.Files.Time.justNow
        case .minutes(let count): return L10n.Files.Time.minutes(count: count)
        case .today: return L10n.Files.Time.today(time: date.formatted(date: .omitted, time: .shortened))
        case .yesterday: return L10n.Files.Time.yesterday(time: date.formatted(date: .omitted, time: .shortened))
        case .earlier: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// "6.4 KB" style size. Folders have none, so the text is empty (not a dash).
    static func size(of entry: FsEntry) -> String {
        guard entry.kind == .file else { return "" }
        return byteCounts.withLock { $0.string(fromByteCount: entry.size) }
    }

    /// One formatter for all rows: a new one per row of a folder with a thousand files was most of the cost of the list.
    /// A formatter is not safe to share between threads, so it sits behind a lock.
    private static let byteCounts: OSAllocatedUnfairLock<ByteCountFormatter> = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return OSAllocatedUnfairLock(uncheckedState: formatter)
    }()

    /// The Size column: a dash for folders, the size for files, empty for links and other entries (as before).
    static func sizeCell(of entry: FsEntry) -> String {
        entry.kind == .dir ? "—" : size(of: entry)
    }

    /// "Document · 6.4 KB" under the file name in the preview. Folders have no size, so they show only the kind.
    static func subtitle(kind: String, size: String) -> String {
        size.isEmpty ? kind : "\(kind) · \(size)"
    }

    /// The word for a category, shown under the file name in the preview.
    static func kind(_ category: FileCategory) -> String {
        switch category {
        case .folder: L10n.Files.Kind.folder
        case .markdown: L10n.Files.Kind.markdown
        case .code: L10n.Files.Kind.code
        case .text: L10n.Files.Kind.text
        case .config: L10n.Files.Kind.config
        case .image: L10n.Files.Kind.image
        case .pdf: L10n.Files.Kind.pdf
        case .video: L10n.Files.Kind.video
        case .audio: L10n.Files.Kind.audio
        case .binary: L10n.Files.Kind.binary
        case .other: L10n.Files.Kind.other
        }
    }
}

extension FileCategory {
    static func of(_ entry: FsEntry) -> FileCategory {
        FileTypes.category(name: entry.name, ext: entry.ext, kind: entry.kind)
    }
}
